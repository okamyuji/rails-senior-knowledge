# frozen_string_literal: true

# ============================================================================
# Rails ブートプロセスと Railtie システム
# ============================================================================
#
# Railsアプリケーションの起動シーケンスと Railtie の仕組みを解説する。
#
# Railsのブートプロセスは以下の順序で進行する：
#   1. config/boot.rb    → Bundler のセットアップ（Gemfile の読み込み）
#   2. config/application.rb → Rails と gem の require、Application クラス定義
#   3. config/environment.rb → Rails.application.initialize! の呼び出し
#   4. Rails.application.initialize! → 全 initializer の実行
#
# Railtie はこのブートプロセスに参加するための公式インターフェースである。
# Engine や Application も Railtie を継承しており、Rails の拡張は
# すべて Railtie を通じて行われる。
#
# このモジュールでは、完全な Rails アプリケーションを起動せずに、
# Railtie のクラス階層、initializer の順序制御、設定オブジェクトの
# 仕組みを実例を通じて学ぶ。
# ============================================================================

require 'rails'

module RailsBootProcess
  # ==========================================================================
  # 1. ブートシーケンスの概要
  # ==========================================================================
  #
  # Railsの起動は3つのファイルを順番に実行することで進む：
  #
  # (1) config/boot.rb:
  #     ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)
  #     require "bundler/setup"
  #     → Bundler が Gemfile.lock に基づいて load path を設定
  #
  # (2) config/application.rb:
  #     require_relative "boot"
  #     require "rails/all"  # または個別の require
  #     Bundler.require(*Rails.groups)
  #     → 各 gem の railtie が自動的にロードされる
  #     → class Application < Rails::Application で設定を定義
  #
  # (3) config/environment.rb:
  #     require_relative "application"
  #     Rails.application.initialize!
  #     → すべての initializer が依存関係順に実行される
  #
  # Bundler.require は各 gem の lib/<gem_name>.rb を require する。
  # gem が Rails::Railtie のサブクラスを定義していれば、
  # そのサブクラスが自動的に Rails.application の initializer チェーンに参加する。

  module_function

  # ブートシーケンスの各ステップを説明するハッシュを返す
  def boot_sequence_overview
    {
      step_1_boot_rb: {
        file: 'config/boot.rb',
        description: 'Bundler のセットアップ。Gemfile.lock に基づき load path を構成',
        key_code: 'require "bundler/setup"'
      },
      step_2_application_rb: {
        file: 'config/application.rb',
        description: 'Rails フレームワークと gem の読み込み。Application クラスの定義',
        key_code: 'Bundler.require(*Rails.groups)'
      },
      step_3_environment_rb: {
        file: 'config/environment.rb',
        description: 'アプリケーションの初期化。全 initializer の実行',
        key_code: 'Rails.application.initialize!'
      },
      rails_version: Rails.version
    }
  end

  # ==========================================================================
  # 2. Railtie クラス階層
  # ==========================================================================
  #
  # Rails の拡張メカニズムは以下の継承チェーンに基づく：
  #
  #   Rails::Railtie
  #     └── Rails::Engine
  #           └── Rails::Application
  #
  # Railtie: 最も基本的な拡張ポイント。initializer, config, rake tasks を追加可能
  # Engine:  Railtie + ルーティング、ミドルウェア、アセットなどアプリケーション的機能
  # Application: Engine + 完全なアプリケーション機能（environments, credentials など）
  #
  # 重要: Rails::Railtie のサブクラスを定義するだけで、
  # そのクラスは自動的にブートプロセスに参加する（abstract_railtie でない限り）。
  # これは inherited フックによって実現される。

  def railtie_class_hierarchy
    {
      # クラス階層の確認
      railtie_is_class: Rails::Railtie.is_a?(Class),
      engine_superclass: Rails::Engine.superclass,
      application_superclass: Rails::Application.superclass,

      # 継承チェーン
      engine_inherits_railtie: Rails::Engine < Rails::Railtie,
      application_inherits_engine: Rails::Application < Rails::Engine,
      application_inherits_railtie: Rails::Application < Rails::Railtie,

      # ancestors チェーンで確認
      engine_ancestors_include_railtie: Rails::Engine.ancestors.include?(Rails::Railtie),
      application_ancestors_include_engine: Rails::Application.ancestors.include?(Rails::Engine),

      # Railtie が提供する主要機能
      railtie_provides: %i[
        initializer
        config
        rake_tasks
        generators
        console
        runner
        server
      ]
    }
  end

  # ==========================================================================
  # 3. カスタム Railtie の作成
  # ==========================================================================
  #
  # カスタム Railtie を作成することで、gem やプラグインが Rails の
  # ブートプロセスに参加できる。
  #
  # 主な用途：
  # - gem の初期化処理を Rails のブートプロセスに統合
  # - 設定を Rails.application.config に追加
  # - Rake タスクやジェネレーターの登録
  # - ミドルウェアの追加
  #
  # 注意: Rails::Railtie を継承したクラスを定義するだけで、
  # inherited フックにより自動的に Railtie として登録される。

  # デモ用のカスタム Railtie（実際の Rails ブートプロセスに参加する）
  class SampleRailtie < Rails::Railtie
    # 設定用の namespace を追加
    # Rails.application.config.sample_railtie でアクセス可能になる
    config.sample_railtie = ActiveSupport::OrderedOptions.new
    config.sample_railtie.enabled = true
    config.sample_railtie.log_level = :info

    # initializer の定義
    # 第一引数は一意な名前（通常は "gem名.機能名" の形式）
    initializer 'sample_railtie.configure' do |app|
      # app は Rails.application のインスタンス
      # ここでアプリケーション起動時の初期化処理を行う
      app.config.sample_railtie.initialized_at = Time.now.to_s
    end
  end

  def custom_railtie_demo
    # SampleRailtie が Railtie のサブクラスとして登録されていることを確認
    {
      is_railtie: SampleRailtie < Rails::Railtie,
      railtie_name: SampleRailtie.railtie_name,
      # Railtie はクラス名から自動的に railtie_name を生成する
      config_accessible: SampleRailtie.config.respond_to?(:sample_railtie),
      config_enabled: SampleRailtie.config.sample_railtie.enabled,
      config_log_level: SampleRailtie.config.sample_railtie.log_level
    }
  end

  # ==========================================================================
  # 4. Initializer の順序制御
  # ==========================================================================
  #
  # Rails の initializer は依存関係に基づいて順序が制御される。
  # 各 initializer は :before または :after オプションで、
  # 他の initializer との相対的な実行順序を指定できる。
  #
  # initializer の実行順序を決定するアルゴリズム：
  # 1. すべての Railtie から initializer を収集
  # 2. :before / :after の依存関係に基づいてトポロジカルソート
  # 3. 依存関係のない initializer はデフォルト順序（定義順）で実行
  #
  # 簡略化したモデルで依存関係による順序制御を再現する。

  # initializer の順序制御を模擬するクラス
  class InitializerOrdering
    Initializer = Struct.new(:name, :before, :after, :block, keyword_init: true)

    attr_reader :initializers, :execution_order

    def initialize
      @initializers = []
      @execution_order = []
    end

    # initializer を登録する
    # name: 一意な名前
    # before: この initializer の前に実行する initializer 名
    # after: この initializer の後に実行する initializer 名
    def add(name, before: nil, after: nil, &block)
      @initializers << Initializer.new(
        name: name,
        before: before,
        after: after,
        block: block || -> { name }
      )
    end

    # 依存関係に基づいて initializer をソートし実行する
    # トポロジカルソートの簡略化版
    def run_all
      sorted = topological_sort
      @execution_order = []
      sorted.each do |init|
        @execution_order << init.name
        init.block.call
      end
      @execution_order
    end

    private

    # トポロジカルソートで依存関係を解決する
    # :before と :after の制約を隣接リストとして表現し、
    # Kahn のアルゴリズムで順序を決定する
    def topological_sort
      # 名前からInitializerへのマップ
      by_name = @initializers.each_with_object({}) { |init, h| h[init.name] = init }

      # 隣接リストと入次数を構築
      # edge: a -> b は「a が b より先に実行される」ことを意味する
      adjacency = Hash.new { |h, k| h[k] = [] }
      in_degree = Hash.new(0)

      @initializers.each do |init|
        in_degree[init.name] ||= 0
        if init.after
          target = init.after.to_s
          if by_name.key?(target)
            adjacency[target] << init.name
            in_degree[init.name] += 1
          end
        end

        # :before が指定されている場合: この initializer が先に実行される
        next unless init.before

        target = init.before.to_s
        if by_name.key?(target)
          adjacency[init.name] << target
          in_degree[target] += 1
        end
      end

      # Kahn のアルゴリズム
      # 入次数0のノードからキューに追加し、順番に取り出す
      # 定義順を安定ソートとして維持するため、配列順を尊重する
      queue = @initializers.select { |init| in_degree[init.name].zero? }.map(&:name)
      result = []

      until queue.empty?
        current = queue.shift
        result << by_name[current]

        adjacency[current].each do |neighbor|
          in_degree[neighbor] -= 1
          queue << neighbor if in_degree[neighbor].zero?
        end
      end

      # 循環依存がある場合は残りを末尾に追加（エラーにはしない）
      remaining = @initializers.reject { |init| result.include?(init) }
      result + remaining
    end
  end

  def demonstrate_initializer_ordering
    ordering = InitializerOrdering.new

    # Rails の典型的な initializer パターンを再現
    ordering.add('load_environment_config')
    ordering.add('set_load_path', after: 'load_environment_config')
    ordering.add('set_autoload_paths', after: 'set_load_path')
    ordering.add('initialize_logger', after: 'load_environment_config')
    ordering.add('initialize_cache', after: 'initialize_logger')
    ordering.add('active_record.initialize_database', after: 'initialize_logger')

    execution_order = ordering.run_all

    {
      total_initializers: ordering.initializers.length,
      execution_order: execution_order,
      # 依存関係が正しく解決されていることを確認
      load_env_before_load_path: execution_order.index('load_environment_config') <
        execution_order.index('set_load_path'),
      load_path_before_autoload: execution_order.index('set_load_path') <
        execution_order.index('set_autoload_paths'),
      logger_before_cache: execution_order.index('initialize_logger') <
        execution_order.index('initialize_cache'),
      logger_before_db: execution_order.index('initialize_logger') <
        execution_order.index('active_record.initialize_database')
    }
  end

  # :before 制約のデモ
  def demonstrate_before_constraint
    ordering = InitializerOrdering.new

    ordering.add('middleware_setup')
    ordering.add('security_headers', before: 'middleware_setup')
    ordering.add('logging_middleware', before: 'middleware_setup')
    ordering.add('routes_setup', after: 'middleware_setup')

    execution_order = ordering.run_all

    {
      execution_order: execution_order,
      security_before_middleware: execution_order.index('security_headers') <
        execution_order.index('middleware_setup'),
      logging_before_middleware: execution_order.index('logging_middleware') <
        execution_order.index('middleware_setup'),
      middleware_before_routes: execution_order.index('middleware_setup') <
        execution_order.index('routes_setup')
    }
  end

  # ==========================================================================
  # 5. 設定オブジェクト（Configuration）
  # ==========================================================================
  #
  # Rails.application.config は Rails::Application::Configuration のインスタンスで、
  # アプリケーション全体の設定を保持する。
  #
  # 設定の流れ：
  # 1. config/application.rb で基本設定を定義
  # 2. config/environments/*.rb で環境固有の設定を上書き
  # 3. config/initializers/*.rb で追加設定
  # 4. Rails.application.initialize! で initializer が設定を参照して初期化
  #
  # ActiveSupport::OrderedOptions はハッシュのように振る舞うが、
  # メソッド呼び出しでアクセスできる便利なオブジェクトである。

  def demonstrate_configuration_object
    # ActiveSupport::OrderedOptions のデモ
    config = ActiveSupport::OrderedOptions.new
    config.database = ActiveSupport::OrderedOptions.new
    config.database.adapter = 'sqlite3'
    config.database.pool = 5
    config.cache_store = :memory_store

    # ネストした設定もメソッドチェーンでアクセス可能
    result = {
      config_class: config.class.name,
      database_adapter: config.database.adapter,
      database_pool: config.database.pool,
      cache_store: config.cache_store,
      # 存在しないキーにアクセスすると nil を返す（NoMethodError にならない）
      undefined_key: config.nonexistent_key,
      # respond_to? は true を返す（OrderedOptions の特性）
      responds_to_any: config.respond_to?(:any_key)
    }

    # Rails.application が存在する場合のみ実際の config クラスを確認
    result[:rails_config_class] = Rails.application.config.class.name if Rails.application

    result
  end

  # ==========================================================================
  # 6. 遅延読み込み（Lazy Loading）vs 積極的読み込み（Eager Loading）
  # ==========================================================================
  #
  # Development 環境:
  #   - autoload_paths からファイルを遅延読み込み（定数参照時に初めてロード）
  #   - config.eager_load = false
  #   - ファイル変更時にリロード可能（Zeitwerk の監視機能）
  #   - 起動が速い（必要なファイルだけロード）
  #
  # Production 環境:
  #   - config.eager_load = true
  #   - 起動時にすべてのファイルを一括読み込み
  #   - リクエスト処理中のファイルI/Oを回避（パフォーマンス向上）
  #   - スレッドセーフティの確保（定数の遅延定義による競合を防止）
  #   - Copy-on-Write によるメモリ共有（fork ベースのサーバーで有効）
  #
  # eager_load のフロー:
  #   Rails.application.initialize!
  #     → "eager_load!" initializer
  #     → Zeitwerk の各 loader に対して eager_load を実行
  #     → autoload_paths 配下のすべての .rb ファイルを require

  def demonstrate_loading_strategies
    result = {
      development: {
        eager_load: false,
        description: '遅延読み込み。定数を参照した時点で初めてファイルをロード',
        advantages: %w[起動が速い リロード可能 開発体験が良い],
        disadvantages: %w[初回リクエストが遅い スレッドセーフでない可能性]
      },
      production: {
        eager_load: true,
        description: '積極的読み込み。起動時にすべてのファイルを一括ロード',
        advantages: %w[リクエスト処理が速い スレッドセーフ CoW対応],
        disadvantages: %w[起動が遅い メモリ使用量が多い]
      }
    }

    # Rails.application が存在する場合のみ実際の設定を確認
    if Rails.application
      result[:current_eager_load] = Rails.application.config.eager_load
      result[:autoload_paths_count] = Rails.application.config.autoload_paths.length
    end

    result
  end

  # ==========================================================================
  # 7. 起動時間の最適化
  # ==========================================================================
  #
  # Railsアプリケーションの起動時間を短縮するための主要なテクニック：
  #
  # (a) Bootsnap:
  #   - Shopify が開発したブート高速化 gem
  #   - Ruby のバイトコード（ISeq）をキャッシュして再コンパイルを回避
  #   - $LOAD_PATH の探索結果をキャッシュして require を高速化
  #   - YAML ファイルのパース結果をキャッシュ
  #   - Rails 5.2 以降はデフォルトで有効
  #
  # (b) Spring（Rails 7.1 でデフォルトから除外）:
  #   - アプリケーションプロセスをバックグラウンドで維持するプリローダー
  #   - rails console, rails test などのコマンド起動を高速化
  #   - ファイル変更を検知して自動リロード
  #   - 注意: 本番環境では使用しない。開発環境でも問題を引き起こすことがある
  #
  # (c) その他のテクニック:
  #   - 不要な gem の削除（Gemfile の整理）
  #   - require: false で遅延読み込みにする gem を選別
  #   - initializer の非同期化（並行実行）
  #   - database.yml の接続プール設定の最適化

  def boot_optimization_techniques
    {
      bootsnap: {
        description: 'バイトコードと load path のキャッシュによる高速化',
        mechanism: 'ISeq キャッシュ + PATH キャッシュ + YAML キャッシュ',
        default_since: 'Rails 5.2',
        # Bootsnap がロードされているか確認
        loaded: defined?(Bootsnap) ? true : false
      },
      spring: {
        description: 'アプリケーションプリローダー（バックグラウンドプロセス）',
        status: 'Rails 7.1 でデフォルトから除外',
        reason: 'キャッシュ不整合やデバッグの困難さが問題視された'
      },
      gemfile_optimization: {
        description: '不要な gem の削除と require: false の活用',
        example: 'gem "sidekiq", require: false  # 必要な箇所で手動 require',
        impact: 'Bundler.require で読み込まれる gem 数を削減'
      },
      eager_load_control: {
        description: 'eager_load_paths の最適化',
        tip: '不要なディレクトリを eager_load_paths から除外して起動を高速化'
      }
    }
  end

  # ==========================================================================
  # 8. Railtie の initializer 一覧（実際の Rails initializer を確認）
  # ==========================================================================
  #
  # Rails.application.initializers で、登録されているすべての initializer を
  # 確認できる。各 initializer は name, before, after の情報を持つ。

  def list_rails_initializers
    return { error: 'Rails.application が存在しません。Rails アプリケーションを初期化してください。' } unless Rails.application

    initializers = Rails.application.initializers.to_a

    {
      total_count: initializers.length,
      # 最初の10個の initializer 名
      first_ten: initializers.first(10).map(&:name),
      # 最後の5個の initializer 名
      last_five: initializers.last(5).map(&:name),
      # 最初の20個の initializer 名をサンプルとして表示
      initializer_names_sample: initializers.first(20).map { |i| i.name.to_s }
    }
  end

  # ==========================================================================
  # 9. Bundler.require の仕組み
  # ==========================================================================
  #
  # Bundler.require は Gemfile に定義された gem を require する。
  # このプロセスで各 gem の lib/<gem_name>.rb が読み込まれ、
  # その中で Rails::Railtie のサブクラスが定義されていれば、
  # inherited フックにより自動的に Railtie として登録される。
  #
  # Rails.groups は環境に応じたグループを返す：
  #   Rails.groups # => [:default, "development"] (development 環境の場合)
  #
  # Gemfile での group 指定例：
  #   group :development do
  #     gem "web-console"  # development 環境でのみ require
  #   end

  def demonstrate_bundler_require
    {
      # Rails.groups の値（現在の環境に基づく）
      rails_groups: Rails.groups,
      rails_env: Rails.env,
      # Railtie のサブクラス一覧（Rails に登録されている Railtie）
      # Rails::Railtie.subclasses で直接のサブクラスを取得
      railtie_subclass_count: Rails::Railtie.subclasses.length,
      railtie_subclass_names: Rails::Railtie.subclasses.map(&:name).compact.sort,
      # inherited フックの仕組み
      inherited_hook_explanation: 'Rails::Railtie.inherited が呼ばれると ' \
                                  'サブクラスが自動的に Railtie として登録される'
    }
  end
end
