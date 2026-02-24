# frozen_string_literal: true

# テスト用の最小限 Rails アプリケーションをセットアップ
# Rails.application が nil だと一部のメソッドが動作しないため、
# SampleRailtie の定義前にアプリケーションを用意する必要がある。
require 'rails'
require 'action_controller/railtie'

# テスト用の最小限 Rails アプリケーション
# （まだ Rails.application が存在しない場合のみ定義する）
unless Rails.application
  class BootProcessTestApp < Rails::Application
    config.eager_load = false
    config.logger = Logger.new(nil)
    config.secret_key_base = SecureRandom.hex(64)
  end

  Rails.application.initialize!
end

require_relative 'rails_boot_process'

RSpec.describe RailsBootProcess do
  # ==========================================================================
  # 1. ブートシーケンスの概要
  # ==========================================================================
  describe '.boot_sequence_overview' do
    let(:result) { described_class.boot_sequence_overview }

    it 'ブートシーケンスの3ステップが正しく定義されていることを確認する' do
      expect(result[:step_1_boot_rb][:file]).to eq 'config/boot.rb'
      expect(result[:step_2_application_rb][:file]).to eq 'config/application.rb'
      expect(result[:step_3_environment_rb][:file]).to eq 'config/environment.rb'
    end

    it 'Rails バージョンが取得できることを確認する' do
      expect(result[:rails_version]).to match(/\A\d+\.\d+/)
    end
  end

  # ==========================================================================
  # 2. Railtie クラス階層
  # ==========================================================================
  describe '.railtie_class_hierarchy' do
    let(:result) { described_class.railtie_class_hierarchy }

    it 'Engine が Railtie を継承していることを確認する' do
      expect(result[:engine_superclass]).to eq Rails::Railtie
      expect(result[:engine_inherits_railtie]).to be true
    end

    it 'Application が Engine を継承していることを確認する' do
      expect(result[:application_superclass]).to eq Rails::Engine
      expect(result[:application_inherits_engine]).to be true
    end

    it 'Application が Railtie の子孫であることを確認する' do
      expect(result[:application_inherits_railtie]).to be true
      expect(result[:application_ancestors_include_engine]).to be true
    end

    it 'Railtie が提供する主要機能を確認する' do
      expect(result[:railtie_provides]).to include(:initializer, :config, :rake_tasks, :generators)
    end
  end

  # ==========================================================================
  # 3. カスタム Railtie
  # ==========================================================================
  describe '.custom_railtie_demo' do
    let(:result) { described_class.custom_railtie_demo }

    it 'SampleRailtie が Rails::Railtie のサブクラスであることを確認する' do
      expect(result[:is_railtie]).to be true
    end

    it 'railtie_name が自動生成されることを確認する' do
      expect(result[:railtie_name]).to be_a(String)
      expect(result[:railtie_name]).not_to be_empty
    end

    it 'カスタム設定がアクセス可能であることを確認する' do
      expect(result[:config_accessible]).to be true
      expect(result[:config_enabled]).to be true
      expect(result[:config_log_level]).to eq :info
    end
  end

  # ==========================================================================
  # 4. Initializer の順序制御
  # ==========================================================================
  describe '.demonstrate_initializer_ordering' do
    let(:result) { described_class.demonstrate_initializer_ordering }

    it 'すべての initializer が実行されることを確認する' do
      expect(result[:total_initializers]).to eq 6
      expect(result[:execution_order].length).to eq 6
    end

    it ':after 制約に基づいて依存関係が解決されることを確認する' do
      expect(result[:load_env_before_load_path]).to be true
      expect(result[:load_path_before_autoload]).to be true
    end

    it 'logger が cache と database の前に初期化されることを確認する' do
      expect(result[:logger_before_cache]).to be true
      expect(result[:logger_before_db]).to be true
    end
  end

  describe '.demonstrate_before_constraint' do
    let(:result) { described_class.demonstrate_before_constraint }

    it ':before 制約で指定した initializer より前に実行されることを確認する' do
      expect(result[:security_before_middleware]).to be true
      expect(result[:logging_before_middleware]).to be true
    end

    it ':after 制約も同時に正しく動作することを確認する' do
      expect(result[:middleware_before_routes]).to be true
    end
  end

  # ==========================================================================
  # 5. 設定オブジェクト
  # ==========================================================================
  describe '.demonstrate_configuration_object' do
    let(:result) { described_class.demonstrate_configuration_object }

    it 'ActiveSupport::OrderedOptions でネストした設定にアクセスできることを確認する' do
      expect(result[:config_class]).to eq 'ActiveSupport::OrderedOptions'
      expect(result[:database_adapter]).to eq 'sqlite3'
      expect(result[:database_pool]).to eq 5
      expect(result[:cache_store]).to eq :memory_store
    end

    it '存在しないキーにアクセスすると nil が返ることを確認する' do
      expect(result[:undefined_key]).to be_nil
    end

    it 'Rails.application.config のクラスが確認できることを確認する' do
      expect(result[:rails_config_class]).to include('Configuration')
    end
  end

  # ==========================================================================
  # 6. 遅延読み込み vs 積極的読み込み
  # ==========================================================================
  describe '.demonstrate_loading_strategies' do
    let(:result) { described_class.demonstrate_loading_strategies }

    it 'development 環境の戦略が正しく定義されていることを確認する' do
      expect(result[:development][:eager_load]).to be false
      expect(result[:development][:advantages]).to include('起動が速い')
    end

    it 'production 環境の戦略が正しく定義されていることを確認する' do
      expect(result[:production][:eager_load]).to be true
      expect(result[:production][:advantages]).to include('スレッドセーフ')
    end

    it '現在の eager_load 設定が取得できることを確認する' do
      expect(result[:current_eager_load]).to be false
    end
  end

  # ==========================================================================
  # 7. 起動時間の最適化
  # ==========================================================================
  describe '.boot_optimization_techniques' do
    let(:result) { described_class.boot_optimization_techniques }

    it 'Bootsnap の情報が正しく定義されていることを確認する' do
      expect(result[:bootsnap][:default_since]).to eq 'Rails 5.2'
      expect(result[:bootsnap][:loaded]).to eq(defined?(Bootsnap) ? true : false)
    end

    it 'Spring が Rails 7.1 でデフォルトから除外されたことを確認する' do
      expect(result[:spring][:status]).to include('7.1')
    end

    it 'Gemfile 最適化の require: false パターンが説明されていることを確認する' do
      expect(result[:gemfile_optimization][:example]).to include('require: false')
    end
  end

  # ==========================================================================
  # 8. InitializerOrdering クラスの単体テスト
  # ==========================================================================
  describe RailsBootProcess::InitializerOrdering do
    it '依存関係なしの initializer が定義順に実行されることを確認する' do
      ordering = described_class.new
      ordering.add('first')
      ordering.add('second')
      ordering.add('third')

      result = ordering.run_all
      expect(result).to eq %w[first second third]
    end

    it ':after 制約が正しく解決されることを確認する' do
      ordering = described_class.new
      ordering.add('database')
      ordering.add('migrations', after: 'database')
      ordering.add('seeds', after: 'migrations')

      result = ordering.run_all
      expect(result.index('database')).to be < result.index('migrations')
      expect(result.index('migrations')).to be < result.index('seeds')
    end

    it ':before 制約が正しく解決されることを確認する' do
      ordering = described_class.new
      ordering.add('main_setup')
      ordering.add('pre_check', before: 'main_setup')

      result = ordering.run_all
      expect(result.index('pre_check')).to be < result.index('main_setup')
    end

    it ':before と :after を組み合わせた複雑な依存関係が解決されることを確認する' do
      ordering = described_class.new
      ordering.add('core')
      ordering.add('pre_core', before: 'core')
      ordering.add('post_core', after: 'core')
      ordering.add('final', after: 'post_core')

      result = ordering.run_all
      expect(result.index('pre_core')).to be < result.index('core')
      expect(result.index('core')).to be < result.index('post_core')
      expect(result.index('post_core')).to be < result.index('final')
    end
  end

  # ==========================================================================
  # 9. Bundler.require の仕組み
  # ==========================================================================
  describe '.demonstrate_bundler_require' do
    let(:result) { described_class.demonstrate_bundler_require }

    it 'Rails.groups が配列を返すことを確認する' do
      expect(result[:rails_groups]).to be_an(Array)
      expect(result[:rails_groups]).to include(:default)
    end

    it 'Railtie サブクラスが登録されていることを確認する' do
      expect(result[:railtie_subclass_count]).to be_positive
      expect(result[:railtie_subclass_names]).to be_an(Array)
    end
  end

  # ==========================================================================
  # 10. 実際の Rails initializer
  # ==========================================================================
  describe '.list_rails_initializers' do
    let(:result) { described_class.list_rails_initializers }

    it 'Rails に登録されている initializer の一覧が取得できることを確認する' do
      expect(result[:total_count]).to be_positive
      expect(result[:first_ten]).to be_an(Array)
      expect(result[:first_ten].length).to be <= 10
    end

    it 'initializer 名がシンボルまたは文字列であることを確認する' do
      expect(result[:initializer_names_sample]).to all(be_a(String))
    end
  end
end
