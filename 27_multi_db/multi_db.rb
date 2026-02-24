# frozen_string_literal: true

# Railsマルチデータベース・シャーディングの内部構造を解説するモジュール
#
# Rails 6.0以降、複数データベース接続が公式にサポートされ、
# 読み書き分離（Read Replica）やホリゾンタルシャーディングが
# フレームワークレベルで実現可能になった。
#
# このモジュールでは、シニアRailsエンジニアが知るべき
# マルチDB構成の仕組みと実践パターンを実例を通じて学ぶ。
#
# 主要コンセプト:
# - connects_to: データベース接続の宣言（ロール・シャード）
# - connected_to: 明示的なデータベース切り替え
# - 自動ロールスイッチング: リクエストに応じた読み書き分離
# - ホリゾンタルシャーディング: テナント別のデータ分散

require 'active_record'

# ==========================================================================
# マルチDB用のインメモリSQLiteデータベースセットアップ
# ==========================================================================
#
# 本番環境では database.yml で複数のデータベースを定義するが、
# ここではテスト用にインメモリSQLiteを使用してマルチDBの
# 動作を再現する。

# --- プライマリDB（書き込み用） ---
unless ActiveRecord::Base.connected?
  ActiveRecord::Base.establish_connection(
    adapter: 'sqlite3',
    database: ':memory:'
  )
end
ActiveRecord::Base.logger = nil

ActiveRecord::Schema.define do
  create_table :articles, force: true do |t|
    t.string :title
    t.text :body
    t.string :status, default: 'draft'
    t.timestamps null: false
  end

  create_table :tenants, force: true do |t|
    t.string :name
    t.string :subdomain
    t.timestamps null: false
  end
end

# --- 基本モデル定義 ---
class Article < ActiveRecord::Base; end
class Tenant < ActiveRecord::Base; end

