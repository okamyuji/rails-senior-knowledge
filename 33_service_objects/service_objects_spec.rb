# frozen_string_literal: true

require_relative 'service_objects'

RSpec.describe ServiceObjects do
  # ==========================================================================
  # 1. Result オブジェクト
  # ==========================================================================
  describe ServiceObjects::Result do
    describe '成功Result' do
      let(:result) { described_class.success({ id: 1, name: '太郎' }) }

      it 'success? が true を返すこと' do
        expect(result.success?).to be true
        expect(result.failure?).to be false
      end

      it 'value にデータが格納されていること' do
        expect(result.value).to eq({ id: 1, name: '太郎' })
      end
    end

    describe '失敗Result' do
      let(:result) { described_class.failure('エラーが発生しました', :validation) }

      it 'failure? が true を返すこと' do
        expect(result.failure?).to be true
        expect(result.success?).to be false
      end

      it 'error と error_type が格納されていること' do
        expect(result.error).to eq 'エラーが発生しました'
        expect(result.error_type).to eq :validation
      end
    end

    describe '#and_then（モナディック連鎖）' do
      it '成功時にブロックを実行すること' do
        result = described_class.success(10)
                                .and_then { |v| described_class.success(v * 2) }
                                .and_then { |v| described_class.success(v + 5) }

        expect(result.success?).to be true
        expect(result.value).to eq 25
      end

      it '失敗時に後続のブロックをスキップすること' do
        executed_steps = []

        result = described_class.success(10)
                                .and_then do |_v|
                                  executed_steps << :step1
                                  described_class.failure('ステップ1で失敗', :business)
                                end
                                .and_then do |v|
                                  executed_steps << :step2 # ここは実行されない
                                  described_class.success(v)
                                end

        expect(result.failure?).to be true
        expect(result.error).to eq 'ステップ1で失敗'
        expect(executed_steps).to eq [:step1]
      end
    end

    describe '#or_else（失敗時の処理）' do
      it '失敗時にブロックを実行すること' do
        result = described_class.failure('元のエラー', :validation)
                                .or_else do |error, _type|
                                  described_class.failure(
                                    "変換後: #{error}", :handled
                                  )
        end

        expect(result.error).to eq '変換後: 元のエラー'
        expect(result.error_type).to eq :handled
      end

      it '成功時にブロックをスキップすること' do
        result = described_class.success(42)
                                .or_else { |_error, _type| described_class.success(0) }

        expect(result.value).to eq 42
      end
    end

    describe '#deconstruct_keys（パターンマッチ対応）' do
      it '成功Resultのパターンマッチが動作すること' do
        result = described_class.success('データ')

        matched = case result
                  in { success: true, value: String => v }
                    v
                  else
                    nil
                  end

        expect(matched).to eq 'データ'
      end

      it '失敗Resultのパターンマッチが動作すること' do
        result = described_class.failure('不正な入力', :validation)

        matched = case result
                  in { success: false, error_type: :validation, error: String => msg }
                    msg
                  else
                    nil
                  end

        expect(matched).to eq '不正な入力'
      end
    end
  end

  # ==========================================================================
  # 2. 基本サービスオブジェクト
  # ==========================================================================
  describe ServiceObjects::BaseService do
    describe '.demonstrate_basic_service' do
      let(:result) { described_class.demonstrate_basic_service }

      it '基本的なサービスオブジェクトが正しく動作すること' do
        expect(result[:success]).to be true
        expect(result[:value]).to eq 'こんにちは、Railsさん！'
        expect(result[:result_class]).to eq 'ServiceObjects::Result'
      end
    end
  end

  describe ServiceObjects::GreetingService do
    it '正常な入力で成功を返すこと' do
      result = described_class.call(name: '太郎')
      expect(result.success?).to be true
      expect(result.value).to eq 'こんにちは、太郎さん！'
    end

    it '空の名前でバリデーションエラーを返すこと' do
      result = described_class.call(name: '')
      expect(result.failure?).to be true
      expect(result.error).to eq '名前が空です'
      expect(result.error_type).to eq :validation
    end

    it 'nilの名前でバリデーションエラーを返すこと' do
      result = described_class.call(name: nil)
      expect(result.failure?).to be true
      expect(result.error_type).to eq :validation
    end
  end

  # ==========================================================================
  # 3. 入力バリデーション
  # ==========================================================================
  describe ServiceObjects::InputValidation do
    describe ServiceObjects::InputValidation::UserRegistrationService do
      context '正常な入力の場合' do
        let(:result) do
          described_class.call(
            email: 'user@example.com',
            password: 'secure_password_123',
            name: '田中太郎'
          )
        end

        it 'ユーザー登録に成功すること' do
          expect(result.success?).to be true
          expect(result.value[:email]).to eq 'user@example.com'
          expect(result.value[:name]).to eq '田中太郎'
          expect(result.value[:id]).to be_a(Integer)
        end
      end

      context 'メールアドレスが不正な場合' do
        it '形式不正でバリデーションエラーを返すこと' do
          result = described_class.call(
            email: 'invalid-email',
            password: 'secure_password',
            name: '太郎'
          )
          expect(result.failure?).to be true
          expect(result.error).to include('形式が不正')
          expect(result.error_type).to eq :validation
        end

        it '空メールでバリデーションエラーを返すこと' do
          result = described_class.call(email: '', password: 'secure_password', name: '太郎')
          expect(result.failure?).to be true
          expect(result.error).to include('必須')
        end
      end

      context 'パスワードが短い場合' do
        it 'バリデーションエラーを返すこと' do
          result = described_class.call(
            email: 'user@example.com',
            password: 'short',
            name: '太郎'
          )
          expect(result.failure?).to be true
          expect(result.error).to include('8文字以上')
        end
      end

      context '既存のメールアドレスの場合' do
        it 'ビジネスルール違反（conflict）を返すこと' do
          result = described_class.call(
            email: 'existing@example.com',
            password: 'secure_password_123',
            name: '既存ユーザー'
          )
          expect(result.failure?).to be true
          expect(result.error_type).to eq :conflict
          expect(result.error).to include('既に登録')
        end
      end
    end

    describe '.demonstrate_validation' do
      let(:result) { described_class.demonstrate_validation }

      it '成功・バリデーション失敗・ビジネスルール違反の3パターンを示すこと' do
        expect(result[:success_case][:success]).to be true
        expect(result[:validation_failure][:success]).to be false
        expect(result[:validation_failure][:error_type]).to eq :validation
        expect(result[:conflict_failure][:success]).to be false
        expect(result[:conflict_failure][:error_type]).to eq :conflict
      end
    end
  end

  # ==========================================================================
  # 4. コンポーザブルサービス（パイプライン）
  # ==========================================================================
  describe ServiceObjects::ComposableServices do
    describe ServiceObjects::ComposableServices::NormalizeEmailService do
      it 'メールアドレスを正規化すること' do
        result = described_class.call(email: '  User@Example.COM  ')
        expect(result.success?).to be true
        expect(result.value).to eq 'user@example.com'
      end

      it '空のメールアドレスで失敗すること' do
        result = described_class.call(email: '')
        expect(result.failure?).to be true
      end
    end

    describe ServiceObjects::ComposableServices::RegistrationPipeline do
      context '全ステップが成功する場合' do
        let(:result) do
          described_class.call(
            email: '  NewUser@Example.COM  ',
            name: '新規ユーザー',
            password: 'secure_password'
          )
        end

        it '全4ステップが実行されること' do
          expect(result.success?).to be true
          expect(result.value[:steps_executed]).to eq %i[normalize uniqueness_check user_creation welcome_email]
        end

        it 'メールアドレスが正規化されていること' do
          expect(result.value[:user][:email]).to eq 'newuser@example.com'
        end
      end

      context '重複チェックで失敗する場合' do
        let(:result) do
          described_class.call(
            email: 'admin@example.com',
            name: '管理者',
            password: 'secure_password'
          )
        end

        it '失敗を返し後続ステップがスキップされること' do
          expect(result.failure?).to be true
          expect(result.error_type).to eq :conflict
          expect(result.error).to include('既に使用')
        end
      end

      context '最初のステップで失敗する場合' do
        it '後続の全ステップがスキップされること' do
          result = described_class.call(email: '', name: '空メール', password: 'pass')
          expect(result.failure?).to be true
          expect(result.error_type).to eq :validation
        end
      end
    end

    describe '.demonstrate_pipeline' do
      let(:result) { described_class.demonstrate_pipeline }

      it 'パイプラインの成功・重複失敗・早期失敗を示すこと' do
        expect(result[:success_case][:success]).to be true
        expect(result[:success_case][:steps]).to include(:normalize, :welcome_email)
        expect(result[:duplicate_failure][:success]).to be false
        expect(result[:early_failure][:success]).to be false
      end
    end
  end

  # ==========================================================================
  # 5. トランザクション処理
  # ==========================================================================
  describe ServiceObjects::TransactionHandling do
    let(:store) { ServiceObjects::TransactionHandling::InMemoryStore.new }

    describe ServiceObjects::TransactionHandling::OrderProcessingService do
      before do
        store.committed_data['product:1'] = { name: 'Ruby本', stock: 10, price: 3000 }
      end

      context '正常な注文の場合' do
        let(:result) do
          described_class.call(
            store: store,
            product_id: '1',
            quantity: 2,
            payment_method: :credit_card
          )
        end

        it '注文が成功し在庫が減少すること' do
          expect(result.success?).to be true
          expect(result.value[:quantity]).to eq 2
          expect(store.committed_data['product:1'][:stock]).to eq 8
        end
      end

      context '決済に失敗した場合' do
        let(:result) do
          described_class.call(
            store: store,
            product_id: '1',
            quantity: 2,
            payment_method: :invalid
          )
        end

        it 'ロールバックされ在庫が復元すること' do
          expect(result.failure?).to be true
          expect(result.error).to include('決済に失敗')
          expect(result.error_type).to eq :payment
          # ロールバックにより在庫が元に戻る
          expect(store.committed_data['product:1'][:stock]).to eq 10
        end
      end

      context '在庫不足の場合' do
        it 'ビジネスエラーを返すこと' do
          result = described_class.call(
            store: store,
            product_id: '1',
            quantity: 100,
            payment_method: :credit_card
          )
          expect(result.failure?).to be true
          expect(result.error).to include('在庫不足')
          expect(result.error_type).to eq :business
        end
      end
    end

    describe '.demonstrate_transaction' do
      let(:result) { described_class.demonstrate_transaction }

      it 'トランザクションの成功・ロールバック・在庫不足を示すこと' do
        expect(result[:success_case][:success]).to be true
        expect(result[:success_case][:remaining_stock]).to eq 8
        expect(result[:rollback_case][:success]).to be false
        expect(result[:rollback_case][:stock_restored]).to eq 5
        expect(result[:stock_shortage][:success]).to be false
        expect(result[:stock_shortage][:error_type]).to eq :business
      end
    end
  end

  # ==========================================================================
  # 6. エラーカテゴリ分類
  # ==========================================================================
  describe ServiceObjects::ErrorCategorization do
    describe ServiceObjects::ErrorCategorization::PaymentProcessingService do
      it '正常な決済で成功を返すこと' do
        result = described_class.call(
          amount: 1000,
          card_token: 'tok_valid_card',
          idempotency_key: 'key_001'
        )
        expect(result.success?).to be true
        expect(result.value[:transaction_id]).to start_with('txn_')
        expect(result.value[:amount]).to eq 1000
      end

      it '残高不足でビジネスエラーを返すこと' do
        result = described_class.call(
          amount: 50_000,
          card_token: 'tok_insufficient',
          idempotency_key: 'key_002'
        )
        expect(result.failure?).to be true
        expect(result.error_type).to eq :insufficient_funds
        expect(result.error).to include('残高不足')
      end

      it '不正な金額でバリデーションエラーを返すこと' do
        result = described_class.call(
          amount: -100,
          card_token: 'tok_valid',
          idempotency_key: 'key_003'
        )
        expect(result.failure?).to be true
        expect(result.error_type).to eq :invalid_amount
      end

      it 'ゲートウェイ障害でシステムエラーを返すこと' do
        result = described_class.call(
          amount: 1000,
          card_token: 'tok_gateway_error',
          idempotency_key: 'key_004'
        )
        expect(result.failure?).to be true
        expect(result.error_type).to eq :system
        expect(result.error).to include('一時的な障害')
      end

      it '有効期限切れカードでビジネスエラーを返すこと' do
        result = described_class.call(
          amount: 1000,
          card_token: 'tok_expired',
          idempotency_key: 'key_005'
        )
        expect(result.failure?).to be true
        expect(result.error_type).to eq :card_expired
      end
    end
  end

  # ==========================================================================
  # 7. テストパターン（依存関係注入）
  # ==========================================================================
  describe ServiceObjects::TestingPatterns do
    describe ServiceObjects::TestingPatterns::NotificationService do
      context 'モック通知器を注入した場合' do
        it '成功する通知器で成功を返すこと' do
          notifier = ServiceObjects::TestingPatterns::MockNotifier.new(should_succeed: true)
          result = described_class.call(user_id: 1, message: 'テスト', notifier: notifier)

          expect(result.success?).to be true
          expect(result.value[:notification_id]).to eq 'mock_notif_001'
          # モック通知器に記録された送信履歴を検証
          expect(notifier.sent_notifications.size).to eq 1
          expect(notifier.sent_notifications.first[:user_id]).to eq 1
        end

        it '失敗する通知器で失敗を返すこと' do
          notifier = ServiceObjects::TestingPatterns::MockNotifier.new(should_succeed: false)
          result = described_class.call(user_id: 1, message: 'テスト', notifier: notifier)

          expect(result.failure?).to be true
          expect(result.error).to include('送信に失敗')
          expect(result.error_type).to eq :delivery_failure
        end
      end

      context 'バリデーションの場合' do
        it 'ユーザーIDがnilで失敗すること' do
          result = described_class.call(user_id: nil, message: 'テスト')
          expect(result.failure?).to be true
          expect(result.error_type).to eq :validation
        end

        it 'メッセージが空で失敗すること' do
          result = described_class.call(user_id: 1, message: '')
          expect(result.failure?).to be true
          expect(result.error_type).to eq :validation
        end
      end
    end

    describe '.demonstrate_testability' do
      let(:result) { described_class.demonstrate_testability }

      it '依存関係注入によるテスタビリティを示すこと' do
        expect(result[:success_case][:success]).to be true
        expect(result[:success_case][:notifications_sent]).to eq 1
        expect(result[:failure_case][:success]).to be false
        expect(result[:failure_case][:notifications_attempted]).to eq 1
      end
    end
  end

  # ==========================================================================
  # 8. アンチパターン
  # ==========================================================================
  describe ServiceObjects::AntiPatterns do
    describe '.demonstrate_anti_patterns' do
      let(:result) { described_class.demonstrate_anti_patterns }

      it '3つのアンチパターンとサービス化の基準を示すこと' do
        expect(result[:god_service][:guideline]).to include('1サービス')
        expect(result[:thin_wrapper][:solution]).to include('モデルに任せる')
        expect(result[:thin_wrapper][:guideline]).to include('複数モデル')
        expect(result[:over_abstraction][:guideline]).to include('5分')
        expect(result[:service_criteria]).to be_an(Array)
        expect(result[:service_criteria].size).to eq 5
      end
    end
  end

  # ==========================================================================
  # 9. パターンマッチ
  # ==========================================================================
  describe ServiceObjects::PatternMatchingDemo do
    describe '.demonstrate_pattern_matching' do
      let(:result) { described_class.demonstrate_pattern_matching }

      it '成功Resultのパターンマッチが動作すること' do
        expect(result[:success_match]).to include('ユーザーID: 1')
        expect(result[:success_match]).to include('名前: 太郎')
      end

      it '失敗Resultのパターンマッチが動作すること' do
        expect(result[:failure_match]).to include('認証エラー')
        expect(result[:failure_match]).to include('リダイレクト')
      end

      it 'エラータイプに基づく分類が動作すること' do
        categorized = result[:categorized_errors]
        expect(categorized.size).to eq 3

        validation_error = categorized.find { |e| e[:status] == 422 }
        expect(validation_error[:category]).to eq 'クライアントエラー'

        auth_error = categorized.find { |e| e[:status] == 403 }
        expect(auth_error[:category]).to eq '認可エラー'

        system_error = categorized.find { |e| e[:status] == 500 }
        expect(system_error[:category]).to eq 'システムエラー'
      end
    end
  end
end
