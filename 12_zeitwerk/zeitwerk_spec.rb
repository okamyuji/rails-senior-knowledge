# frozen_string_literal: true

require_relative 'zeitwerk'

RSpec.describe ZeitwerkAutoloader do
  describe ZeitwerkAutoloader::NamingConvention do
    describe '.file_path_to_constant_name' do
      it '単純なファイル名をキャメルケースの定数名に変換する' do
        expect(described_class.file_path_to_constant_name('user.rb')).to eq 'User'
        expect(described_class.file_path_to_constant_name('user_profile.rb')).to eq 'UserProfile'
        expect(described_class.file_path_to_constant_name('html_parser.rb')).to eq 'HtmlParser'
      end

      it 'ネストしたディレクトリパスを :: 区切りの定数名に変換する' do
        expect(described_class.file_path_to_constant_name('concerns/fooable.rb'))
          .to eq 'Concerns::Fooable'
        expect(described_class.file_path_to_constant_name('api/v1/users_controller.rb'))
          .to eq 'Api::V1::UsersController'
        expect(described_class.file_path_to_constant_name('services/payment/stripe_gateway.rb'))
          .to eq 'Services::Payment::StripeGateway'
      end
    end

    describe '.camelize' do
      it 'アンダースコア区切りの文字列をキャメルケースに変換する' do
        expect(described_class.camelize('user')).to eq 'User'
        expect(described_class.camelize('user_profile')).to eq 'UserProfile'
        expect(described_class.camelize('active_record')).to eq 'ActiveRecord'
      end
    end

    describe '.constant_name_to_file_path' do
      it '定数名からファイルパスを逆算する' do
        expect(described_class.constant_name_to_file_path('User')).to eq 'user.rb'
        expect(described_class.constant_name_to_file_path('UserProfile')).to eq 'user_profile.rb'
        expect(described_class.constant_name_to_file_path('Concerns::Fooable'))
          .to eq 'concerns/fooable.rb'
      end
    end

    describe '.demonstrate_mapping_examples' do
      it 'すべてのマッピング例が正しく変換されることを確認する' do
        examples = described_class.demonstrate_mapping_examples
        examples.each do |example|
          expect(example[:match]).to be(true),
                                     "#{example[:path]} の変換が不一致: 期待値=#{example[:expected]}, 実際=#{example[:computed]}"
        end
      end
    end
  end

  describe ZeitwerkAutoloader::AutoloadPrimitive do
    describe '.demonstrate_autoload_registration' do
      let(:result) { described_class.demonstrate_autoload_registration }

      it 'Module#autoloadの登録と確認ができることを検証する' do
        expect(result[:autoload_path]).to eq '/tmp/dummy_some_class.rb'
        expect(result[:unregistered]).to be_nil
        expect(result[:is_registered]).to be true
      end
    end

    describe '.explain_autoload_vs_require' do
      it 'autoload, require, require_relativeの3種類の説明を返す' do
        explanation = described_class.explain_autoload_vs_require
        expect(explanation.keys).to contain_exactly(:autoload, :require, :require_relative)
        expect(explanation[:autoload][:timing]).to include('遅延ロード')
        expect(explanation[:require][:timing]).to include('即座にロード')
      end
    end

    describe '.demonstrate_zeitwerk_autoload_strategy' do
      it 'Zeitwerkの内部処理ステップを返す' do
        result = described_class.demonstrate_zeitwerk_autoload_strategy
        expect(result[:steps]).to be_an(Array)
        expect(result[:steps].length).to eq 6
        expect(result[:steps].first).to include('Zeitwerk::Loader.new')
      end
    end
  end

  describe ZeitwerkAutoloader::LoaderSetup do
    describe '.demonstrate_loader_configuration' do
      let(:result) { described_class.demonstrate_loader_configuration }

      it 'Zeitwerk::Loaderのインスタンスが正しく作成されることを確認する' do
        expect(result[:loader_class]).to eq 'Zeitwerk::Loader'
        expect(result[:zeitwerk_version]).to be_a(String)
        expect(result[:zeitwerk_version]).not_to be_empty
      end
    end

    describe '.loader_api_overview' do
      it '主要APIの概要を返す' do
        api = described_class.loader_api_overview
        expect(api.keys).to include(:setup, :push_dir, :eager_load, :reload, :log, :ignore, :collapse)
        api.each_value do |info|
          expect(info).to have_key(:description)
        end
      end
    end

    describe '.demonstrate_standalone_loader' do
      it 'スタンドアロンのZeitwerkローダーでautoloadが動作することを確認する' do
        result = described_class.demonstrate_standalone_loader
        expect(result[:greeter]).to eq 'Hello from Zeitwerk!'
        expect(result[:calculator]).to eq 7
      end
    end
  end

  describe ZeitwerkAutoloader::Reloading do
    describe '.explain_reloading' do
      it 'リロードの仕組みと注意事項を返す' do
        explanation = described_class.explain_reloading
        expect(explanation[:why]).to include('コード変更を反映')
        expect(explanation[:mechanism]).to be_an(Array)
        expect(explanation[:caveats]).to be_an(Array)
        expect(explanation[:caveats]).not_to be_empty
      end
    end

    describe '.demonstrate_const_removal' do
      it '定数の削除と再定義によるリロードをシミュレートする' do
        result = described_class.demonstrate_const_removal
        expect(result[:before_reload]).to eq 'v1'
        expect(result[:after_reload]).to eq 'v2'
        expect(result[:reloaded]).to be true
      end
    end
  end

  describe ZeitwerkAutoloader::EagerLoading do
    describe '.explain_eager_loading' do
      it 'Eager Loadingの理由とRails設定を返す' do
        explanation = described_class.explain_eager_loading
        expect(explanation[:why_production]).to have_key(:thread_safety)
        expect(explanation[:why_production]).to have_key(:copy_on_write)
        expect(explanation[:rails_config][:production]).to include('eager_load = true')
        expect(explanation[:rails_config][:development]).to include('eager_load = false')
      end
    end

    describe '.demonstrate_eager_load' do
      it 'eager_loadにより全定数が一括ロードされることを確認する' do
        result = described_class.demonstrate_eager_load
        # eager_load前はautoload状態（定義されているがファイルはまだ未ロード）
        # eager_load後はすべてロード済み
        expect(result[:after_eager_load]).to be true
        expect(result[:nested_loaded]).to be true
        expect(result[:widget_name]).to eq 'Widget'
        expect(result[:button_name]).to eq 'Components::Button'
      end
    end
  end

  describe ZeitwerkAutoloader::CustomInflection do
    describe '.demonstrate_inflection_differences' do
      it 'デフォルトとカスタムのinflectionの違いを返す' do
        result = described_class.demonstrate_inflection_differences
        expect(result[:default_inflection]['html_parser']).to eq 'HtmlParser'
        expect(result[:custom_inflection]['html_parser']).to eq 'HTMLParser'
        expect(result[:configuration_example]).to include('inflect')
      end
    end

    describe '.explain_inflector_types' do
      it '3種類のinflectorを説明する' do
        types = described_class.explain_inflector_types
        expect(types.keys).to contain_exactly(:default, :gem_inflector, :custom)
        expect(types[:default][:name]).to eq 'Zeitwerk::Inflector'
        expect(types[:gem_inflector][:name]).to eq 'Zeitwerk::GemInflector'
      end
    end
  end

  describe ZeitwerkAutoloader::Debugging do
    describe '.debugging_techniques' do
      it 'デバッグ手法を体系的に返す' do
        techniques = described_class.debugging_techniques
        expect(techniques).to have_key(:log_activation)
        expect(techniques).to have_key(:name_mismatch_detection)
        expect(techniques).to have_key(:eager_load_check)
        expect(techniques).to have_key(:zeitwerk_check)
        expect(techniques[:log_activation][:code]).to include('log!')
      end
    end

    describe '.common_errors_and_solutions' do
      it 'よくあるエラーパターンと解決策を返す' do
        errors = described_class.common_errors_and_solutions
        expect(errors).to have_key(:name_error)
        expect(errors).to have_key(:expected_file_error)
        expect(errors).to have_key(:circular_dependency)

        errors.each_value do |error_info|
          expect(error_info).to have_key(:error)
          expect(error_info).to have_key(:cause)
          expect(error_info).to have_key(:solutions)
          expect(error_info[:solutions]).to be_an(Array)
        end
      end
    end

    describe '.explain_zeitwerk_check' do
      it 'bin/rails zeitwerk:check の使い方を説明する' do
        info = described_class.explain_zeitwerk_check
        expect(info[:command]).to eq 'bin/rails zeitwerk:check'
        expect(info[:what_it_does]).to be_an(Array)
        expect(info[:output_on_success]).to eq 'All is good!'
      end
    end
  end

  describe ZeitwerkAutoloader::RailsIntegration do
    describe '.explain_rails_autoloaders' do
      it 'mainとonceの2つのオートローダーを説明する' do
        info = described_class.explain_rails_autoloaders
        expect(info).to have_key(:main_autoloader)
        expect(info).to have_key(:once_autoloader)
        expect(info[:main_autoloader][:access]).to eq 'Rails.autoloaders.main'
        expect(info[:once_autoloader][:reloadable]).to include('false')
      end
    end

    describe '.explain_engine_development' do
      it 'EngineとGem開発でのZeitwerkの活用法を返す' do
        info = described_class.explain_engine_development
        expect(info).to have_key(:engine_autoloading)
        expect(info).to have_key(:gem_development)
        expect(info[:gem_development][:setup_code]).to include('Zeitwerk::Loader.for_gem')
      end
    end

    describe '.explain_collapse' do
      it 'collapseディレクティブの用途を説明する' do
        info = described_class.explain_collapse
        expect(info[:purpose]).to include('名前空間にマッピングしない')
        expect(info[:example][:without_collapse][:constant]).to eq 'Concerns::Searchable'
        expect(info[:example][:with_collapse][:constant]).to eq 'Searchable'
      end
    end
  end
end