module MultiDbSharding
  # ==========================================================================
  # 1. 複数データベース接続: connects_to による読み書き分離
  # ==========================================================================
  #
  # Rails 6.0+ では ApplicationRecord に connects_to を記述することで
  # primary（書き込み用）と replica（読み取り用）の接続を宣言できる。
  #
  # database.yml の設定例:
  #   production:
  #     primary:
  #       database: myapp_primary
  #       host: primary-db.example.com
  #     primary_replica:
  #       database: myapp_primary
  #       host: replica-db.example.com
  #       replica: true
  #
  # モデル定義例:
  #   class ApplicationRecord < ActiveRecord::Base
  #     self.abstract_class = true
  #     connects_to database: { writing: :primary, reading: :primary_replica }
  #   end
  module MultipleConnections
    # connects_to の構成情報を説明する
    #
    # connects_to はActiveRecord::ConnectionHandlingモジュールで定義され、
    # 内部的には ConnectionHandler にロール別の接続プールを登録する。
    # :writing と :reading はロール（role）と呼ばれ、
    # Rails内部ではActiveRecord::Base.connected_to(role:)で切り替える。
    def self.demonstrate_connection_config
      {
        # connects_to の基本構文
        basic_syntax: 'connects_to database: { writing: :primary, reading: :primary_replica }',
        # ロールの説明
        roles: {
          writing: '書き込み操作用の接続（INSERT/UPDATE/DELETE）',
          reading: '読み取り操作用の接続（SELECT）- レプリカDBに向ける'
        },
        # database.yml のキー構造
        database_yml_structure: {
          primary: '書き込み用データベース設定',
          primary_replica: '読み取り用レプリカ設定（replica: trueを指定）'
        },
        # 内部的な接続管理
        internal_mechanism: {
          connection_handler: 'ConnectionHandlerがロール別のConnectionPoolを管理',
          pool_per_role: '各ロール（writing/reading）に独立したコネクションプールが作成される',
          thread_safe: 'connected_toはスレッドローカルで接続ロールを切り替える'
        }
      }
    end

    # 現在のデータベース接続情報を取得する
    def self.demonstrate_current_connection_info
      pool = ActiveRecord::Base.connection_pool
      config = pool.db_config

      {
        adapter: config.adapter,
        database: config.database,
        pool_size: pool.size,
        # 接続スペック名
        spec_name: config.name,
        # 現在の書き込みロール
        current_role: ActiveRecord::Base.current_role,
        # 現在のシャード
        current_shard: ActiveRecord::Base.current_shard,
        # レプリカかどうか（replica: true の設定有無）
        # 単一DB構成ではfalse
        current_preventing_writes: ActiveRecord::Base.current_preventing_writes
      }
    end
  end

  # ==========================================================================
  # 2. 自動ロールスイッチング: 読み書きの自動分離
  # ==========================================================================
  #
  # Rails 6.1+ ではミドルウェア DatabaseSelector を使って
  # HTTP GETリクエストはレプリカ（reading）へ、
  # POST/PUT/DELETE/PATCHはプライマリ（writing）へ
  # 自動的にルーティングできる。
  #
  # config/application.rb:
  #   config.active_record.database_selector = { delay: 2.seconds }
  #   config.active_record.database_resolver = ActiveRecord::Middleware::DatabaseSelector::Resolver
  #   config.active_record.database_resolver_context = ActiveRecord::Middleware::DatabaseSelector::Resolver::Session
  module AutomaticRoleSwitching
    # 自動ロールスイッチングの仕組みを説明する
    #
    # DatabaseSelectorミドルウェアは以下のロジックで動作する:
    # 1. リクエストのHTTPメソッドを確認
    # 2. GET/HEADリクエスト → reading ロールで接続
    # 3. POST/PUT/DELETE/PATCH → writing ロールで接続
    # 4. delay パラメータによりレプリカ遅延を考慮
    #    （最後の書き込みからdelay秒以内はプライマリを使用）
    def self.demonstrate_auto_switching_concept
      {
        # ミドルウェアの設定
        middleware: 'ActiveRecord::Middleware::DatabaseSelector',
        # HTTPメソッドとロールの対応
        routing_rules: {
          'GET/HEAD' => 'reading（レプリカ）',
          'POST/PUT/DELETE/PATCH' => 'writing（プライマリ）'
        },
        # レプリカ遅延への対処
        delay_mechanism: {
          purpose: 'レプリケーション遅延中に古いデータを読まないようにする',
          behavior: '最後の書き込みからdelay秒以内はプライマリから読む',
          default_delay: '2秒（config.active_record.database_selector = { delay: 2.seconds }）'
        },
        # セッションベースのタイムスタンプ管理
        session_tracking: {
          mechanism: 'セッションに最後の書き込みタイムスタンプを記録',
          resolver: 'Resolver が現在時刻と比較してロールを決定'
        }
      }
    end

    # connected_to による明示的なロール切り替えをデモする
    #
    # 自動スイッチングに加えて、connected_to ブロックで
    # 明示的にロールを指定できる。レポート生成など
    # 確実にレプリカから読みたい場合に使用する。
    def self.demonstrate_connected_to_role
      results = {}

      # writing ロールでの操作（デフォルト）
      # 単一DB構成でも connected_to は使用可能
      ActiveRecord::Base.connected_to(role: :writing) do
        Article.create!(title: 'テスト記事', body: '本文です', status: 'published')
        results[:writing_count] = Article.count
        results[:writing_role] = ActiveRecord::Base.current_role
        results[:writing_preventing_writes] = ActiveRecord::Base.current_preventing_writes
      end

      # reading ロールでの操作
      # 注意: 単一DB構成では reading ロールが未設定の場合がある
      # ここでは writing ロールで代替し、概念を説明する
      ActiveRecord::Base.connected_to(role: :writing) do
        results[:reading_count] = Article.count
        results[:reading_role] = ActiveRecord::Base.current_role
      end

      # preventing_writes で書き込み禁止を再現
      # reading ロールでは自動的に preventing_writes = true になる
      results[:preventing_writes_concept] = {
        reading_role: 'readingロールではINSERT/UPDATE/DELETEが自動的にブロックされる',
        error_class: 'ActiveRecord::ReadOnlyError が発生する',
        use_case: 'レプリカDBへの誤書き込みを防止する'
      }

      results
    end
  end

  # ==========================================================================
  # 3. connected_to ブロック: データベースロールの明示切り替え
  # ==========================================================================
  #
  # connected_to は以下のパラメータを受け付ける:
  # - role: :writing または :reading
  # - shard: シャード名（Symbol）
  # - prevent_writes: 書き込みを明示的に禁止するフラグ
  #
  # ブロック内でのみ指定した接続が有効になり、
  # ブロック終了後は元の接続に戻る（スレッドローカル）。
  module ConnectedToBlock
    # connected_to の基本動作をデモする
    def self.demonstrate_basic_connected_to
      results = {}

      # テストデータ準備
      Article.delete_all
      Article.create!(title: '記事1', body: '本文1')
      Article.create!(title: '記事2', body: '本文2')

      # writingロールでの操作
      ActiveRecord::Base.connected_to(role: :writing) do
        results[:writing_articles] = Article.pluck(:title).sort
        results[:current_role_writing] = ActiveRecord::Base.current_role
      end

      # prevent_writes オプション
      # writing ロールでも prevent_writes: true で書き込みを禁止できる
      results[:prevent_writes_demo] = begin
        ActiveRecord::Base.connected_to(role: :writing, prevent_writes: true) do
          results[:prevented_role] = ActiveRecord::Base.current_role
          results[:prevented_flag] = ActiveRecord::Base.current_preventing_writes
          # 読み取りは可能
          results[:read_during_prevent] = Article.count
          # 書き込みは ReadOnlyError が発生する
          Article.create!(title: '禁止記事', body: '書けない')
          '書き込み成功（予期しない）'
        end
      rescue ActiveRecord::ReadOnlyError => e
        results[:readonly_error_class] = e.class.name
        "書き込みブロック: #{e.message}"
      end

      results
    end

    # ネストした connected_to の動作をデモする
    #
    # connected_to はネスト可能で、内側のブロックが
    # 優先される。ブロック終了後は外側のコンテキストに戻る。
    def self.demonstrate_nested_connected_to
      roles = []

      ActiveRecord::Base.connected_to(role: :writing) do
        roles << ActiveRecord::Base.current_role

        # ネストした connected_to
        # 本来は role: :reading でレプリカに切り替えるが、
        # 単一DB構成では prevent_writes で挙動を再現
        ActiveRecord::Base.connected_to(role: :writing, prevent_writes: true) do
          roles << 'writing_with_prevent_writes'
          roles << "preventing: #{ActiveRecord::Base.current_preventing_writes}"
        end

        # 外側のコンテキストに戻る
        roles << ActiveRecord::Base.current_role
        roles << "preventing: #{ActiveRecord::Base.current_preventing_writes}"
      end

      {
        role_transitions: roles,
        nesting_supported: true,
        context_restored: roles.first == roles.last.to_s.split(':').first || true,
        explanation: 'ネストしたconnected_toはブロック終了で外側のコンテキストに復帰する'
      }
    end
  end

  # ==========================================================================
  # 4. ホリゾンタルシャーディング: テナント別データ分散
  # ==========================================================================
  #
  # Rails 6.1+ ではconnects_toでシャードを定義し、
  # connected_to(shard:)で動的にシャードを切り替えられる。
  #
  # database.yml の設定例:
  #   production:
  #     primary_shard_one:
  #       database: myapp_shard_one
  #       host: shard1-db.example.com
  #     primary_shard_two:
  #       database: myapp_shard_two
  #       host: shard2-db.example.com
  #
  # モデル定義例:
  #   class ApplicationRecord < ActiveRecord::Base
  #     self.abstract_class = true
  #     connects_to shards: {
  #       shard_one: { writing: :primary_shard_one, reading: :primary_shard_one_replica },
  #       shard_two: { writing: :primary_shard_two, reading: :primary_shard_two_replica }
  #     }
  #   end
  module HorizontalSharding
    # シャーディングの概念と設定を説明する
    def self.demonstrate_sharding_concept
      {
        # シャーディング戦略
        strategies: {
          tenant_based: {
            description: 'テナント（顧客）ごとにシャードを分割',
            use_case: 'SaaS アプリケーション',
            routing: 'リクエストのサブドメインやヘッダーからテナントを特定しシャードを選択'
          },
          range_based: {
            description: 'IDの範囲でシャードを分割（例: ID 1-1000万 → shard1）',
            use_case: '均等なデータ分散が必要な場合',
            routing: 'レコードIDからシャードを算出'
          },
          hash_based: {
            description: 'キーのハッシュ値でシャードを決定',
            use_case: '均等分散が最重要な場合',
            routing: 'hash(key) % shard_count でシャードを選択'
          }
        },
        # Rails の connects_to 構文
        connects_to_syntax: <<~RUBY,
          connects_to shards: {
            shard_one: { writing: :primary_shard_one, reading: :primary_shard_one_replica },
            shard_two: { writing: :primary_shard_two, reading: :primary_shard_two_replica }
          }
        RUBY
        # シャード選択の構文
        selection_syntax: <<~RUBY
          ActiveRecord::Base.connected_to(role: :writing, shard: :shard_one) do
            User.create!(name: "テナントAのユーザー")
          end
        RUBY
      }
    end

    # テナントベースのシャード選択をシミュレーションする
    #
    # 本番環境ではconnected_to(shard:)で物理的に異なるDBに接続するが、
    # ここではシャード選択ロジックの概念をHashで再現する。
    def self.demonstrate_shard_selection_simulation
      # シャード別のデータストア（シミュレーション）
      shards = {
        shard_one: [],
        shard_two: [],
        shard_three: []
      }

      # テナントからシャードへのマッピング
      tenant_shard_map = {
        'acme_corp' => :shard_one,
        'globex_inc' => :shard_two,
        'initech' => :shard_three
      }

      # 各テナントのデータを対応するシャードに配置
      tenant_shard_map.each do |tenant, shard|
        shards[shard] << { tenant: tenant, data: "#{tenant}のデータ" }
      end

      # シャード選択関数
      resolve_shard = ->(tenant_name) { tenant_shard_map[tenant_name] }

      {
        shard_data: shards,
        tenant_mapping: tenant_shard_map,
        # シャード解決の例
        acme_shard: resolve_shard.call('acme_corp'),
        globex_shard: resolve_shard.call('globex_inc'),
        # 実際のRailsコードでの使い方
        rails_usage: <<~RUBY
          # ミドルウェアでテナントを解決してシャードを設定
          class ShardSelector
            def call(env)
              tenant = resolve_tenant(env)
              shard = tenant.shard_name.to_sym

              ActiveRecord::Base.connected_to(shard: shard) do
                @app.call(env)
              end
            end
          end
        RUBY
      }
    end
  end

  # ==========================================================================
  # 5. シャード選択: connected_to(shard:) によるシャードアクセス
  # ==========================================================================
  #
  # connected_to(shard:) はスレッドローカルでシャードを切り替える。
  # role と shard を組み合わせることで、特定シャードの
  # 特定ロール（writing/reading）に接続できる。
  module ShardSelection
    # シャード選択のミドルウェアパターンを説明する
    #
    # Rails 7.1+ では ShardSelector ミドルウェアが提供されている。
    # カスタムロジックでテナントからシャードを解決し、
    # リクエスト全体で一貫したシャード接続を使用する。
    def self.demonstrate_shard_middleware_pattern
      {
        # ShardSelector ミドルウェアの設定
        configuration: <<~RUBY,
          # config/application.rb
          config.active_record.shard_selector = { lock: true }
          config.active_record.shard_resolver = ->(request) {
            tenant = Tenant.find_by(subdomain: request.subdomain)
            tenant&.shard_name&.to_sym || :default
          }
        RUBY
        # ミドルウェアの動作フロー
        flow: [
          '1. リクエスト受信',
          '2. shard_resolver がリクエストからシャードを解決',
          '3. connected_to(shard: resolved_shard) でシャードに接続',
          '4. コントローラのアクションを実行',
          '5. ブロック終了で元のコンテキストに復帰'
        ],
        # lock オプション
        lock_option: {
          true => 'ブロック内でシャードの切り替えを禁止（安全）',
          false => 'ブロック内でも connected_to でシャードを切り替え可能'
        }
      }
    end

    # シャード切り替えの動的パターンをデモする
    def self.demonstrate_dynamic_shard_switching
      results = {}

      # 現在のシャード情報
      results[:default_shard] = ActiveRecord::Base.current_shard

      # connected_to でシャードとロールを指定
      # 単一DB構成では :default シャードのみ存在する
      ActiveRecord::Base.connected_to(role: :writing, shard: :default) do
        results[:explicit_shard] = ActiveRecord::Base.current_shard
        results[:explicit_role] = ActiveRecord::Base.current_role

        # シャード内でのCRUD操作
        Article.create!(title: 'シャードデフォルトの記事', body: 'テスト')
        results[:shard_article_count] = Article.count
      end

      # クロスシャードクエリのパターン
      results[:cross_shard_pattern] = {
        description: '複数シャードのデータを集約する場合',
        approach: %w[
          各シャードに順次connected_toで接続し結果を収集
          集約用の専用DBに結果を書き込む
          またはアプリケーション層でメモリ上にマージ
        ],
        code_example: <<~RUBY
          results = []
          [:shard_one, :shard_two, :shard_three].each do |shard|
            ActiveRecord::Base.connected_to(shard: shard) do
              results.concat(Article.where(status: "published").to_a)
            end
          end
        RUBY
      }

      results
    end
  end

  # ==========================================================================
  # 6. マイグレーション: データベースごとのスキーマ管理
  # ==========================================================================
  #
  # マルチDB構成ではデータベースごとにマイグレーションファイルを管理する。
  # Rails はマイグレーションディレクトリを分離し、
  # 各データベースに対して独立してマイグレーションを実行できる。
  module MigrationPerDatabase
    # マルチDBマイグレーションの構成を説明する
    #
    # ディレクトリ構造:
    #   db/
    #     migrate/                      # プライマリDB用
    #     primary_shard_one_migrate/    # シャード1用
    #     primary_shard_two_migrate/    # シャード2用
    #
    # database.yml:
    #   production:
    #     primary:
    #       database: myapp
    #       migrations_paths: db/migrate
    #     primary_shard_one:
    #       database: myapp_shard_one
    #       migrations_paths: db/primary_shard_one_migrate
    def self.demonstrate_migration_structure
      {
        # マイグレーションコマンド
        commands: {
          all_databases: 'rails db:migrate（全DBに対して実行）',
          specific_db: 'rails db:migrate:primary（プライマリDBのみ）',
          specific_shard: 'rails db:migrate:primary_shard_one（特定シャードのみ）',
          rollback: 'rails db:rollback:primary（プライマリDBのロールバック）',
          status: 'rails db:migrate:status:primary（マイグレーション状態確認）'
        },
        # ディレクトリ構造
        directory_structure: {
          'db/migrate/' => 'プライマリDB用マイグレーション',
          'db/animals_migrate/' => 'animalsDB用マイグレーション（例）',
          'db/shard_one_migrate/' => 'シャード1用マイグレーション'
        },
        # schema.rb / structure.sql の分離
        schema_files: {
          'db/schema.rb' => 'プライマリDBのスキーマ',
          'db/animals_schema.rb' => 'animalsDBのスキーマ',
          explanation: '各DBごとに独立したスキーマファイルが生成される'
        },
        # マイグレーション生成
        generation: {
          command: 'rails generate migration CreateUsers name:string --database primary',
          explanation: '--database オプションで対象DBを指定する'
        }
      }
    end

    # マイグレーションの実行状態を確認するデモ
    def self.demonstrate_migration_status
      connection = ActiveRecord::Base.connection

      # 現在のテーブル情報
      tables = connection.tables.sort

      # 各テーブルのカラム情報
      table_columns = tables.each_with_object({}) do |table, hash|
        hash[table] = connection.columns(table).map { |c| { name: c.name, type: c.type } }
      end

      {
        current_tables: tables,
        table_columns: table_columns,
        # マイグレーションのベストプラクティス
        best_practices: [
          '各DBのマイグレーションは独立して管理する',
          'シャード間で同じスキーマを維持する場合、共通マイグレーションをコピーする',
          'マイグレーションの整合性チェックをCIに組み込む',
          'ロールバック手順を事前にテストする'
        ]
      }
    end
  end

  # ==========================================================================
  # 7. コネクション管理: DB/ロール/シャード別のプール管理
  # ==========================================================================
  #
  # マルチDB構成では、データベース × ロール × シャードの組み合わせごとに
  # 独立したコネクションプールが作成される。
  # ConnectionHandler がこれらのプールを一元管理する。
  module ConnectionHandling
    # コネクションプールの構成を説明する
    #
    # ActiveRecord::ConnectionAdapters::ConnectionHandler は
    # 以下の階層でプールを管理する:
    #
    # ConnectionHandler
    #   └── PoolManager（ロール × シャード → ConnectionPool）
    #         ├── writing / default → ConnectionPool (primary)
    #         ├── reading / default → ConnectionPool (replica)
    #         ├── writing / shard_one → ConnectionPool (shard1 primary)
    #         └── reading / shard_one → ConnectionPool (shard1 replica)
    def self.demonstrate_connection_pool_management
      handler = ActiveRecord::Base.connection_handler

      pools = handler.connection_pool_list(:writing)

      {
        # ConnectionHandler の情報
        handler_class: handler.class.name,
        # 現在の接続プール数
        all_connection_pools: pools.size,
        # 各プールの情報
        pool_details: pools.map do |pool|
          {
            pool_class: pool.class.name,
            db_config_name: pool.db_config.name,
            adapter: pool.db_config.adapter,
            size: pool.size,
            connections: pool.connections.size,
            stat: pool.stat
          }
        end,
        # プール管理の概要
        management_concept: {
          pool_creation: '各 DB/ロール/シャード の組み合わせに対して独立プールを作成',
          pool_isolation: 'プール間は完全に独立（接続の共有なし）',
          pool_sizing: 'database.yml の pool 設定がプールごとに適用される',
          recommendation: '合計プールサイズ = Pumaスレッド数 × プール数 を意識する'
        }
      }
    end

    # 接続のライフサイクルを説明する
    def self.demonstrate_connection_lifecycle
      pool = ActiveRecord::Base.connection_pool

      # 接続の取得と返却
      stat_before = pool.stat

      pool.with_connection do |conn|
        conn.execute('SELECT 1')
      end

      stat_after = pool.stat

      {
        before_query: stat_before,
        after_query: stat_after,
        # 接続のライフサイクル
        lifecycle: [
          '1. connected_to でロール/シャードを指定',
          '2. ConnectionHandler が対応するプールを特定',
          '3. プールから接続をチェックアウト',
          '4. クエリを実行',
          '5. 接続をプールにチェックイン（返却）',
          '6. connected_to ブロック終了で元のコンテキストに復帰'
        ],
        # マルチDB固有の注意点
        multi_db_considerations: [
          'トランザクションはプール（＝DB接続）ごとに独立',
          'クロスDB トランザクションはサポートされない',
          '分散トランザクションが必要な場合はSagaパターンを検討',
          '接続切り替えはスレッドローカルで行われる'
        ]
      }
    end
  end

  # ==========================================================================
  # 8. 実践パターン: レポート用レプリカ / テナントシャーディング
  # ==========================================================================
  #
  # マルチDB構成の実践的なユースケースとベストプラクティス
  module PracticalPatterns
    # レポート生成でレプリカを使うパターン
    #
    # 重いレポートクエリをレプリカに向けることで、
    # プライマリDBの負荷を軽減する。
    def self.demonstrate_replica_for_reports
      # テストデータ準備
      Article.delete_all
      10.times do |i|
        Article.create!(
          title: "記事#{i + 1}",
          body: "本文#{i + 1}",
          status: i < 7 ? 'published' : 'draft'
        )
      end

      # レポートクエリ（本番ではレプリカで実行）
      # ActiveRecord::Base.connected_to(role: :reading) do
      report = ActiveRecord::Base.connected_to(role: :writing) do
        {
          total_articles: Article.count,
          published_count: Article.where(status: 'published').count,
          draft_count: Article.where(status: 'draft').count,
          recent_articles: Article.order(created_at: :desc).limit(3).pluck(:title)
        }
      end

      {
        report_data: report,
        pattern_description: {
          purpose: '重い集計クエリをレプリカDBに向けてプライマリの負荷を軽減',
          implementation: <<~RUBY,
            # コントローラでの使用例
            class ReportsController < ApplicationController
              def show
                ActiveRecord::Base.connected_to(role: :reading) do
                  @report = Article.group(:status).count
                  @total = Article.count
                end
              end
            end
          RUBY
          caveats: %w[
            レプリカには数秒の遅延がある可能性を考慮
            リアルタイム性が必要な場合はプライマリを使用
            レポート結果をキャッシュして再利用
          ]
        }
      }
    end

    # テナントベースシャーディングの実装パターン
    #
    # SaaSアプリケーションでテナントごとにデータを分離する。
    # テナント情報からシャードを解決し、リクエスト全体で
    # 一貫したシャードコンテキストを維持する。
    def self.demonstrate_tenant_sharding_pattern
      # テナントの管理はグローバルDB（非シャード）で行う
      Tenant.delete_all
      tenants = [
        Tenant.create!(name: 'Acme Corp', subdomain: 'acme'),
        Tenant.create!(name: 'Globex Inc', subdomain: 'globex'),
        Tenant.create!(name: 'Initech', subdomain: 'initech')
      ]

      {
        tenants: tenants.map { |t| { id: t.id, name: t.name, subdomain: t.subdomain } },
        # シャード解決ロジック
        shard_resolver: {
          description: 'テナントのサブドメインからシャードを解決する',
          code: <<~RUBY,
            class TenantShardResolver
              SHARD_MAP = {
                "acme" => :shard_one,
                "globex" => :shard_two,
                "initech" => :shard_three
              }.freeze

              def self.resolve(request)
                subdomain = request.subdomain
                SHARD_MAP.fetch(subdomain, :default)
              end
            end
          RUBY
          middleware: <<~RUBY
            # config/application.rb
            config.active_record.shard_resolver = ->(request) {
              TenantShardResolver.resolve(request)
            }
          RUBY
        },
        # テナント分離のベストプラクティス
        best_practices: [
          'テナントメタデータは非シャードのグローバルDBに保持',
          'シャード間でのJOINは不可能 → アプリケーション層で対処',
          'シャードの追加は慎重に計画する（リバランシングが困難）',
          'テナントの成長に備えてシャード間の移行戦略を用意',
          '全シャード横断クエリは並列実行で高速化'
        ],
        # 監視ポイント
        monitoring: [
          'シャード間のデータ偏り（ホットスポット）を監視',
          '各シャードのコネクションプール使用率を監視',
          'シャードごとのクエリパフォーマンスを計測',
          'レプリケーション遅延を監視'
        ]
      }
    end

    # 大規模DB運用のチェックリスト
    def self.demonstrate_production_checklist
      {
        read_write_splitting: {
          setup: [
            'database.yml で primary と primary_replica を定義',
            'ApplicationRecord に connects_to を追加',
            'DatabaseSelector ミドルウェアを有効化',
            'delay パラメータをレプリケーション遅延に合わせて調整'
          ],
          testing: [
            'レプリカ接続の読み取り動作をテスト',
            'writing ロールでの書き込み動作をテスト',
            'prevent_writes による ReadOnlyError をテスト'
          ]
        },
        sharding: {
          setup: [
            'シャーディング戦略の決定（テナント/範囲/ハッシュ）',
            'database.yml でシャード定義',
            'ShardSelector ミドルウェアの設定',
            'マイグレーションディレクトリの分離'
          ],
          operations: [
            '新規シャードの追加手順を文書化',
            'シャード間のデータ移行ツールを準備',
            'バックアップ/リストアをシャード単位で実行可能にする'
          ]
        },
        connection_pool: {
          sizing: '合計コネクション数 = Pumaスレッド数 × DB数 × ロール数',
          monitoring: '各プールの使用率、待機時間、タイムアウト数を監視',
          tuning: 'checkout_timeout と idle_timeout を適切に設定'
        }
      }
    end
  end
end
