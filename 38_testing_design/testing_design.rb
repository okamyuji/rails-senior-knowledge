# frozen_string_literal: true

# テスト設計パターン（Testing Design Patterns）の解説モジュール
#
# テスト設計はソフトウェア品質の要であり、シニアエンジニアには
# テストピラミッド、ファクトリパターン、テストダブル、並列テスト、
# パフォーマンス最適化など、高度なテスト設計の知識が求められる。
#
# このモジュールでは、Rails/RSpec エコシステムにおける
# テスト設計の主要パターンを実例を通じて学ぶ。
module TestingDesign
  # ==========================================================================
  # 1. テストピラミッド: Unit → Integration → System テストの比率と戦略
  # ==========================================================================
  module TestPyramid
    # テストピラミッドは、テストの種類ごとに適切な数と実行コストのバランスを示す。
    #
    #        /\
    #       /  \        System（E2E）テスト: 少数・高コスト・遅い
    #      /    \       ブラウザ操作、全スタック結合
    #     /------\
    #    /        \     Integration テスト: 中程度
    #   /          \    コントローラー、API、サービス間連携
    #  /------------\
    # /              \  Unit テスト: 多数・低コスト・高速
    # ----------------  モデル、PORO、個別メソッド
    #
    # 推奨比率（目安）: Unit 70% / Integration 20% / System 10%

    # テストピラミッドの各層の特性を返す
    def self.pyramid_layers
      {
        unit: {
          ratio: '70%',
          speed: :fast,
          cost: :low,
          scope: '単一クラス・メソッドの振る舞い',
          examples: %w[モデルバリデーション サービスオブジェクト ヘルパーメソッド PORO],
          rails_tools: %w[RSpec::Rails::ModelSpec ActiveModel::Lint]
        },
        integration: {
          ratio: '20%',
          speed: :medium,
          cost: :medium,
          scope: '複数コンポーネントの連携',
          examples: %w[コントローラーテスト リクエストスペック メーラーテスト ジョブテスト],
          rails_tools: %w[RSpec::Rails::RequestSpec ActionDispatch::IntegrationTest]
        },
        system: {
          ratio: '10%',
          speed: :slow,
          cost: :high,
          scope: 'ユーザー視点でのエンドツーエンド動作',
          examples: %w[ログインフロー 購入フロー フォーム送信 JavaScript連携],
          rails_tools: %w[RSpec::Rails::SystemSpec Capybara Selenium]
        }
      }
    end

    # アンチパターン: 逆ピラミッド（アイスクリームコーン）
    # System テストに偏重すると、実行速度が著しく低下し、
    # テストの脆弱性（フレーキーテスト）が増加する。
    def self.anti_patterns
      {
        ice_cream_cone: {
          description: 'System テストに偏重した逆ピラミッド型',
          problems: [
            '実行時間が長大になる',
            'テストが不安定（フレーキー）になりやすい',
            'デバッグが困難',
            'CI/CD パイプラインのボトルネック化'
          ]
        },
        hourglass: {
          description: 'Unit と System のみで Integration が欠落',
          problems: [
            'コンポーネント間の不整合を見逃す',
            'System テストで初めてバグが発覚する',
            'フィードバックループが遅い'
          ]
        }
      }
    end
  end

  # ==========================================================================
  # 2. Fixtures vs Factories: トレードオフと使い分け
  # ==========================================================================
  module FixturesVsFactories
    # --- Fixtures（YAML固定データ）---
    # Rails 標準のテストデータ生成方式。
    # YAML ファイルにデータを定義し、テスト開始時にDBに一括ロードする。
    #
    # メリット:
    # - 高速（トランザクション内で一括INSERT、テストごとの生成なし）
    # - シンプル（YAMLの宣言的な記述）
    # - Rails 標準（追加 gem 不要）
    #
    # デメリット:
    # - ファイル間の暗黙的な依存関係が生まれやすい
    # - データの組み合わせが増えると管理が煩雑
    # - テストコード内でデータの前提条件が見えにくい

    # Fixtures の概念をシミュレートするクラス
    class FixtureLoader
      # 実際の Rails fixtures は YAML ファイルからDBに一括ロードする。
      # ここでは概念的なシミュレーションを行う。
      def initialize
        @fixtures = {}
      end

      # Fixture データの登録（YAML ファイル相当）
      def define(table_name, name, attributes)
        @fixtures[table_name] ||= {}
        @fixtures[table_name][name] = attributes.merge(_loaded_at: Time.now)
        self
      end

      # Fixture データの取得
      def get(table_name, name)
        @fixtures.dig(table_name, name)
      end

      # 登録済みの全データを返す
      def all(table_name)
        @fixtures.fetch(table_name, {})
      end

      # Fixture の特性情報
      def self.characteristics
        {
          loading_strategy: 'テスト開始前に一括ロード（BEGIN/ROLLBACK で高速化）',
          data_location: 'test/fixtures/*.yml',
          access_method: 'メソッド名でアクセス（例: users(:alice)）',
          performance: :high,
          flexibility: :low,
          best_for: '安定したマスターデータ、共通の参照データ'
        }
      end
    end

    # --- Factories（factory_bot パターン）---
    # factory_bot は必要なデータをテストごとに動的に生成する。
    #
    # メリット:
    # - テスト内でデータの前提条件が明確
    # - 柔軟なデータ生成（trait, sequence, association）
    # - テスト間の依存関係が少ない
    #
    # デメリット:
    # - Fixtures より低速（テストごとにINSERT）
    # - N+1 ファクトリ問題（関連オブジェクトの連鎖生成）
    # - 複雑なファクトリ定義が肥大化しやすい

    # Factory パターンのシンプルな実装
    # 実際の factory_bot の概念を純 Ruby で再現する
    class FactoryBot
      class << self
        def registry
          @registry ||= {}
        end

        # ファクトリの定義
        # factory_bot の FactoryBot.define { factory :user do ... end } に相当
        def define_factory(name, &block)
          registry[name] = block
          nil
        end

        # ファクトリからオブジェクトを生成
        # factory_bot の FactoryBot.build(:user) に相当
        def build(name, **overrides)
          factory = registry.fetch(name) { raise "Factory '#{name}' は未定義です" }
          attributes = factory.call
          attributes.merge(overrides)
        end

        # trait の概念: ファクトリのバリエーション定義
        # factory_bot では trait :admin do ... end で定義する
        def build_with_trait(name, trait_name, **overrides)
          base = build(name)
          trait_key = :"#{name}_#{trait_name}"
          trait_factory = registry.fetch(trait_key) do
            raise "Trait '#{trait_name}' for '#{name}' は未定義です"
          end
          base.merge(trait_factory.call).merge(overrides)
        end

        # sequence の概念: 連番やユニーク値の自動生成
        def sequence(name)
          @sequences ||= {}
          @sequences[name] ||= 0
          @sequences[name] += 1
          @sequences[name]
        end

        # レジストリのリセット（テスト間の独立性確保）
        def reset!
          @registry = {}
          @sequences = {}
        end
      end
    end

    # Fixtures と Factories の比較情報
    def self.comparison
      {
        fixtures: FixtureLoader.characteristics,
        factories: {
          loading_strategy: 'テストごとに動的生成（build/create）',
          data_location: 'spec/factories/*.rb',
          access_method: 'FactoryBot.create(:user) / FactoryBot.build(:user)',
          performance: :medium,
          flexibility: :high,
          best_for: 'テストごとに異なるデータが必要な場合、エッジケースの検証'
        },
        recommendation: [
          'マスターデータ（都道府県、ステータスコード等）は Fixtures が適切',
          'テスト固有のデータは Factories が適切',
          '大規模プロジェクトでは両者を併用する戦略が有効',
          'build_stubbed でDB書き込みを回避し高速化を図る'
        ]
      }
    end
  end

  # ==========================================================================
  # 3. Shared Examples: RSpec shared_examples による DRY テスト
  # ==========================================================================
  module SharedExamples
    # RSpec の shared_examples は、複数のコンテキストで
    # 共通する振る舞いをテストする仕組みである。
    #
    # 用途:
    # - ポリモーフィックな振る舞いの共通テスト
    # - Concern のテスト
    # - API レスポンスの共通検証
    # - 認可パターンの共通テスト

    # Timestampable な振る舞いを持つモジュール（Concern 相当）
    module Timestampable
      def touch_timestamps
        now = Time.now
        @created_at ||= now
        @updated_at = now
        self
      end

      def timestamps
        { created_at: @created_at, updated_at: @updated_at }
      end
    end

    # Soft-deletable な振る舞いを持つモジュール（Concern 相当）
    module SoftDeletable
      def soft_delete
        @deleted_at = Time.now
        self
      end

      def deleted?
        !@deleted_at.nil?
      end

      def restore
        @deleted_at = nil
        self
      end
    end

    # Validatable な振る舞いを持つモジュール
    module Validatable
      def valid?
        @errors = []
        validate
        @errors.empty?
      end

      def errors
        @errors ||= []
      end

      private

      def validate
        # サブクラスでオーバーライドする
      end
    end

    # 上記モジュールを組み合わせたモデルクラスの例
    class User
      include Timestampable
      include SoftDeletable
      include Validatable

      attr_accessor :name, :email

      def initialize(name: nil, email: nil)
        @name = name
        @email = email
        touch_timestamps
      end

      private

      def validate
        @errors << '名前は必須です' if @name.nil? || @name.empty?
        @errors << 'メールアドレスは必須です' if @email.nil? || @email.empty?
        @errors << 'メールアドレスの形式が不正です' if @email && !@email.include?('@')
      end
    end

    class Article
      include Timestampable
      include SoftDeletable
      include Validatable

      attr_accessor :title, :body

      def initialize(title: nil, body: nil)
        @title = title
        @body = body
        touch_timestamps
      end

      private

      def validate
        @errors << 'タイトルは必須です' if @title.nil? || @title.empty?
        @errors << '本文は必須です' if @body.nil? || @body.empty?
      end
    end

    # shared_examples で検証すべき共通振る舞いの一覧
    def self.shared_behavior_catalog
      {
        timestampable: {
          description: 'created_at/updated_at の自動設定',
          applicable_to: %w[User Article Comment Order]
        },
        soft_deletable: {
          description: '論理削除と復元の振る舞い',
          applicable_to: %w[User Article Comment]
        },
        validatable: {
          description: 'バリデーションエラーの検出と報告',
          applicable_to: %w[User Article Order Payment]
        }
      }
    end
  end

  # ==========================================================================
  # 4. テストダブル: Mock, Stub, Spy, Fake の使い分け
  # ==========================================================================
  module TestDoubles
    # テストダブルは、テスト対象の依存関係を置き換えるオブジェクトの総称。
    # Martin Fowler の分類に基づく4種類を解説する。
    #
    # 使い分けの指針:
    # - Stub: 固定値を返すだけ。入力に対する出力のみが重要な場合
    # - Mock: メソッド呼び出しの検証が目的。副作用の確認に使う
    # - Spy: 呼び出し履歴を記録。事後検証に使う
    # - Fake: 簡易的な実装を持つ。インメモリDBなど

    # --- Stub: 固定値を返すダブル ---
    # 外部API、DB、ファイルシステムなどの代替に使う
    class StubPaymentGateway
      def initialize(success: true, transaction_id: 'txn_stub_001')
        @success = success
        @transaction_id = transaction_id
      end

      def charge(amount:, currency: 'JPY')
        if @success
          { status: :success, transaction_id: @transaction_id, amount: amount, currency: currency }
        else
          { status: :failure, error: 'カード決済に失敗しました' }
        end
      end
    end

    # --- Mock: 呼び出しの期待を検証するダブル ---
    # RSpec では expect(obj).to receive(:method) で表現する
    class MockNotifier
      attr_reader :expected_calls, :actual_calls

      def initialize
        @expected_calls = []
        @actual_calls = []
      end

      def expect_call(method_name, with_args: nil)
        @expected_calls << { method: method_name, args: with_args }
        self
      end

      def notify(user:, message:)
        @actual_calls << { method: :notify, args: { user: user, message: message } }
        true
      end

      def verify!
        unmet = @expected_calls.reject do |expected|
          @actual_calls.any? { |actual| actual[:method] == expected[:method] }
        end
        raise "未呼び出しの期待: #{unmet.inspect}" unless unmet.empty?

        true
      end
    end

    # --- Spy: 呼び出し履歴を記録するダブル ---
    # RSpec では have_received マッチャーで事後検証する
    class SpyLogger
      attr_reader :call_log

      def initialize
        @call_log = []
      end

      def info(message)
        @call_log << { level: :info, message: message, at: Time.now }
      end

      def warn(message)
        @call_log << { level: :warn, message: message, at: Time.now }
      end

      def error(message)
        @call_log << { level: :error, message: message, at: Time.now }
      end

      def called_with?(level:, message_pattern: nil)
        @call_log.any? do |entry|
          entry[:level] == level &&
            (message_pattern.nil? || entry[:message].match?(message_pattern))
        end
      end

      def call_count(level: nil)
        if level
          @call_log.count { |entry| entry[:level] == level }
        else
          @call_log.size
        end
      end
    end

    # --- Fake: 簡易的な実装を持つダブル ---
    # インメモリDB、インメモリキャッシュなど
    class FakeCache
      def initialize
        @store = {}
        @stats = { hits: 0, misses: 0, writes: 0 }
      end

      def read(key)
        if @store.key?(key)
          entry = @store[key]
          if entry[:expires_at] && Time.now > entry[:expires_at]
            @store.delete(key)
            @stats[:misses] += 1
            nil
          else
            @stats[:hits] += 1
            entry[:value]
          end
        else
          @stats[:misses] += 1
          nil
        end
      end

      def write(key, value, expires_in: nil)
        expires_at = expires_in ? Time.now + expires_in : nil
        @store[key] = { value: value, expires_at: expires_at }
        @stats[:writes] += 1
        true
      end

      def delete(key)
        @store.delete(key)
        true
      end

      def clear
        @store.clear
        true
      end

      def stats
        @stats.dup
      end
    end

    # テストダブルの使い分けガイドライン
    def self.usage_guidelines
      {
        stub: {
          purpose: '固定値を返す（戻り値のみが重要）',
          rspec_syntax: 'allow(obj).to receive(:method).and_return(value)',
          use_when: '外部サービスの応答をシミュレートする場合',
          avoid_when: 'メソッドの呼び出し自体を検証したい場合'
        },
        mock: {
          purpose: 'メソッド呼び出しの期待を設定し検証する',
          rspec_syntax: 'expect(obj).to receive(:method).with(args)',
          use_when: '副作用（通知送信、ログ出力等）の発生を確認する場合',
          avoid_when: 'テストが実装の詳細に過度に依存する場合'
        },
        spy: {
          purpose: '呼び出し履歴を記録し事後検証する',
          rspec_syntax: 'expect(obj).to have_received(:method).with(args)',
          use_when: 'Arrange-Act-Assert パターンで事後検証したい場合',
          avoid_when: '呼び出し順序が重要でない単純なケース'
        },
        fake: {
          purpose: '簡易的な実装を提供する（インメモリDB等）',
          rspec_syntax: '独自クラスを作成して注入する',
          use_when: '実際のインフラストラクチャを使わずにテストしたい場合',
          avoid_when: 'Stub で十分な単純なケース'
        }
      }
    end
  end

  # ==========================================================================
  # 5. Database Cleaner 戦略: Transaction, Truncation, Deletion
  # ==========================================================================
  module DatabaseCleanerStrategies
    # テスト間のデータ独立性を確保するための DB クリーニング戦略。
    # Rails 標準のトランザクションフィクスチャと
    # database_cleaner gem の戦略を比較する。
    #
    # 選択基準:
    # 1. Transaction: 最速。単一接続のテストに最適。Rails デフォルト。
    # 2. Truncation: 複数接続が必要な場合（System テスト等）。中速。
    # 3. Deletion: Truncation の代替。外部キー制約がある場合に有効。

    # 各戦略の特性をシミュレートするクラス
    class CleaningStrategy
      STRATEGIES = {
        transaction: {
          mechanism: 'BEGIN → テストデータ操作 → ROLLBACK',
          speed: :fastest,
          supports_multiple_connections: false,
          supports_system_tests: false,
          data_visibility: '同一接続内のみ（他接続からは見えない）',
          rails_default: true,
          best_for: 'Unit テスト、Integration テスト（単一DB接続）'
        },
        truncation: {
          mechanism: 'TRUNCATE TABLE でテーブルを空にする',
          speed: :medium,
          supports_multiple_connections: true,
          supports_system_tests: true,
          data_visibility: '全接続から見える（コミット済み）',
          rails_default: false,
          best_for: 'System テスト、JavaScript 連携テスト'
        },
        deletion: {
          mechanism: 'DELETE FROM でレコードを削除する',
          speed: :slow,
          supports_multiple_connections: true,
          supports_system_tests: true,
          data_visibility: '全接続から見える（コミット済み）',
          rails_default: false,
          best_for: '外部キー制約が厳しい場合のフォールバック'
        }
      }.freeze

      def self.get(name)
        STRATEGIES.fetch(name) { raise "不明な戦略: #{name}" }
      end

      def self.all
        STRATEGIES
      end

      # 推奨構成: テスト種別ごとに戦略を切り替える
      def self.recommended_configuration
        {
          unit_tests: :transaction,
          integration_tests: :transaction,
          system_tests: :truncation,
          api_tests_with_external_process: :truncation,
          configuration_example: <<~RUBY
            # spec/support/database_cleaner.rb
            RSpec.configure do |config|
              config.use_transactional_fixtures = false

              config.before(:suite) do
                DatabaseCleaner.clean_with(:truncation)
              end

              config.before(:each) do
                DatabaseCleaner.strategy = :transaction
              end

              config.before(:each, type: :system) do
                DatabaseCleaner.strategy = :truncation
              end

              config.before(:each) do
                DatabaseCleaner.start
              end

              config.after(:each) do
                DatabaseCleaner.clean
              end
            end
          RUBY
        }
      end
    end
  end

  # ==========================================================================
  # 6. 並列テスト: Rails 6+ parallel test workers
  # ==========================================================================
  module ParallelTesting
    # Rails 6 以降、Minitest では parallelize メソッドで
    # テストの並列実行がサポートされている。
    # RSpec では parallel_tests gem を使用する。
    #
    # 並列テストの課題:
    # - データベースの分離（ワーカーごとに独立したDB）
    # - テスト順序の非決定性
    # - 共有リソース（ファイル、ポート）の競合
    # - ログの混在

    # 並列テストの設定情報
    def self.configuration
      {
        rails_minitest: {
          setup: 'parallelize(workers: :number_of_processors)',
          database: '各ワーカーが独自のDBを使用（test-database-0, test-database-1, ...）',
          method: :processes,
          alternative_method: :threads
        },
        rspec_parallel_tests: {
          setup: 'parallel_tests gem + database.yml の設定',
          command: 'bundle exec parallel_rspec spec/',
          database: 'TEST_ENV_NUMBER 環境変数でDB名を分離',
          database_yml_example: <<~YAML
            test:
              database: myapp_test<%= ENV['TEST_ENV_NUMBER'] %>
          YAML
        },
        ci_optimization: [
          'テストファイルの実行時間に基づく均等分割（--group-by runtime）',
          '失敗テストの再実行（--retry-failed）',
          'ワーカー数はCPUコア数に合わせる',
          'CI サービスの並列化機能との併用（CircleCI parallelism, GitHub Actions matrix）'
        ]
      }
    end

    # 並列テスト環境でのDB セットアップをシミュレート
    class ParallelDatabaseSetup
      attr_reader :worker_id, :database_name

      def initialize(worker_id:)
        @worker_id = worker_id
        @database_name = "app_test_#{worker_id}"
      end

      # 各ワーカーのDB作成をシミュレート
      def setup
        {
          worker_id: @worker_id,
          database: @database_name,
          steps: [
            "CREATE DATABASE #{@database_name}",
            "rails db:schema:load DATABASE=#{@database_name}",
            "rails db:seed DATABASE=#{@database_name} (必要な場合)"
          ]
        }
      end

      # 並列テスト時の注意点
      def self.caveats
        [
          'テスト間で共有する外部リソース（Redis, Elasticsearch）は分離が必要',
          'ファイルシステムへの書き込みはワーカーごとに異なるパスを使う',
          '固定ポートを使うサービスは動的ポート割り当てに変更する',
          'シードデータは各ワーカーDBに個別にロードする',
          'テスト順序の依存関係がある場合は並列化できない'
        ]
      end
    end
  end

  # ==========================================================================
  # 7. 時間テスト: travel_to による時間の凍結
  # ==========================================================================
  module TimeTesting
    # テストで時間を制御する手法。Rails の ActiveSupport::Testing::TimeHelpers
    # が提供する travel_to, freeze_time, travel を使用する。
    #
    # 時間依存のロジック（有効期限、期間計算、スケジューリング）のテストに必須。

    # 時間依存のビジネスロジックを持つクラス
    class Subscription
      attr_reader :plan, :started_at, :expires_at

      def initialize(plan:, started_at: nil, duration_days: 30)
        @plan = plan
        @started_at = started_at || Time.now
        @expires_at = @started_at + (duration_days * 24 * 60 * 60)
      end

      def active?(at: nil)
        check_time = at || Time.now
        check_time >= @started_at && check_time < @expires_at
      end

      def days_remaining(at: nil)
        check_time = at || Time.now
        return 0 unless active?(at: check_time)

        remaining_seconds = @expires_at - check_time
        (remaining_seconds / (24 * 60 * 60)).ceil
      end

      def expired?(at: nil)
        !active?(at: at)
      end

      # 期限間近（残り7日以内）の判定
      def expiring_soon?(at: nil, threshold_days: 7)
        remaining = days_remaining(at: at)
        remaining.positive? && remaining <= threshold_days
      end
    end

    # 営業日計算のユーティリティ
    class BusinessDayCalculator
      WEEKEND_DAYS = [0, 6].freeze # 日曜=0, 土曜=6

      def self.business_day?(date)
        !WEEKEND_DAYS.include?(date.wday)
      end

      def self.next_business_day(date)
        next_day = date + (24 * 60 * 60)
        next_day += (24 * 60 * 60) until business_day?(next_day)
        next_day
      end

      def self.add_business_days(date, days)
        result = date
        days.times do
          result = next_business_day(result)
        end
        result
      end
    end

    # 時間テストの手法一覧
    def self.time_testing_methods
      {
        freeze_time: {
          description: '現在時刻を固定する（Time.now が常に同じ値を返す）',
          rails_method: 'freeze_time { ... } または travel_to(Time.zone.local(2024, 1, 1)) { ... }',
          use_case: '特定の日時における振る舞いを検証する'
        },
        travel_to: {
          description: '指定した日時に移動する',
          rails_method: 'travel_to(Time.zone.local(2024, 12, 31, 23, 59, 59))',
          use_case: '年末処理、月次バッチ、有効期限チェックのテスト'
        },
        travel: {
          description: '現在時刻から相対的に時間を進める',
          rails_method: 'travel(3.days)',
          use_case: '期間経過後の振る舞いを段階的に検証する'
        },
        best_practices: [
          'テスト後に必ず travel_back で時間を戻す（after フックで自動化推奨）',
          'タイムゾーンを明示する（Time.zone.local を使う）',
          '境界値テスト: 期限直前・当日・翌日を網羅する',
          'freeze_time より travel_to の方が明示的で推奨'
        ]
      }
    end
  end

  # ==========================================================================
  # 8. テストパフォーマンス: プロファイリングと最適化
  # ==========================================================================
  module TestPerformance
    # テストスイート全体の実行速度を改善するための戦略。
    # 大規模プロジェクトでは CI のフィードバックループが
    # 開発生産性に直結するため、テストの高速化は重要課題である。

    # テストプロファイリングの手法
    def self.profiling_techniques
      {
        rspec_profiling: {
          command: 'bundle exec rspec --profile 10',
          description: '最も遅い10件のテストを表示する',
          output: '上位N件の遅いテスト例とその実行時間'
        },
        test_prof_gem: {
          description: 'test-prof gem による詳細プロファイリング',
          tools: {
            'TagProf' => 'タグ別の実行時間分析',
            'EventProf' => 'ActiveSupport::Notifications ベースのプロファイリング',
            'FactoryProf' => 'ファクトリの使用状況と生成コスト分析',
            'RSpecDissect' => 'before/let の実行時間の内訳分析'
          }
        },
        stackprof: {
          description: 'CPU プロファイリングでボトルネックを特定',
          use_case: '特定のテストが極端に遅い場合の原因調査'
        }
      }
    end

    # before(:all) vs before(:each) の違いとトレードオフ
    def self.before_hook_strategies
      {
        before_each: {
          scope: '各テスト例（it ブロック）の前に実行',
          isolation: :high,
          performance: :lower,
          data_mutation_risk: :none,
          recommended_for: 'テストデータの準備（デフォルト推奨）'
        },
        before_all: {
          scope: 'describe/context ブロック全体で一度だけ実行',
          isolation: :low,
          performance: :higher,
          data_mutation_risk: :high,
          recommended_for: '変更されない読み取り専用データ、重い初期化処理',
          caveats: [
            'テスト間でデータが共有されるため、変更すると後続テストに影響',
            'test-prof の before_all はトランザクション内で実行しロールバックする',
            'let_it_be（test-prof）は before_all の安全な代替'
          ]
        },
        let_it_be: {
          description: 'test-prof が提供する before_all ベースの安全な let',
          mechanism: 'before(:all) でデータを作成し、各テスト後にロールバック',
          performance: 'let よりも大幅に高速（特にDB操作を伴う場合）',
          syntax: 'let_it_be(:user) { create(:user) }'
        }
      }
    end

    # テスト高速化の戦略一覧
    def self.optimization_strategies
      [
        {
          strategy: 'build_stubbed の活用',
          description: 'DB書き込みなしでモデルオブジェクトを生成する',
          impact: :high,
          effort: :low
        },
        {
          strategy: '不要な関連オブジェクトの生成を避ける',
          description: 'ファクトリで必要最小限の関連のみ生成する',
          impact: :high,
          effort: :medium
        },
        {
          strategy: 'shared_context でセットアップを共有する',
          description: '共通のテストデータ準備を一箇所にまとめる',
          impact: :medium,
          effort: :low
        },
        {
          strategy: 'let_it_be でDBアクセスを削減する',
          description: 'test-prof の let_it_be で読み取り専用データを再利用する',
          impact: :high,
          effort: :low
        },
        {
          strategy: '並列テストの導入',
          description: 'parallel_tests gem で複数プロセスで実行する',
          impact: :very_high,
          effort: :medium
        },
        {
          strategy: 'テストのDB依存を減らす',
          description: '可能な限りPOROとして設計し、DBなしでテストする',
          impact: :high,
          effort: :high
        }
      ]
    end

    # テスト実行時間のシミュレーター
    class TestSuiteProfiler
      def initialize
        @results = []
      end

      def record(test_name, duration_ms)
        @results << { name: test_name, duration_ms: duration_ms }
      end

      def slowest(n = 5)
        @results.sort_by { |r| -r[:duration_ms] }.first(n)
      end

      def total_duration_ms
        @results.sum { |r| r[:duration_ms] }
      end

      def average_duration_ms
        return 0.0 if @results.empty?

        total_duration_ms.to_f / @results.size
      end

      def count
        @results.size
      end

      def summary
        {
          total_tests: count,
          total_duration_ms: total_duration_ms,
          average_duration_ms: average_duration_ms.round(2),
          slowest_5: slowest(5)
        }
      end
    end
  end

  # ==========================================================================
  # 9. コントラクトテスト: API 契約の検証パターン
  # ==========================================================================
  module ContractTesting
    # コントラクトテストは、API の提供者と消費者の間の
    # 「契約（スキーマ・レスポンス形式）」が守られていることを検証する。
    #
    # マイクロサービス環境では特に重要:
    # - サービス間のインターフェース変更を早期に検知
    # - 後方互換性の維持を保証
    # - 統合テストの一部を高速なコントラクトテストで代替

    # API スキーマの定義と検証
    class SchemaValidator
      def initialize(schema)
        @schema = schema
      end

      # レスポンスがスキーマに適合するか検証する
      def validate(data)
        errors = []
        validate_object(data, @schema, '', errors)
        { valid: errors.empty?, errors: errors }
      end

      private

      def validate_object(data, schema, path, errors)
        # 必須フィールドの検証
        required_fields = schema.fetch(:required, [])
        required_fields.each do |field|
          errors << "#{path}.#{field} は必須です" unless data.is_a?(Hash) && data.key?(field)
        end

        # 各フィールドの型検証
        properties = schema.fetch(:properties, {})
        properties.each do |field, field_schema|
          next unless data.is_a?(Hash) && data.key?(field)

          value = data[field]
          field_path = "#{path}.#{field}"
          validate_type(value, field_schema, field_path, errors)
        end
      end

      def validate_type(value, field_schema, path, errors)
        expected_type = field_schema[:type]

        type_valid = case expected_type
                     when :string then value.is_a?(String)
                     when :integer then value.is_a?(Integer)
                     when :float then value.is_a?(Float) || value.is_a?(Integer)
                     when :boolean then [true, false].include?(value)
                     when :array then value.is_a?(Array)
                     when :hash then value.is_a?(Hash)
                     when :nullable then true
                     else true
                     end

        errors << "#{path} の型が不正です（期待: #{expected_type}, 実際: #{value.class}）" unless type_valid

        # ネストしたオブジェクトの検証
        validate_object(value, field_schema, path, errors) if expected_type == :hash && field_schema[:properties]

        # 配列要素の検証
        return unless expected_type == :array && field_schema[:items] && value.is_a?(Array)

        value.each_with_index do |item, idx|
          validate_type(item, field_schema[:items], "#{path}[#{idx}]", errors)
        end
      end
    end

    # API コントラクトの定義例
    def self.example_user_api_contract
      {
        endpoint: 'GET /api/v1/users/:id',
        response_schema: {
          required: %i[id name email created_at],
          properties: {
            id: { type: :integer },
            name: { type: :string },
            email: { type: :string },
            created_at: { type: :string },
            avatar_url: { type: :nullable },
            posts_count: { type: :integer }
          }
        }
      }
    end

    # コントラクトテストのベストプラクティス
    def self.best_practices
      [
        'API のバージョニングとコントラクトテストを連携させる',
        'Consumer-Driven Contract Testing（消費者駆動型）を検討する',
        'Pact 等のツールでコントラクトを共有・検証する',
        'スキーマの後方互換性を CI で自動検証する',
        'レスポンスの型だけでなく、値の範囲や形式も検証する'
      ]
    end
  end

  # ==========================================================================
  # 10. Property-Based Testing: ランダム入力によるエッジケース発見
  # ==========================================================================
  module PropertyBasedTesting
    # Property-Based Testing（プロパティベーステスト）は、
    # 具体的な入力値ではなく「満たすべき性質（プロパティ）」を定義し、
    # テストフレームワークがランダムな入力を自動生成して検証する手法。
    #
    # Ruby では rspec-property gem や propcheck gem が利用可能。
    # QuickCheck（Haskell）、Hypothesis（Python）の Ruby 版に相当する。

    # プロパティの例: ソート関数の性質
    class SortProperties
      # 性質1: ソート結果の長さは入力と同じ
      def self.preserves_length?(input)
        input.sort.length == input.length
      end

      # 性質2: ソート結果は昇順に並んでいる
      def self.ordered?(input)
        sorted = input.sort
        sorted.each_cons(2).all? { |a, b| a <= b }
      end

      # 性質3: ソート結果は入力と同じ要素を含む
      def self.same_elements?(input)
        input.sort.tally == input.tally
      end

      # 性質4: 冪等性 — 二回ソートしても結果は同じ
      def self.idempotent?(input)
        input.sort == input.sort.sort
      end
    end

    # 簡易的なランダムデータジェネレーター
    class DataGenerator
      def self.integer(min: -1000, max: 1000)
        rand(min..max)
      end

      def self.string(length: nil)
        length ||= rand(0..50)
        Array.new(length) { rand(32..126).chr }.join
      end

      def self.array_of_integers(size: nil, min: -100, max: 100)
        size ||= rand(0..20)
        Array.new(size) { integer(min: min, max: max) }
      end

      def self.email
        user = string(length: rand(3..10)).gsub(/[^a-z]/, 'a')
        domain = string(length: rand(3..8)).gsub(/[^a-z]/, 'b')
        "#{user}@#{domain}.com"
      end

      # 境界値を含むジェネレーター
      def self.boundary_integers
        [0, 1, -1, (2**31) - 1, -(2**31), (2**63) - 1, -(2**63)]
      end
    end

    # Property-Based Testing の概念説明
    def self.concepts
      {
        traditional_testing: {
          approach: '具体的な入力 → 期待する出力 を列挙する',
          limitation: 'テスト作成者の想像力に依存する',
          example: 'expect(sort([3,1,2])).to eq([1,2,3])'
        },
        property_based_testing: {
          approach: '満たすべき性質を定義 → ランダム入力で検証する',
          advantage: '人間が思いつかないエッジケースを自動発見する',
          example: '任意の配列 arr に対し、arr.sort.length == arr.length'
        },
        shrinking: {
          description: '失敗した入力を自動的に最小化する',
          purpose: 'デバッグを容易にするため、最小の反例を提示する',
          example: '100要素の配列で失敗 → 3要素まで縮小して報告'
        },
        when_to_use: [
          '純粋関数（副作用なし）のテスト',
          'シリアライゼーション/デシリアライゼーションの往復検証',
          'パーサーのロバスト性検証',
          '数学的性質を持つアルゴリズム',
          'エンコード/デコードの対称性検証'
        ]
      }
    end
  end
end
