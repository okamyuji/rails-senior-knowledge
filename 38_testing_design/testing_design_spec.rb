# frozen_string_literal: true

require_relative 'testing_design'

RSpec.describe TestingDesign do
  # ==========================================================================
  # 1. テストピラミッド
  # ==========================================================================
  describe TestingDesign::TestPyramid do
    describe '.pyramid_layers' do
      it 'テストピラミッドの3層（unit/integration/system）を定義する' do
        layers = described_class.pyramid_layers

        expect(layers).to have_key(:unit)
        expect(layers).to have_key(:integration)
        expect(layers).to have_key(:system)
      end

      it 'Unit テストが最も高速・低コストであること' do
        layers = described_class.pyramid_layers

        expect(layers[:unit][:speed]).to eq(:fast)
        expect(layers[:unit][:cost]).to eq(:low)
        expect(layers[:system][:speed]).to eq(:slow)
        expect(layers[:system][:cost]).to eq(:high)
      end
    end

    describe '.anti_patterns' do
      it 'アイスクリームコーンとアワーグラスのアンチパターンを列挙する' do
        patterns = described_class.anti_patterns

        expect(patterns).to have_key(:ice_cream_cone)
        expect(patterns).to have_key(:hourglass)
        expect(patterns[:ice_cream_cone][:problems]).not_to be_empty
        expect(patterns[:hourglass][:problems]).not_to be_empty
      end
    end
  end

  # ==========================================================================
  # 2. Fixtures vs Factories
  # ==========================================================================
  describe TestingDesign::FixturesVsFactories do
    describe TestingDesign::FixturesVsFactories::FixtureLoader do
      it 'Fixture データの登録と取得ができる' do
        loader = described_class.new
        loader.define(:users, :alice, name: 'Alice', email: 'alice@example.com')

        user = loader.get(:users, :alice)

        expect(user[:name]).to eq('Alice')
        expect(user[:email]).to eq('alice@example.com')
        expect(user[:_loaded_at]).to be_a(Time)
      end

      it '存在しないデータは nil を返す' do
        loader = described_class.new
        expect(loader.get(:users, :nobody)).to be_nil
      end
    end

    describe TestingDesign::FixturesVsFactories::FactoryBot do
      before do
        described_class.reset!
      end

      it 'ファクトリの定義と build ができる' do
        described_class.define_factory(:user) do
          { name: 'テストユーザー', email: 'test@example.com', role: :member }
        end

        user = described_class.build(:user)

        expect(user[:name]).to eq('テストユーザー')
        expect(user[:email]).to eq('test@example.com')
        expect(user[:role]).to eq(:member)
      end

      it 'override で属性を上書きできる' do
        described_class.define_factory(:user) do
          { name: 'デフォルト', email: 'default@example.com' }
        end

        user = described_class.build(:user, name: 'カスタム名')

        expect(user[:name]).to eq('カスタム名')
        expect(user[:email]).to eq('default@example.com')
      end

      it 'trait でバリエーションを生成できる' do
        described_class.define_factory(:user) do
          { name: '一般ユーザー', role: :member }
        end
        described_class.define_factory(:user_admin) do
          { role: :admin, admin_since: '2024-01-01' }
        end

        admin = described_class.build_with_trait(:user, :admin)

        expect(admin[:name]).to eq('一般ユーザー')
        expect(admin[:role]).to eq(:admin)
        expect(admin[:admin_since]).to eq('2024-01-01')
      end

      it 'sequence でユニークな連番を生成できる' do
        3.times { described_class.sequence(:user_id) }
        next_id = described_class.sequence(:user_id)

        expect(next_id).to eq(4)
      end
    end
  end

  # ==========================================================================
  # 3. Shared Examples — 共通振る舞いの DRY テスト
  # ==========================================================================
  # shared_examples: Timestampable な振る舞いの共通テスト
  RSpec.shared_examples 'timestampable' do
    it 'タイムスタンプ（created_at/updated_at）を持つ' do
      timestamps = subject.timestamps

      expect(timestamps[:created_at]).to be_a(Time)
      expect(timestamps[:updated_at]).to be_a(Time)
    end

    it 'touch_timestamps で updated_at が更新される' do
      original = subject.timestamps[:updated_at]
      sleep(0.01) # 時間差を作る
      subject.touch_timestamps
      updated = subject.timestamps[:updated_at]

      expect(updated).to be >= original
    end
  end

  # shared_examples: SoftDeletable な振る舞いの共通テスト
  RSpec.shared_examples 'soft_deletable' do
    it '論理削除と復元ができる' do
      expect(subject.deleted?).to be false

      subject.soft_delete
      expect(subject.deleted?).to be true

      subject.restore
      expect(subject.deleted?).to be false
    end
  end

  describe TestingDesign::SharedExamples::User do
    subject { described_class.new(name: 'テスト太郎', email: 'taro@example.com') }

    # 共通振る舞いを shared_examples で検証
    it_behaves_like 'timestampable'
    it_behaves_like 'soft_deletable'

    it 'バリデーションで有効なデータを受け入れる' do
      expect(subject.valid?).to be true
      expect(subject.errors).to be_empty
    end

    it '名前なしでバリデーションエラーになる' do
      user = described_class.new(name: '', email: 'test@example.com')

      expect(user.valid?).to be false
      expect(user.errors).to include('名前は必須です')
    end

    it 'メール形式不正でバリデーションエラーになる' do
      user = described_class.new(name: 'テスト', email: 'invalid-email')

      expect(user.valid?).to be false
      expect(user.errors).to include('メールアドレスの形式が不正です')
    end
  end

  describe TestingDesign::SharedExamples::Article do
    subject { described_class.new(title: 'テスト記事', body: '本文です') }

    # 同じ shared_examples を別のクラスにも適用
    it_behaves_like 'timestampable'
    it_behaves_like 'soft_deletable'

    it 'タイトルなしでバリデーションエラーになる' do
      article = described_class.new(title: '', body: '本文あり')

      expect(article.valid?).to be false
      expect(article.errors).to include('タイトルは必須です')
    end
  end

  # ==========================================================================
  # 4. テストダブル: Mock, Stub, Spy, Fake
  # ==========================================================================
  describe TestingDesign::TestDoubles do
    describe TestingDesign::TestDoubles::StubPaymentGateway do
      it 'Stub: 成功時の固定レスポンスを返す' do
        gateway = described_class.new(success: true, transaction_id: 'txn_123')

        result = gateway.charge(amount: 5000)

        expect(result[:status]).to eq(:success)
        expect(result[:transaction_id]).to eq('txn_123')
        expect(result[:amount]).to eq(5000)
      end

      it 'Stub: 失敗時のエラーレスポンスを返す' do
        gateway = described_class.new(success: false)

        result = gateway.charge(amount: 5000)

        expect(result[:status]).to eq(:failure)
        expect(result[:error]).to include('失敗')
      end
    end

    describe TestingDesign::TestDoubles::MockNotifier do
      it 'Mock: 期待された呼び出しを検証できる' do
        notifier = described_class.new
        notifier.expect_call(:notify)

        notifier.notify(user: 'alice', message: '注文完了')

        expect(notifier.verify!).to be true
      end

      it 'Mock: 未呼び出しの期待があればエラーを発生させる' do
        notifier = described_class.new
        notifier.expect_call(:notify)

        # notify を呼ばないまま検証
        expect { notifier.verify! }.to raise_error(/未呼び出しの期待/)
      end
    end

    describe TestingDesign::TestDoubles::SpyLogger do
      it 'Spy: 呼び出し履歴を記録し事後検証できる' do
        logger = described_class.new

        logger.info('処理開始')
        logger.warn('注意事項あり')
        logger.error('エラー発生')

        expect(logger.call_count).to eq(3)
        expect(logger.call_count(level: :error)).to eq(1)
        expect(logger.called_with?(level: :warn, message_pattern: /注意/)).to be true
        expect(logger.called_with?(level: :info, message_pattern: /開始/)).to be true
      end
    end

    describe TestingDesign::TestDoubles::FakeCache do
      it 'Fake: インメモリキャッシュとして読み書きできる' do
        cache = described_class.new

        cache.write('user:1', { name: 'Alice' })
        result = cache.read('user:1')

        expect(result).to eq({ name: 'Alice' })
        expect(cache.stats[:writes]).to eq(1)
        expect(cache.stats[:hits]).to eq(1)
      end

      it 'Fake: 存在しないキーは nil を返し miss としてカウントする' do
        cache = described_class.new

        result = cache.read('nonexistent')

        expect(result).to be_nil
        expect(cache.stats[:misses]).to eq(1)
      end

      it 'Fake: delete と clear が機能する' do
        cache = described_class.new
        cache.write('key1', 'value1')
        cache.write('key2', 'value2')

        cache.delete('key1')
        expect(cache.read('key1')).to be_nil

        cache.clear
        expect(cache.read('key2')).to be_nil
      end
    end

    # RSpec 標準のテストダブル機能のデモンストレーション
    describe 'RSpec 標準のテストダブル機能' do
      it 'double + allow で Stub を実現する' do
        payment_service = double('PaymentService')
        allow(payment_service).to receive(:charge).and_return(status: :success)

        result = payment_service.charge(amount: 1000)

        expect(result[:status]).to eq(:success)
      end

      it 'expect(...).to receive で Mock を実現する' do
        notifier = double('Notifier')
        expect(notifier).to receive(:send_email).with('user@example.com', '件名')

        notifier.send_email('user@example.com', '件名')
      end

      it 'spy + have_received で Spy を実現する' do
        logger = spy('Logger')

        logger.info('テストメッセージ')
        logger.warn('警告メッセージ')

        expect(logger).to have_received(:info).with('テストメッセージ')
        expect(logger).to have_received(:warn).with('警告メッセージ')
      end

      it 'instance_double で検証付きダブルを作成する' do
        # 実在するクラスのインターフェースに基づくダブル
        # 存在しないメソッドを stub しようとするとエラーになる
        stub_gateway = instance_double(
          TestingDesign::TestDoubles::StubPaymentGateway,
          charge: { status: :success }
        )

        result = stub_gateway.charge(amount: 3000)
        expect(result[:status]).to eq(:success)
      end
    end
  end

  # ==========================================================================
  # 5. Database Cleaner 戦略
  # ==========================================================================
  describe TestingDesign::DatabaseCleanerStrategies::CleaningStrategy do
    describe '.get' do
      it 'transaction 戦略の特性を取得できる' do
        strategy = described_class.get(:transaction)

        expect(strategy[:speed]).to eq(:fastest)
        expect(strategy[:supports_multiple_connections]).to be false
        expect(strategy[:rails_default]).to be true
      end

      it 'truncation 戦略が System テストをサポートする' do
        strategy = described_class.get(:truncation)

        expect(strategy[:supports_system_tests]).to be true
        expect(strategy[:supports_multiple_connections]).to be true
      end
    end

    describe '.recommended_configuration' do
      it 'テスト種別ごとの推奨戦略を返す' do
        config = described_class.recommended_configuration

        expect(config[:unit_tests]).to eq(:transaction)
        expect(config[:system_tests]).to eq(:truncation)
        expect(config[:configuration_example]).to include('DatabaseCleaner')
      end
    end
  end

  # ==========================================================================
  # 6. 並列テスト
  # ==========================================================================
  describe TestingDesign::ParallelTesting do
    describe '.configuration' do
      it 'Rails Minitest と RSpec の並列テスト設定を返す' do
        config = described_class.configuration

        expect(config).to have_key(:rails_minitest)
        expect(config).to have_key(:rspec_parallel_tests)
        expect(config).to have_key(:ci_optimization)
        expect(config[:ci_optimization]).to be_an(Array)
      end
    end

    describe TestingDesign::ParallelTesting::ParallelDatabaseSetup do
      it 'ワーカーごとに異なるDB名を生成する' do
        worker_0 = described_class.new(worker_id: 0)
        worker_1 = described_class.new(worker_id: 1)

        expect(worker_0.database_name).to eq('app_test_0')
        expect(worker_1.database_name).to eq('app_test_1')
        expect(worker_0.database_name).not_to eq(worker_1.database_name)
      end

      it 'セットアップ手順に CREATE DATABASE が含まれる' do
        setup = described_class.new(worker_id: 2).setup

        expect(setup[:steps]).to be_an(Array)
        expect(setup[:steps].first).to include('CREATE DATABASE')
        expect(setup[:database]).to eq('app_test_2')
      end
    end
  end

  # ==========================================================================
  # 7. 時間テスト
  # ==========================================================================
  describe TestingDesign::TimeTesting::Subscription do
    it '有効期間内であれば active? が true を返す' do
      now = Time.new(2024, 6, 1, 0, 0, 0)
      sub = described_class.new(plan: :premium, started_at: now, duration_days: 30)

      check = Time.new(2024, 6, 15, 0, 0, 0)
      expect(sub.active?(at: check)).to be true
    end

    it '有効期限切れ後は expired? が true を返す' do
      now = Time.new(2024, 6, 1, 0, 0, 0)
      sub = described_class.new(plan: :basic, started_at: now, duration_days: 30)

      after_expiry = Time.new(2024, 7, 2, 0, 0, 0)
      expect(sub.expired?(at: after_expiry)).to be true
    end

    it '残り日数を正しく計算する' do
      now = Time.new(2024, 6, 1, 0, 0, 0)
      sub = described_class.new(plan: :premium, started_at: now, duration_days: 30)

      check = Time.new(2024, 6, 25, 0, 0, 0)
      expect(sub.days_remaining(at: check)).to eq(6)
    end

    it '期限間近（7日以内）を検知する' do
      now = Time.new(2024, 6, 1, 0, 0, 0)
      sub = described_class.new(plan: :premium, started_at: now, duration_days: 30)

      # 残り5日 → expiring_soon
      near_expiry = Time.new(2024, 6, 26, 0, 0, 0)
      expect(sub.expiring_soon?(at: near_expiry)).to be true

      # 残り15日 → まだ大丈夫
      far_from_expiry = Time.new(2024, 6, 16, 0, 0, 0)
      expect(sub.expiring_soon?(at: far_from_expiry)).to be false
    end
  end

  describe TestingDesign::TimeTesting::BusinessDayCalculator do
    it '平日を営業日と判定する' do
      # 2024年6月3日は月曜日
      monday = Time.new(2024, 6, 3)
      expect(described_class.business_day?(monday)).to be true
    end

    it '土日を営業日でないと判定する' do
      # 2024年6月1日は土曜日
      saturday = Time.new(2024, 6, 1)
      expect(described_class.business_day?(saturday)).to be false

      # 2024年6月2日は日曜日
      sunday = Time.new(2024, 6, 2)
      expect(described_class.business_day?(sunday)).to be false
    end

    it '営業日を加算して正しい日付を返す' do
      # 2024年6月3日（月）+ 5営業日 = 2024年6月10日（月）
      monday = Time.new(2024, 6, 3)
      result = described_class.add_business_days(monday, 5)

      expect(result.day).to eq(10)
      expect(result.month).to eq(6)
    end
  end

  # ==========================================================================
  # 8. テストパフォーマンス
  # ==========================================================================
  describe TestingDesign::TestPerformance::TestSuiteProfiler do
    it 'テスト結果を記録し、最も遅いテストを特定する' do
      profiler = described_class.new
      profiler.record('fast_test', 10)
      profiler.record('medium_test', 500)
      profiler.record('slow_test', 2000)
      profiler.record('very_slow_test', 5000)

      summary = profiler.summary

      expect(summary[:total_tests]).to eq(4)
      expect(summary[:total_duration_ms]).to eq(7510)
      expect(summary[:slowest_5].first[:name]).to eq('very_slow_test')
    end

    it '平均実行時間を計算する' do
      profiler = described_class.new
      profiler.record('test_a', 100)
      profiler.record('test_b', 200)
      profiler.record('test_c', 300)

      expect(profiler.average_duration_ms).to eq(200.0)
    end
  end

  # ==========================================================================
  # 9. コントラクトテスト
  # ==========================================================================
  describe TestingDesign::ContractTesting::SchemaValidator do
    let(:schema) do
      {
        required: %i[id name email],
        properties: {
          id: { type: :integer },
          name: { type: :string },
          email: { type: :string },
          age: { type: :integer }
        }
      }
    end

    it 'スキーマに適合するデータを有効と判定する' do
      validator = described_class.new(schema)
      data = { id: 1, name: 'Alice', email: 'alice@example.com', age: 30 }

      result = validator.validate(data)

      expect(result[:valid]).to be true
      expect(result[:errors]).to be_empty
    end

    it '必須フィールドの欠落を検知する' do
      validator = described_class.new(schema)
      data = { id: 1, name: 'Alice' } # email が欠落

      result = validator.validate(data)

      expect(result[:valid]).to be false
      expect(result[:errors].any? { |e| e.include?('email') }).to be true
    end

    it '型の不一致を検知する' do
      validator = described_class.new(schema)
      data = { id: 'not_an_integer', name: 'Alice', email: 'alice@example.com' }

      result = validator.validate(data)

      expect(result[:valid]).to be false
      expect(result[:errors].any? { |e| e.include?('型が不正') }).to be true
    end
  end

  # ==========================================================================
  # 10. Property-Based Testing
  # ==========================================================================
  describe TestingDesign::PropertyBasedTesting::SortProperties do
    it 'ソートは要素数を保存する（プロパティ: 長さの保存）' do
      # 複数のランダム入力で性質を検証する
      20.times do
        input = TestingDesign::PropertyBasedTesting::DataGenerator.array_of_integers
        expect(described_class.preserves_length?(input)).to be true
      end
    end

    it 'ソート結果は昇順である（プロパティ: 順序性）' do
      20.times do
        input = TestingDesign::PropertyBasedTesting::DataGenerator.array_of_integers
        expect(described_class.ordered?(input)).to be true
      end
    end

    it 'ソートは同じ要素を含む（プロパティ: 要素の保存）' do
      20.times do
        input = TestingDesign::PropertyBasedTesting::DataGenerator.array_of_integers
        expect(described_class.same_elements?(input)).to be true
      end
    end

    it 'ソートは冪等である（プロパティ: 冪等性）' do
      20.times do
        input = TestingDesign::PropertyBasedTesting::DataGenerator.array_of_integers
        expect(described_class.idempotent?(input)).to be true
      end
    end
  end

  describe TestingDesign::PropertyBasedTesting::DataGenerator do
    it '整数を指定範囲内で生成する' do
      100.times do
        value = described_class.integer(min: 0, max: 10)
        expect(value).to be_between(0, 10)
      end
    end

    it '文字列を生成する' do
      str = described_class.string(length: 10)
      expect(str).to be_a(String)
      expect(str.length).to eq(10)
    end

    it '境界値の整数リストを返す' do
      boundaries = described_class.boundary_integers
      expect(boundaries).to include(0, 1, -1)
      expect(boundaries.length).to be >= 4
    end
  end
end
