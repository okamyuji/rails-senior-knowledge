# frozen_string_literal: true

# Zeitwerk オートローディングの内部構造を解説するモジュール
#
# ZeitwerkはRails 6以降のデフォルトオートローダーであり、
# ファイルパスから定数名への規約ベースのマッピングを提供する。
# このモジュールでは、Zeitwerkの仕組みをスタンドアロンで理解し、
# シニアエンジニアが知るべき内部動作を実例を通じて学ぶ。
module ZeitwerkAutoloader
  # ==========================================================================
  # 1. 命名規約: ファイルパスから定数名へのマッピング
  # ==========================================================================
  module NamingConvention
    # Zeitwerkの命名規約のコア: ファイルパスを定数名に変換する
    #
    # 規約:
    #   user.rb           → User
    #   user_profile.rb   → UserProfile
    #   html_parser.rb    → HtmlParser (デフォルト、カスタムinflectionで HTMLParser も可)
    #   concerns/fooable.rb → Concerns::Fooable
    #   api/v1/users.rb  → Api::V1::Users
    #
    # Zeitwerkはこの変換にString#camelizeに相当する処理を使う。
    # アンダースコアで分割し、各単語の先頭を大文字にする。
    def self.file_path_to_constant_name(relative_path)
      # .rb拡張子を除去
      path = relative_path.delete_suffix('.rb')

      # ディレクトリ区切りを :: に変換し、各セグメントをキャメルケースにする
      path.split('/').map { |segment| camelize(segment) }.join('::')
    end

    # アンダースコア区切りの文字列をキャメルケースに変換する
    # これはZeitwerkが内部で行うinflectionのデフォルト動作に相当する
    def self.camelize(term)
      term.split('_').map(&:capitalize).join
    end

    # 逆方向の変換: 定数名からファイルパスを推測する
    # Zeitwerkではこの逆方向は直接使わないが、理解の助けになる
    def self.constant_name_to_file_path(constant_name)
      constant_name
        .gsub('::', '/')
        .split('/')
        .map { |segment| segment.gsub(/([A-Z])/) { "_#{::Regexp.last_match(1).downcase}" }.sub(/\A_/, '') }
        .join('/') + '.rb'
    end

    # 複数のファイルパスとそれに対応する定数名のマッピング例を返す
    def self.demonstrate_mapping_examples
      examples = {
        'user.rb' => 'User',
        'user_profile.rb' => 'UserProfile',
        'html_parser.rb' => 'HtmlParser',
        'concerns/fooable.rb' => 'Concerns::Fooable',
        'api/v1/users_controller.rb' => 'Api::V1::UsersController',
        'middleware/rate_limiter.rb' => 'Middleware::RateLimiter',
        'services/payment/stripe_gateway.rb' => 'Services::Payment::StripeGateway'
      }

      examples.transform_values.with_index.each_with_object({}) do |(expected, _idx), result|
        path = examples.key(expected)
        computed = file_path_to_constant_name(path)
        result[path] = { expected: expected, computed: computed, match: expected == computed }
      end

      examples.map do |path, expected|
        computed = file_path_to_constant_name(path)
        { path: path, expected: expected, computed: computed, match: expected == computed }
      end
    end
  end

  # ==========================================================================
  # 2. Module#autoload: Zeitwerkが利用するRubyの組み込み機構
  # ==========================================================================
  module AutoloadPrimitive
    # Module#autoloadはRubyの組み込み機能で、定数が最初に参照された時に
    # 指定されたファイルを自動的にrequireする仕組みを提供する。
    #
    # Zeitwerkはこのプリミティブを活用して、ディレクトリ構造を走査し、
    # 各ファイルに対応する定数のautoloadを設定する。
    #
    # 使い方:
    #   module MyApp
    #     autoload :User, "/path/to/user.rb"
    #   end
    #   # MyApp::User を参照した瞬間に /path/to/user.rb が require される

    # Module#autoloadの基本動作をデモンストレーションする
    # 実際のファイルロードは行わず、autoloadの登録と確認の仕組みを示す
    def self.demonstrate_autoload_registration
      # 動的にモジュールを作成してautoloadを登録する
      test_module = Module.new

      # autoload を登録（実際のファイルパスを指定）
      # ここではダミーパスを使い、autoload?で登録状態を確認する
      test_module.autoload(:SomeClass, '/tmp/dummy_some_class.rb')

      {
        # autoload? で登録されたファイルパスを確認できる
        autoload_path: test_module.autoload?(:SomeClass),
        # 登録されていない定数はnilを返す
        unregistered: test_module.autoload?(:NotRegistered),
        # autoloadが登録されているかどうかの確認パターン
        is_registered: !test_module.autoload?(:SomeClass).nil?
      }
    end

    # autoloadとrequireの違いを説明する
    def self.explain_autoload_vs_require
      {
        autoload: {
          timing: '定数が参照された時点で遅延ロード',
          scope: '特定のモジュール/クラスのネームスペース内',
          mechanism: 'Module#autoload を使用',
          used_by: 'Zeitwerk（開発環境）'
        },
        require: {
          timing: '呼び出し時点で即座にロード',
          scope: 'グローバル（$LOADED_FEATURES に記録）',
          mechanism: 'Kernel#require を使用',
          used_by: '通常のRubyコード、eager loading時'
        },
        require_relative: {
          timing: '呼び出し時点で即座にロード',
          scope: '呼び出し元ファイルからの相対パス',
          mechanism: 'Kernel#require_relative を使用',
          used_by: 'Zeitwerkを使わないRubyプロジェクト'
        }
      }
    end

    # Zeitwerkがautoloadをどのように設定するかの疑似コード
    def self.demonstrate_zeitwerk_autoload_strategy
      # Zeitwerkが内部で行う処理の概念的な再現:
      #
      # 1. push_dirで指定されたルートディレクトリを走査
      # 2. 各.rbファイルに対して、パスから定数名を導出
      # 3. 対応するネームスペースモジュールにautoloadを登録
      #
      # 例: app/models/user.rb の場合
      #   Object.autoload(:User, "app/models/user.rb")
      #
      # 例: app/models/concerns/searchable.rb の場合
      #   まず Concerns モジュールを設定し、
      #   Concerns.autoload(:Searchable, "app/models/concerns/searchable.rb")

      steps = [
        '1. Zeitwerk::Loader.new でローダーインスタンスを作成',
        "2. loader.push_dir('app/models') でルートディレクトリを登録",
        '3. loader.setup を呼ぶと、ディレクトリを再帰的に走査',
        '4. 各ディレクトリに対応するモジュール（名前空間）を implicit に作成',
        '5. 各.rbファイルに対して Module#autoload を設定',
        '6. 定数が参照された時にファイルがrequireされる'
      ]

      { steps: steps }
    end
  end

  # ==========================================================================
  # 3. ローダーの設定と動作
  # ==========================================================================
  module LoaderSetup
    # Zeitwerk::Loaderの基本的な使い方を示す
    # （実際のファイルシステムに依存する部分はコメントで説明）
    def self.demonstrate_loader_configuration
      require 'zeitwerk'

      loader = Zeitwerk::Loader.new

      # ローダーの基本設定を確認
      {
        loader_class: loader.class.name,
        # tag はデバッグ時にローダーを識別するための名前
        default_tag: loader.tag,
        # Zeitwerkのバージョン情報
        zeitwerk_version: Zeitwerk::VERSION
      }
    end

    # Zeitwerk::Loaderの主要APIを一覧する
    def self.loader_api_overview
      {
        setup: {
          method: 'loader.setup',
          description: 'autoloadを設定する。push_dirの後に一度だけ呼ぶ',
          timing: 'アプリケーション起動時'
        },
        push_dir: {
          method: 'loader.push_dir(dir)',
          description: 'オートロード対象のルートディレクトリを追加',
          example: 'loader.push_dir("app/models")'
        },
        eager_load: {
          method: 'loader.eager_load',
          description: 'すべての管理下ファイルを即座にrequireする',
          timing: '本番環境の起動時'
        },
        reload: {
          method: 'loader.reload',
          description: '定数を削除してautoloadを再設定する',
          timing: '開発環境でコード変更後'
        },
        enable_reloading: {
          method: 'loader.enable_reloading',
          description: 'リロード機能を有効化する（setupの前に呼ぶ）',
          note: '本番環境では通常無効'
        },
        log: {
          method: 'loader.log!',
          description: 'デバッグログを有効化する',
          output: 'どのファイルがいつロードされたかを標準出力に表示'
        },
        ignore: {
          method: 'loader.ignore(path)',
          description: '特定のファイルやディレクトリをオートロード対象から除外',
          example: 'loader.ignore("app/models/concerns/legacy")'
        },
        collapse: {
          method: 'loader.collapse(dir)',
          description: 'ディレクトリを名前空間として扱わない（フラット化）',
          example: 'loader.collapse("app/models/concerns")'
        }
      }
    end

    # Zeitwerk::Loaderをスタンドアロンで実際にセットアップするデモ
    # 一時ディレクトリに構造を作り、autoloadの動作を確認する
    def self.demonstrate_standalone_loader
      require 'zeitwerk'
      require 'tmpdir'
      require 'fileutils'

      dir = Dir.mktmpdir('zeitwerk_demo')
      begin
        # テスト用のファイル構造を作成
        File.write(File.join(dir, 'greeter.rb'), <<~RUBY)
          class Greeter
            def self.hello
              "Hello from Zeitwerk!"
            end
          end
        RUBY

        # サブディレクトリ（名前空間）を作成
        # Zeitwerkの規約: services/ ディレクトリは Services モジュールに対応
        # 注意: Ractor が require をパッチする Ruby 3.4+ 環境では暗黙的な名前空間
        # （ディレクトリのみ）の autoload が正しく動作しないケースがあるため、
        # 名前空間モジュール用のファイルを明示的に作成する（collapse は使わない）
        FileUtils.mkdir_p(File.join(dir, 'services'))
        File.write(File.join(dir, 'services.rb'), <<~RUBY)
          module Services
          end
        RUBY
        File.write(File.join(dir, 'services', 'calculator.rb'), <<~RUBY)
          module Services
            class Calculator
              def self.add(a, b)
                a + b
              end
            end
          end
        RUBY

        # Zeitwerkローダーをセットアップ
        loader = Zeitwerk::Loader.new
        loader.tag = "demo_#{object_id}"
        loader.push_dir(dir)
        loader.setup

        # autoloadが設定されているので、定数参照でファイルがロードされる
        greeter_result = Greeter.hello
        calculator_result = Services::Calculator.add(3, 4)

        { greeter: greeter_result, calculator: calculator_result, dir: dir }
      ensure
        # クリーンアップ: ローダーをunloadしてから定数を削除
        loader&.unload
        Object.send(:remove_const, :Greeter) if defined?(Greeter)
        Object.send(:remove_const, :Services) if defined?(Services)
        FileUtils.remove_entry(dir) if dir
      end
    end
  end

  # ==========================================================================
  # 4. リローディング: 開発環境でのコード再読み込み
  # ==========================================================================
  module Reloading
    # Zeitwerkのリロードの仕組みを概念的に説明する
    #
    # リロードのステップ:
    # 1. loader.enable_reloading を setup 前に呼ぶ
    # 2. コード変更を検知（Rails は ActiveSupport::FileUpdateChecker を使用）
    # 3. loader.reload を呼ぶ
    # 4. Zeitwerk が管理している定数をすべて remove_const で削除
    # 5. autoload を再設定する
    # 6. 次に定数が参照された時に新しいコードがロードされる

    # リロードが必要な理由と仕組みを返す
    def self.explain_reloading
      {
        why: '開発中にサーバー再起動なしでコード変更を反映するため',
        mechanism: [
          '1. Zeitwerkが管理下の全定数を追跡している',
          '2. reload時、Object.send(:remove_const, :ClassName) で定数を削除',
          '3. Module#autoload を再登録する',
          '4. 次回の定数参照時に変更後のファイルがrequireされる'
        ],
        rails_integration: [
          'Rails は config.file_watcher (ActiveSupport::FileUpdateChecker) でファイル変更を検知',
          'リクエストごとに変更チェックが行われる',
          '変更があれば ActionDispatch::Reloader が reload を呼ぶ'
        ],
        caveats: [
          'グローバル変数やクラス変数に保持された古い参照は更新されない',
          '定数をキャッシュしている場合（変数に代入など）、古い参照が残る',
          'リロード後は定数を再参照する必要がある'
        ]
      }
    end

    # remove_const によるリロードの仕組みを疑似的にデモする
    def self.demonstrate_const_removal
      # 動的にモジュールとクラスを作成
      test_namespace = Module.new
      Object.const_set(:ReloadDemo, test_namespace)

      # 最初のバージョンのクラスを定義
      test_namespace.const_set(:MyService, Class.new do
        def self.version
          'v1'
        end
      end)

      version1 = ReloadDemo::MyService.version

      # リロードをシミュレート: 古い定数を削除
      test_namespace.send(:remove_const, :MyService)

      # 新しいバージョンのクラスを定義（実際にはファイルから再ロードされる）
      test_namespace.const_set(:MyService, Class.new do
        def self.version
          'v2'
        end
      end)

      version2 = ReloadDemo::MyService.version

      # クリーンアップ
      Object.send(:remove_const, :ReloadDemo)

      {
        before_reload: version1,
        after_reload: version2,
        reloaded: version1 != version2
      }
    end
  end

  # ==========================================================================
  # 5. Eager Loading: 本番環境での一括読み込み
  # ==========================================================================
  module EagerLoading
    # Eager Loading が本番環境で重要な理由を説明する
    def self.explain_eager_loading
      {
        why_production: {
          thread_safety: 'autoloadはスレッドセーフだが、eager loadingにより' \
                         '並行アクセスでの不要なロック競合を完全に排除できる',
          no_overhead: 'リクエスト処理中にファイルI/Oが発生しないため、' \
                       'レイテンシが安定する',
          copy_on_write: 'Unicorn/Pumaのfork前にeager loadすることで、' \
                         'CoW(Copy-on-Write)の恩恵を最大化できる',
          error_detection: '起動時にすべてのファイルをロードすることで、' \
                           '構文エラーや定数の不整合を早期発見できる'
        },
        rails_config: {
          production: 'config.eager_load = true',
          development: 'config.eager_load = false',
          test: "config.eager_load = ENV['CI'].present? (CIではtrue推奨)"
        },
        how_it_works: [
          '1. loader.eager_load を呼ぶ',
          '2. push_dirで登録された全ディレクトリを再帰走査',
          '3. 各.rbファイルを Kernel#require でロード',
          '4. autoloadの設定は不要になる（全定数がメモリ上に存在）'
        ]
      }
    end

    # eager_load のスタンドアロンデモ
    def self.demonstrate_eager_load
      require 'zeitwerk'
      require 'tmpdir'
      require 'fileutils'

      dir = Dir.mktmpdir('zeitwerk_eager_demo')
      begin
        # テスト用ファイルを作成
        File.write(File.join(dir, 'widget.rb'), <<~RUBY)
          class Widget
            LOADED_AT = Time.now
            def self.name_str
              "Widget"
            end
          end
        RUBY

        FileUtils.mkdir_p(File.join(dir, 'components'))
        File.write(File.join(dir, 'components.rb'), <<~RUBY)
          module Components
          end
        RUBY
        File.write(File.join(dir, 'components', 'button.rb'), <<~RUBY)
          module Components
            class Button
              LOADED_AT = Time.now
              def self.name_str
                "Components::Button"
              end
            end
          end
        RUBY

        loader = Zeitwerk::Loader.new
        loader.tag = "eager_demo_#{object_id}"
        loader.push_dir(dir)
        loader.setup

        # eager_load前: 定数はまだロードされていない
        widget_defined_before = Object.const_defined?(:Widget, false)

        # eager_load: すべてのファイルを即座にロード
        loader.eager_load

        # eager_load後: すべての定数が利用可能
        widget_defined_after = Object.const_defined?(:Widget, false)
        button_defined_after = Object.const_defined?(:Components) &&
                               Components.const_defined?(:Button, false)

        result = {
          before_eager_load: widget_defined_before,
          after_eager_load: widget_defined_after,
          nested_loaded: button_defined_after,
          widget_name: Widget.name_str,
          button_name: Components::Button.name_str
        }

        result
      ensure
        loader&.unload
        Object.send(:remove_const, :Widget) if defined?(Widget)
        Object.send(:remove_const, :Components) if defined?(Components)
        FileUtils.remove_entry(dir) if dir
      end
    end
  end

  # ==========================================================================
  # 6. カスタムInflection: 非標準の命名規約
  # ==========================================================================
  module CustomInflection
    # Zeitwerkのデフォルトinflectorはファイル名をキャメルケースに変換するが、
    # 特殊な略語（HTML, API, OAuth等）はデフォルトで正しく変換されない。
    #
    # 例: html_parser.rb → HtmlParser (デフォルト)
    #     html_parser.rb → HTMLParser (カスタムinflection後)

    # デフォルトinflectionとカスタムinflectionの違いを示す
    def self.demonstrate_inflection_differences
      default_cases = {
        'html_parser' => 'HtmlParser',
        'api_controller' => 'ApiController',
        'oauth_token' => 'OauthToken',
        'json_serializer' => 'JsonSerializer',
        'ssl_certificate' => 'SslCertificate'
      }

      custom_cases = {
        'html_parser' => 'HTMLParser',
        'api_controller' => 'APIController',
        'oauth_token' => 'OAuthToken',
        'json_serializer' => 'JSONSerializer',
        'ssl_certificate' => 'SSLCertificate'
      }

      {
        default_inflection: default_cases,
        custom_inflection: custom_cases,
        configuration_example: <<~CONFIG
          # Zeitwerk::Loader でカスタムinflectionを設定する方法:
          #
          # 方法1: inflect メソッドで個別にマッピング
          loader.inflector.inflect(
            "html_parser" => "HTMLParser",
            "api_controller" => "APIController",
            "oauth_token" => "OAuthToken"
          )
          #
          # 方法2: Rails の場合は config/initializers/inflections.rb で設定
          # ActiveSupport::Inflector.inflections do |inflect|
          #   inflect.acronym "HTML"
          #   inflect.acronym "API"
          #   inflect.acronym "OAuth"
          # end
        CONFIG
      }
    end

    # Zeitwerkのinflectorの種類を説明する
    def self.explain_inflector_types
      {
        default: {
          name: 'Zeitwerk::Inflector',
          behavior: 'String#capitalize で各単語の先頭を大文字化',
          example: 'html_parser → HtmlParser'
        },
        gem_inflector: {
          name: 'Zeitwerk::GemInflector',
          behavior: 'gem開発用。gemのルートファイル名を特別扱いする',
          example: 'my_gem.rb → MyGem (gemのエントリポイント)'
        },
        custom: {
          name: 'カスタムInflector',
          behavior: 'Zeitwerk::Inflector を継承して camelize をオーバーライド',
          example: <<~RUBY
            class MyInflector < Zeitwerk::Inflector
              def camelize(basename, _abspath)
                case basename
                when "html_parser" then "HTMLParser"
                when "api"         then "API"
                else super
                end
              end
            end
          RUBY
        }
      }
    end
  end

  # ==========================================================================
  # 7. デバッグ: autoloading問題の調査方法
  # ==========================================================================
  module Debugging
    # autoloading問題のデバッグ方法を体系的に説明する
    def self.debugging_techniques
      {
        log_activation: {
          description: 'Zeitwerkのログを有効化して、何がいつロードされるかを確認',
          code: 'Rails.autoloaders.main.log! # または Zeitwerk::Loader.new.log!',
          output_example: [
            'Zeitwerk@rails.main: autoload set for User, to be loaded from app/models/user.rb',
            'Zeitwerk@rails.main: constant User loaded from app/models/user.rb'
          ]
        },
        check_autoload_paths: {
          description: 'autoload対象のパスを確認',
          code: 'puts ActiveSupport::Dependencies.autoload_paths',
          rails_console: 'Rails.autoloaders.main.dirs'
        },
        name_mismatch_detection: {
          description: 'ファイル名と定数名の不一致を検出',
          common_errors: [
            'user_api.rb に class UserAPI を定義 → NG (UserApi が期待される)',
            'html_helper.rb に module HTMLHelper を定義 → NG (HtmlHelper が期待される)',
            '解決策: カスタムinflectionを設定するか、ファイル名を変更する'
          ]
        },
        eager_load_check: {
          description: 'eager_load で全ファイルを強制ロードして問題を検出',
          code: 'Rails.application.eager_load! # 起動時に全ファイルをロード',
          purpose: '定数名の不一致やrequireの循環を早期発見'
        },
        zeitwerk_check: {
          description: 'Zeitwerkの組み込みチェック機能',
          code: 'Zeitwerk::Loader.eager_load_all # 全ローダーのeager load',
          rails_task: 'bin/rails zeitwerk:check'
        }
      }
    end

    # よくあるautoloadingエラーとその解決策
    def self.common_errors_and_solutions
      {
        name_error: {
          error: 'NameError: uninitialized constant MyApp::UserAPI',
          cause: 'ファイル名 user_api.rb に対してZeitwerkは UserApi を期待するが、' \
                 'コードでは UserAPI と定義している',
          solutions: [
            '1. クラス名を UserApi に変更する',
            '2. loader.inflector.inflect("user_api" => "UserAPI") を設定する',
            '3. Railsの場合: inflect.acronym "API" を設定する'
          ]
        },
        expected_file_error: {
          error: 'Zeitwerk::NameError: expected file app/models/user.rb to define constant User',
          cause: 'user.rb ファイルが User 定数を定義していない',
          solutions: [
            '1. ファイル内のクラス/モジュール名を確認する',
            '2. namespace がファイルパスと一致しているか確認する',
            '3. typo がないか確認する'
          ]
        },
        circular_dependency: {
          error: 'Zeitwerk detects a circular dependency',
          cause: 'A → B → A の循環参照がある',
          solutions: [
            '1. 循環を断ち切るようにコードを再構成する',
            '2. メソッド内で定数を参照する（遅延参照）',
            '3. 共通部分を別のモジュールに抽出する'
          ]
        }
      }
    end

    # bin/rails zeitwerk:check の動作を説明する
    def self.explain_zeitwerk_check
      {
        command: 'bin/rails zeitwerk:check',
        purpose: 'Zeitwerkの命名規約に準拠しているかを全ファイルに対してチェック',
        what_it_does: [
          '1. 全autoloadパスを走査',
          '2. 各ファイルの期待される定数名を計算',
          '3. ファイルをrequireして定数が実際に定義されるか確認',
          '4. 不一致があればエラーを報告'
        ],
        when_to_use: [
          'classic autoloader (Rails 5以前) から zeitwerk への移行時',
          '新しいファイルを追加した時',
          'CIパイプラインで継続的にチェック'
        ],
        output_on_success: 'All is good!',
        output_on_failure: "expected file app/models/foo.rb to define constant Foo, but didn't"
      }
    end
  end

  # ==========================================================================
  # 8. Rails統合とEngine/Gem開発での活用
  # ==========================================================================
  module RailsIntegration
    # RailsアプリケーションにおけるZeitwerkの統合を説明する
    def self.explain_rails_autoloaders
      {
        main_autoloader: {
          access: 'Rails.autoloaders.main',
          manages: 'app/ 以下のコード (models, controllers, etc.)',
          reloadable: 'development環境ではtrue',
          description: 'アプリケーションコード用。開発中はリロード可能'
        },
        once_autoloader: {
          access: 'Rails.autoloaders.once',
          manages: 'config.autoload_once_paths に追加されたパス',
          reloadable: 'false（リロード不可）',
          description: 'リロードしてはいけないコード用（初期化子、ミドルウェア等）'
        },
        autoload_paths: {
          default: 'app/ の全サブディレクトリ',
          add_custom: "config.autoload_paths << Rails.root.join('lib')",
          description: 'Zeitwerkが監視するディレクトリのリスト'
        },
        eager_load_paths: {
          default: 'autoload_pathsと同じ',
          description: 'eager_load時にロードされるパス（本番環境で使用）'
        }
      }
    end

    # Engine開発でのZeitwerkの使い方を説明する
    def self.explain_engine_development
      {
        engine_autoloading: {
          description: 'Engineは自身のZeitwerkローダーを持つ',
          structure: [
            'my_engine/',
            '  app/',
            '    models/',
            '      my_engine/',
            '        widget.rb    → MyEngine::Widget',
            '    controllers/',
            '      my_engine/',
            '        widgets_controller.rb → MyEngine::WidgetsController'
          ],
          isolation: 'Engine の名前空間により、ホストアプリとの定数の衝突を防ぐ'
        },
        gem_development: {
          description: 'gem でも Zeitwerk をスタンドアロンで使える',
          setup_code: <<~RUBY,
            # lib/my_gem.rb
            require "zeitwerk"

            module MyGem
              class Error < StandardError; end

              class << self
                def loader
                  @loader ||= Zeitwerk::Loader.for_gem
                end
              end

              loader.setup
            end
          RUBY
          gem_inflector: 'Zeitwerk::Loader.for_gem は GemInflector を自動設定する',
          advantage: 'gem内部のrequire_relativeを排除し、ファイル追加時の手間を削減'
        }
      }
    end

    # collapseディレクティブの活用例を説明する
    def self.explain_collapse
      {
        purpose: 'ディレクトリを名前空間にマッピングしないようにする',
        example: {
          without_collapse: {
            structure: 'app/models/concerns/searchable.rb',
            constant: 'Concerns::Searchable',
            problem: 'Concernsモジュールは不要な名前空間'
          },
          with_collapse: {
            code: 'loader.collapse("app/models/concerns")',
            structure: 'app/models/concerns/searchable.rb',
            constant: 'Searchable',
            benefit: '不要な名前空間を排除してフラットにアクセスできる'
          }
        },
        rails_default: 'Railsではconcernsディレクトリはデフォルトでcollapseされる'
      }
    end
  end
end
