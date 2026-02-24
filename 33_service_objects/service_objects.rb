# frozen_string_literal: true

require 'securerandom'

# サービスオブジェクト設計パターンを解説するモジュール
#
# Railsアプリケーションが成長すると、Fat ModelやFat Controllerが発生しやすい。
# サービスオブジェクトはビジネスロジックを単一責任のクラスに抽出し、
# テスタビリティと保守性を向上させる設計パターンである。
#
# このモジュールでは、シニアエンジニアが知るべきサービスオブジェクトの
# 設計原則と実装パターンを実例を通じて学ぶ。
module ServiceObjects
  # ==========================================================================
  # 1. Result オブジェクト: 成功/失敗を明示的に表現する
  # ==========================================================================
  #
  # 例外をフロー制御に使うのではなく、Result オブジェクトで
  # 成功/失敗を明示的に返す。これにより呼び出し側が
  # パターンマッチやif分岐で結果を扱える。
  #
  # メリット:
  # - 例外に頼らない明示的なフロー制御
  # - エラー情報を構造化して返せる
  # - パターンマッチとの相性が良い（Ruby 3.0+）
  class Result
    attr_reader :value, :error, :error_type

    def initialize(success:, value: nil, error: nil, error_type: :unknown)
      @success = success
      @value = value
      @error = error
      @error_type = error_type
    end

    def success?
      @success
    end

    def failure?
      !@success
    end

    # 成功時のみブロックを実行（モナディックな連鎖）
    def and_then
      return self if failure?

      yield(value)
    end

    # 失敗時のみブロックを実行
    def or_else
      return self if success?

      yield(error, error_type)
    end

    # パターンマッチ対応（Ruby 3.0+）
    def deconstruct_keys(_keys)
      if success?
        { success: true, value: value }
      else
        { success: false, error: error, error_type: error_type }
      end
    end

    # ファクトリメソッド
    def self.success(value = nil)
      new(success: true, value: value)
    end

    def self.failure(error, error_type = :unknown)
      new(success: false, error: error, error_type: error_type)
    end
  end

  # ==========================================================================
  # 2. 基本サービスオブジェクト: 単一責任の call メソッド
  # ==========================================================================
  #
  # サービスオブジェクトの基本原則:
  # - クラスメソッド .call で呼び出し可能
  # - 単一のビジネス操作に責任を持つ
  # - Result オブジェクトを返す
  # - 副作用を明示的に管理する
  module BaseService
    # 基底クラス: すべてのサービスオブジェクトが継承する
    #
    # .call クラスメソッドでインスタンスを生成し、#call を実行する。
    # これにより、呼び出し側は UserRegistrationService.call(params) のように
    # シンプルに使える。
    class Base
      def self.call(...)
        new(...).call
      end

      private

      def success(value = nil)
        Result.success(value)
      end

      def failure(error, error_type = :unknown)
        Result.failure(error, error_type)
      end
    end

    # デモ用: 基本的なサービスオブジェクトの動作確認
    def self.demonstrate_basic_service
      result = GreetingService.call(name: 'Rails')

      {
        success: result.success?,
        value: result.value,
        result_class: result.class.name
      }
    end
  end

  # シンプルな挨拶サービス（基本パターンのデモ用）
  class GreetingService < BaseService::Base
    def initialize(name:)
      super()
      @name = name
    end

    def call
      return failure('名前が空です', :validation) if @name.nil? || @name.empty?

      success("こんにちは、#{@name}さん！")
    end
  end

  # ==========================================================================
  # 3. 入力バリデーション: ビジネスロジック実行前の検証
  # ==========================================================================
  #
  # サービスオブジェクトは入力を受け取る窓口でもある。
  # ビジネスロジックを実行する前に入力を検証し、
  # 不正な入力に対しては早期にFailureを返す。
  module InputValidation
    # ユーザー登録サービス
    #
    # バリデーション → ビジネスロジック → 結果返却の流れを示す。
    # ActiveModelのバリデーションとは異なり、
    # サービスレベルのビジネスルールを検証する。
    class UserRegistrationService < BaseService::Base
      VALID_EMAIL_PATTERN = /\A[\w+\-.]+@[a-z\d\-.]+\.[a-z]+\z/i
      MIN_PASSWORD_LENGTH = 8

      def initialize(email:, password:, name:)
        super()
        @email = email
        @password = password
        @name = name
      end

      def call
        # 1. 入力バリデーション（早期リターン）
        validation_result = validate_inputs
        return validation_result if validation_result&.failure?

        # 2. ビジネスルールの検証
        business_result = check_business_rules
        return business_result if business_result&.failure?

        # 3. ユーザー作成（シミュレーション）
        user = create_user

        success(user)
      end

      private

      def validate_inputs
        return failure('メールアドレスは必須です', :validation) if @email.nil? || @email.empty?
        return failure('メールアドレスの形式が不正です', :validation) unless @email.match?(VALID_EMAIL_PATTERN)
        if @password.nil? || @password.length < MIN_PASSWORD_LENGTH
          return failure("パスワードは#{MIN_PASSWORD_LENGTH}文字以上必要です", :validation)
        end
        return failure('名前は必須です', :validation) if @name.nil? || @name.strip.empty?

        nil # バリデーション成功
      end

      def check_business_rules
        # 既存ユーザーチェック（シミュレーション）
        return failure('このメールアドレスは既に登録されています', :conflict) if @email == 'existing@example.com'

        nil # ビジネスルール検証成功
      end

      def create_user
        {
          id: rand(1000..9999),
          email: @email,
          name: @name.strip,
          created_at: Time.now
        }
      end
    end

    # デモ: バリデーション成功と失敗のケース
    def self.demonstrate_validation
      # 成功ケース
      success_result = UserRegistrationService.call(
        email: 'user@example.com',
        password: 'secure_password_123',
        name: '田中太郎'
      )

      # バリデーション失敗ケース
      validation_failure = UserRegistrationService.call(
        email: 'invalid-email',
        password: 'short',
        name: '田中太郎'
      )

      # ビジネスルール違反ケース
      conflict_failure = UserRegistrationService.call(
        email: 'existing@example.com',
        password: 'secure_password_123',
        name: '既存ユーザー'
      )

      {
        success_case: {
          success: success_result.success?,
          email: success_result.value&.fetch(:email, nil)
        },
        validation_failure: {
          success: validation_failure.success?,
          error: validation_failure.error,
          error_type: validation_failure.error_type
        },
        conflict_failure: {
          success: conflict_failure.success?,
          error: conflict_failure.error,
          error_type: conflict_failure.error_type
        }
      }
    end
  end

  # ==========================================================================
  # 4. コンポーザブルサービス: パイプラインパターン
  # ==========================================================================
  #
  # 複数のサービスオブジェクトを連鎖させて、
  # 一連のビジネスプロセスを構築する。
  # Result#and_then を使ったモナディックな連鎖により、
  # 途中で失敗した場合は後続の処理がスキップされる。
  module ComposableServices
    # メールアドレス正規化サービス
    class NormalizeEmailService < BaseService::Base
      def initialize(email:)
        super()
        @email = email
      end

      def call
        return failure('メールアドレスが空です', :validation) if @email.nil? || @email.empty?

        normalized = @email.strip.downcase
        success(normalized)
      end
    end

    # メールアドレス重複チェックサービス（シミュレーション）
    class CheckEmailUniquenessService < BaseService::Base
      EXISTING_EMAILS = %w[admin@example.com test@example.com].freeze

      def initialize(email:)
        super()
        @email = email
      end

      def call
        if EXISTING_EMAILS.include?(@email)
          failure("メールアドレス '#{@email}' は既に使用されています", :conflict)
        else
          success(@email)
        end
      end
    end

    # ウェルカムメール送信サービス（シミュレーション）
    class SendWelcomeEmailService < BaseService::Base
      def initialize(email:, name:)
        super()
        @email = email
        @name = name
      end

      def call
        # メール送信をシミュレーション
        success({
                  to: @email,
                  subject: "ようこそ、#{@name}さん！",
                  sent_at: Time.now,
                  status: :sent
                })
      end
    end

    # パイプラインオーケストレーター
    #
    # 複数のサービスを and_then で連鎖させる。
    # いずれかのステップで失敗した場合、後続は実行されない。
    class RegistrationPipeline < BaseService::Base
      def initialize(email:, name:, password:)
        super()
        @email = email
        @name = name
        @password = password
      end

      def call
        steps_executed = []

        # ステップ1: メールアドレス正規化
        NormalizeEmailService.call(email: @email)
                             .and_then do |normalized_email|
                               steps_executed << :normalize
                               # ステップ2: 重複チェック
                               CheckEmailUniquenessService.call(email: normalized_email)
                             end
                             .and_then do |verified_email|
                               steps_executed << :uniqueness_check
                               # ステップ3: ユーザー作成
                               user = { id: rand(1000..9999), email: verified_email, name: @name }
                               steps_executed << :user_creation
                               # ステップ4: ウェルカムメール
                               SendWelcomeEmailService.call(email: verified_email, name: @name)
                                                      .and_then do |email_result|
                                                        steps_executed << :welcome_email
                                                        Result.success({
                                                                         user: user,
                                                                         email_result: email_result,
                                                                         steps_executed: steps_executed
                                                                       })
                                                      end
                             end
      end
    end

    # デモ: パイプラインの成功と失敗
    def self.demonstrate_pipeline
      # 成功ケース
      success_result = RegistrationPipeline.call(
        email: '  NewUser@Example.COM  ',
        name: '新規ユーザー',
        password: 'secure_password'
      )

      # 途中で失敗するケース（重複メール）
      failure_result = RegistrationPipeline.call(
        email: 'admin@example.com',
        name: '管理者',
        password: 'secure_password'
      )

      # 最初のステップで失敗するケース
      early_failure = RegistrationPipeline.call(
        email: '',
        name: '空メール',
        password: 'secure_password'
      )

      {
        success_case: {
          success: success_result.success?,
          steps: success_result.value&.fetch(:steps_executed, nil),
          email: success_result.value&.dig(:user, :email)
        },
        duplicate_failure: {
          success: failure_result.success?,
          error: failure_result.error,
          error_type: failure_result.error_type
        },
        early_failure: {
          success: early_failure.success?,
          error: early_failure.error
        }
      }
    end
  end

  # ==========================================================================
  # 5. トランザクション処理: 複数ステップの原子性保証
  # ==========================================================================
  #
  # 複数のデータ変更を伴うサービスでは、トランザクションで
  # 原子性を保証する必要がある。途中で失敗した場合は
  # すべての変更をロールバックする。
  #
  # 注意: ここではDBを使わずシミュレーションで原理を示す。
  module TransactionHandling
    # シンプルなインメモリデータストア（トランザクション対応）
    #
    # 実際のRailsアプリケーションでは ActiveRecord::Base.transaction を使う。
    # ここでは原理を理解するためにインメモリで実装する。
    class InMemoryStore
      attr_reader :committed_data, :transaction_active

      def initialize
        @committed_data = {}
        @pending_changes = []
        @transaction_active = false
        @savepoint_data = nil
      end

      def transaction
        @transaction_active = true
        @savepoint_data = @committed_data.dup
        @pending_changes = []

        result = yield

        if result.is_a?(Result) && result.failure?
          rollback
          return result
        end

        commit
        result
      rescue StandardError => e
        rollback
        raise e
      ensure
        @transaction_active = false
      end

      def insert(key, value)
        @pending_changes << { action: :insert, key: key, value: value }
        @committed_data[key] = value
      end

      def delete(key)
        @pending_changes << { action: :delete, key: key, value: @committed_data[key] }
        @committed_data.delete(key)
      end

      private

      def commit
        @pending_changes.clear
        @savepoint_data = nil
      end

      def rollback
        @committed_data = @savepoint_data || {}
        @pending_changes.clear
        @savepoint_data = nil
      end
    end

    # 注文処理サービス（トランザクション付き）
    #
    # 1. 在庫確認 → 2. 在庫減少 → 3. 注文作成 → 4. 決済処理
    # いずれかが失敗した場合、すべてロールバックする。
    class OrderProcessingService < BaseService::Base
      def initialize(store:, product_id:, quantity:, payment_method:)
        super()
        @store = store
        @product_id = product_id
        @quantity = quantity
        @payment_method = payment_method
      end

      def call
        @store.transaction do
          # ステップ1: 在庫確認
          stock = @store.committed_data.dig("product:#{@product_id}", :stock) || 0
          next failure("在庫不足です（残り: #{stock}個、要求: #{@quantity}個）", :business) if stock < @quantity

          # ステップ2: 在庫減少
          product = @store.committed_data["product:#{@product_id}"]
          @store.insert("product:#{@product_id}", product.merge(stock: stock - @quantity))

          # ステップ3: 注文作成
          order_id = "order_#{rand(1000..9999)}"
          @store.insert("order:#{order_id}", {
                          product_id: @product_id,
                          quantity: @quantity,
                          status: :pending
                        })

          # ステップ4: 決済処理（シミュレーション）
          next failure('決済に失敗しました', :payment) if @payment_method == :invalid

          # 注文ステータスを確定に更新
          @store.insert("order:#{order_id}", {
                          product_id: @product_id,
                          quantity: @quantity,
                          status: :confirmed,
                          payment_method: @payment_method
                        })

          success({ order_id: order_id, product_id: @product_id, quantity: @quantity })
        end
      end
    end

    # デモ: トランザクションの成功とロールバック
    def self.demonstrate_transaction
      # 成功ケース
      success_store = InMemoryStore.new
      success_store.committed_data['product:1'] = { name: 'Ruby本', stock: 10, price: 3000 }

      success_result = OrderProcessingService.call(
        store: success_store,
        product_id: '1',
        quantity: 2,
        payment_method: :credit_card
      )

      # 決済失敗ケース → ロールバック
      rollback_store = InMemoryStore.new
      rollback_store.committed_data['product:2'] = { name: 'Rails本', stock: 5, price: 4000 }

      rollback_result = OrderProcessingService.call(
        store: rollback_store,
        product_id: '2',
        quantity: 1,
        payment_method: :invalid
      )

      # 在庫不足ケース
      stock_store = InMemoryStore.new
      stock_store.committed_data['product:3'] = { name: '設計本', stock: 0, price: 2500 }

      stock_result = OrderProcessingService.call(
        store: stock_store,
        product_id: '3',
        quantity: 1,
        payment_method: :credit_card
      )

      {
        success_case: {
          success: success_result.success?,
          order: success_result.value,
          remaining_stock: success_store.committed_data['product:1'][:stock]
        },
        rollback_case: {
          success: rollback_result.success?,
          error: rollback_result.error,
          # 決済失敗でロールバック → 在庫が元に戻る
          stock_restored: rollback_store.committed_data['product:2'][:stock]
        },
        stock_shortage: {
          success: stock_result.success?,
          error: stock_result.error,
          error_type: stock_result.error_type
        }
      }
    end
  end

  # ==========================================================================
  # 6. エラーカテゴリ分類: ビジネスエラー vs システムエラー
  # ==========================================================================
  #
  # サービスオブジェクトでは、エラーを2種類に分類する:
  #
  # ビジネスエラー（期待されるエラー）:
  # - バリデーション失敗、権限不足、リソース競合など
  # - Result.failure で返す（例外を投げない）
  # - ユーザーに適切なメッセージを表示
  #
  # システムエラー（予期しないエラー）:
  # - DB接続エラー、外部API障害、メモリ不足など
  # - 例外として raise する（または捕捉してログ出力後に再送出）
  # - 運用チームに通知が必要
  module ErrorCategorization
    # 決済処理サービス（エラーカテゴリ分類の例）
    class PaymentProcessingService < BaseService::Base
      # ビジネスエラー: Result.failure で返す
      BUSINESS_ERRORS = %i[
        insufficient_funds
        card_expired
        card_declined
        invalid_amount
      ].freeze

      def initialize(amount:, card_token:, idempotency_key:)
        super()
        @amount = amount
        @card_token = card_token
        @idempotency_key = idempotency_key
      end

      def call
        # 1. 入力バリデーション（ビジネスエラー）
        return failure('金額は正の数である必要があります', :invalid_amount) if @amount <= 0
        return failure('カードトークンが無効です', :validation) if @card_token.nil? || @card_token.empty?

        # 2. 決済実行（シミュレーション）
        payment_result = simulate_payment

        case payment_result[:status]
        when :success
          success({
                    transaction_id: payment_result[:transaction_id],
                    amount: @amount,
                    idempotency_key: @idempotency_key
                  })
        when :insufficient_funds
          # ビジネスエラー: ユーザーに伝えるべき情報
          failure('残高不足です', :insufficient_funds)
        when :card_expired
          failure('カードの有効期限が切れています', :card_expired)
        when :gateway_error
          # システムエラー: 運用チームに通知が必要
          # 実際にはエラーレポーターに通知してから failure を返す
          failure('決済システムに一時的な障害が発生しています。しばらく後に再試行してください', :system)
        else
          failure('不明なエラーが発生しました', :system)
        end
      end

      private

      def simulate_payment
        # カードトークンに基づいたシミュレーション
        case @card_token
        when 'tok_insufficient'
          { status: :insufficient_funds }
        when 'tok_expired'
          { status: :card_expired }
        when 'tok_gateway_error'
          { status: :gateway_error }
        else
          { status: :success, transaction_id: "txn_#{SecureRandom.hex(8)}" }
        end
      end
    end

    # エラーハンドリングのデモ
    def self.demonstrate_error_categorization
      require 'securerandom'

      # 成功ケース
      success_result = PaymentProcessingService.call(
        amount: 1000,
        card_token: 'tok_valid_card',
        idempotency_key: SecureRandom.uuid
      )

      # ビジネスエラー: 残高不足
      business_error = PaymentProcessingService.call(
        amount: 50_000,
        card_token: 'tok_insufficient',
        idempotency_key: SecureRandom.uuid
      )

      # ビジネスエラー: 不正な金額
      validation_error = PaymentProcessingService.call(
        amount: -100,
        card_token: 'tok_valid',
        idempotency_key: SecureRandom.uuid
      )

      # システムエラー: ゲートウェイ障害
      system_error = PaymentProcessingService.call(
        amount: 1000,
        card_token: 'tok_gateway_error',
        idempotency_key: SecureRandom.uuid
      )

      {
        success: {
          success: success_result.success?,
          has_transaction_id: !success_result.value[:transaction_id].nil?
        },
        business_error: {
          success: business_error.success?,
          error: business_error.error,
          error_type: business_error.error_type,
          is_business_error: PaymentProcessingService::BUSINESS_ERRORS.include?(business_error.error_type)
        },
        validation_error: {
          success: validation_error.success?,
          error: validation_error.error,
          error_type: validation_error.error_type
        },
        system_error: {
          success: system_error.success?,
          error: system_error.error,
          error_type: system_error.error_type,
          is_system_error: system_error.error_type == :system
        }
      }
    end
  end

  # ==========================================================================
  # 7. テストパターン: サービスオブジェクトの効果的なテスト方法
  # ==========================================================================
  #
  # サービスオブジェクトはテスタビリティが高い:
  # - 入力と出力が明確（引数 → Result）
  # - 依存関係を注入できる（テストダブルを使える）
  # - 単一のメソッド（call）をテストすればよい
  module TestingPatterns
    # 依存関係注入を活用したサービス
    #
    # 外部依存（メール送信、API呼び出し等）をコンストラクタで
    # 注入することで、テスト時にモックに差し替えられる。
    class NotificationService < BaseService::Base
      def initialize(user_id:, message:, notifier: DefaultNotifier.new)
        super()
        @user_id = user_id
        @message = message
        @notifier = notifier
      end

      def call
        return failure('ユーザーIDは必須です', :validation) if @user_id.nil?
        return failure('メッセージは必須です', :validation) if @message.nil? || @message.empty?

        # 依存関係を通じて通知を送信
        notification_result = @notifier.send_notification(
          user_id: @user_id,
          message: @message
        )

        if notification_result[:delivered]
          success({
                    user_id: @user_id,
                    notification_id: notification_result[:id],
                    delivered_at: notification_result[:delivered_at]
                  })
        else
          failure("通知の送信に失敗しました: #{notification_result[:reason]}", :delivery_failure)
        end
      end
    end

    # デフォルトの通知送信クラス
    class DefaultNotifier
      def send_notification(user_id:, message:)
        # 実際にはメール送信やPush通知を行う
        {
          id: "notif_#{rand(1000..9999)}",
          delivered: true,
          delivered_at: Time.now,
          user_id: user_id,
          message: message
        }
      end
    end

    # テスト用のモック通知送信クラス
    class MockNotifier
      attr_reader :sent_notifications

      def initialize(should_succeed: true)
        @should_succeed = should_succeed
        @sent_notifications = []
      end

      def send_notification(user_id:, message:)
        record = { user_id: user_id, message: message }
        @sent_notifications << record

        if @should_succeed
          { id: 'mock_notif_001', delivered: true, delivered_at: Time.now }
        else
          { delivered: false, reason: '配信先が見つかりません' }
        end
      end
    end

    # デモ: 依存関係注入によるテスタビリティ
    def self.demonstrate_testability
      # 成功するモック通知器を注入
      success_notifier = MockNotifier.new(should_succeed: true)
      success_result = NotificationService.call(
        user_id: 42,
        message: 'テスト通知',
        notifier: success_notifier
      )

      # 失敗するモック通知器を注入
      failure_notifier = MockNotifier.new(should_succeed: false)
      failure_result = NotificationService.call(
        user_id: 42,
        message: 'テスト通知',
        notifier: failure_notifier
      )

      {
        success_case: {
          success: success_result.success?,
          notification_id: success_result.value&.fetch(:notification_id, nil),
          notifications_sent: success_notifier.sent_notifications.size
        },
        failure_case: {
          success: failure_result.success?,
          error: failure_result.error,
          notifications_attempted: failure_notifier.sent_notifications.size
        },
        # モック通知器で実際に送信されたかを検証できる
        testability_benefit: '依存関係注入により外部サービスなしでテスト可能'
      }
    end
  end

  # ==========================================================================
  # 8. アンチパターン: 避けるべきサービスオブジェクトの設計
  # ==========================================================================
  #
  # サービスオブジェクトは万能薬ではない。
  # 以下のアンチパターンに注意すること。
  module AntiPatterns
    # --- アンチパターン1: God Service Object ---
    #
    # 1つのサービスに多くの責任を詰め込みすぎる。
    # これは Fat Model/Controller を Fat Service に移動しただけである。
    #
    # 悪い例（コメントで示す）:
    # class UserManagementService
    #   def call(action:, **params)
    #     case action
    #     when :register then register(params)
    #     when :update_profile then update_profile(params)
    #     when :change_password then change_password(params)
    #     when :deactivate then deactivate(params)
    #     when :send_notification then send_notification(params)
    #     end
    #   end
    # end
    #
    # 良い例: 各操作を個別のサービスに分割する
    # - UserRegistrationService
    # - ProfileUpdateService
    # - PasswordChangeService
    # - AccountDeactivationService
    # - NotificationService

    # --- アンチパターン2: 単なるメソッド抽出 ---
    #
    # モデルのメソッドをサービスに移動しただけで、
    # 実質的にはモデルへの薄いラッパーになっている。
    #
    # 悪い例:
    # class UpdateUserNameService
    #   def call(user:, name:)
    #     user.update!(name: name) # ← これはモデルのメソッドで十分
    #   end
    # end
    #
    # サービスオブジェクトにすべき基準:
    # - 複数のモデルやリソースにまたがる操作
    # - 外部サービスとの連携が必要
    # - 複雑なビジネスルールの適用
    # - トランザクション管理が必要

    # --- アンチパターン3: 過度な抽象化 ---
    #
    # 汎用的すぎるベースクラスや、必要以上の抽象レイヤーは
    # コードの可読性を下げ、デバッグを困難にする。

    # アンチパターンの判定デモ
    def self.demonstrate_anti_patterns
      {
        god_service: {
          problem: '1つのサービスに複数の責任を持たせている',
          symptom: 'case文やif文で処理を分岐している',
          solution: '各操作を独立したサービスに分割する',
          guideline: '1サービス = 1ビジネス操作'
        },
        thin_wrapper: {
          problem: 'モデルの単純な操作をサービスで包んでいる',
          symptom: 'サービスの中身がuser.update!だけ',
          solution: '単純なCRUDはモデルに任せる',
          guideline: 'サービスにすべきは複数モデル/外部連携/複雑なルール'
        },
        over_abstraction: {
          problem: '汎用的すぎるベースクラスやDSL',
          symptom: '基底クラスの理解なしにサービスを書けない',
          solution: 'YAGNI原則に従い必要最小限の抽象化にとどめる',
          guideline: '新しいチームメンバーが5分で理解できるか？'
        },
        service_criteria: [
          '複数のモデル/リソースにまたがる操作',
          '外部サービス（API、メール等）との連携',
          '複雑なビジネスルール/バリデーション',
          'トランザクション管理が必要な処理',
          '非同期ジョブから呼び出す処理の単位'
        ]
      }
    end
  end

  # ==========================================================================
  # 9. Result オブジェクトのパターンマッチ（Ruby 3.0+）
  # ==========================================================================
  #
  # Ruby 3.0+ のパターンマッチとResult オブジェクトを
  # 組み合わせることで、より宣言的なエラーハンドリングが可能になる。
  module PatternMatchingDemo
    def self.demonstrate_pattern_matching
      require 'securerandom'

      results = {}

      # 成功ケースのパターンマッチ
      success_result = Result.success({ user_id: 1, name: '太郎' })
      results[:success_match] = case success_result
                                in { success: true, value: { user_id: Integer => id, name: String => name } }
                                  "ユーザーID: #{id}, 名前: #{name}"
                                in { success: false, error: String => err }
                                  "エラー: #{err}"
                                end

      # 失敗ケースのパターンマッチ
      failure_result = Result.failure('認証に失敗しました', :authentication)
      results[:failure_match] = case failure_result
                                in { success: false, error_type: :authentication }
                                  '認証エラー: ログインページにリダイレクト'
                                in { success: false, error_type: :validation, error: String => msg }
                                  "バリデーションエラー: #{msg}"
                                in { success: true }
                                  '成功'
                                end

      # エラータイプに基づく分岐
      errors = [
        Result.failure('不正な入力', :validation),
        Result.failure('権限がありません', :authorization),
        Result.failure('DB接続エラー', :system)
      ]

      results[:categorized_errors] = errors.map do |result|
        case result
        in { error_type: :validation, error: String => msg }
          { category: 'クライアントエラー', message: msg, status: 422 }
        in { error_type: :authorization }
          { category: '認可エラー', message: result.error, status: 403 }
        in { error_type: :system }
          { category: 'システムエラー', message: '内部エラーが発生しました', status: 500 }
        end
      end

      results
    end
  end
end
