# frozen_string_literal: true

# Rails/Ruby におけるエラーハンドリングの設計パターンを解説するモジュール
#
# 本番アプリケーションでは例外設計が品質を大きく左右する。
# このモジュールでは、シニアエンジニアが知るべきエラーハンドリングの
# 原則とパターンを実例を通じて学ぶ。
module ErrorHandling
  # =========================================================================
  # カスタム例外階層
  # =========================================================================
  #
  # アプリケーション固有の例外階層を構築する。
  # すべてのカスタム例外は StandardError を継承すべきである。
  # Exception を直接継承してはならない（後述）。
  #
  # 階層構造:
  #   ApplicationError
  #   ├── BusinessError（ビジネスロジック上のエラー）
  #   │   ├── ValidationError
  #   │   └── AuthorizationError
  #   └── SystemError（インフラ/外部システムのエラー）
  #       ├── ExternalServiceError
  #       └── DatabaseError

  # アプリケーション全体の基底例外
  # エラーコードと HTTP ステータスのマッピングを持つ
  class ApplicationError < StandardError
    attr_reader :error_code, :http_status, :metadata

    def initialize(message = nil, error_code: 'APP_ERROR', http_status: 500, metadata: {})
      @error_code = error_code
      @http_status = http_status
      @metadata = metadata
      super(message || self.class.name)
    end

    # エラー報告サービスに送る構造化データを生成する
    def to_error_report
      {
        error_class: self.class.name,
        message: message,
        error_code: @error_code,
        http_status: @http_status,
        metadata: @metadata,
        backtrace_head: backtrace&.first(5)
      }
    end
  end

  # ビジネスロジック上のエラー（ユーザーの操作に起因）
  class BusinessError < ApplicationError
    def initialize(message = nil, error_code: 'BUSINESS_ERROR', http_status: 422, metadata: {})
      super
    end
  end

  # バリデーションエラー
  class ValidationError < BusinessError
    attr_reader :field, :errors

    def initialize(message = nil, field: nil, errors: [], metadata: {})
      @field = field
      @errors = errors
      super(
        message || "バリデーションエラー: #{field}",
        error_code: 'VALIDATION_ERROR',
        http_status: 422,
        metadata: metadata.merge(field: field, errors: errors)
      )
    end
  end

  # 認可エラー
  class AuthorizationError < BusinessError
    def initialize(message = nil, resource: nil, action: nil, metadata: {})
      super(
        message || "権限がありません: #{action} on #{resource}",
        error_code: 'AUTHORIZATION_ERROR',
        http_status: 403,
        metadata: metadata.merge(resource: resource, action: action)
      )
    end
  end

  # システムエラー（インフラ/外部サービスに起因）
  class SystemError < ApplicationError
    def initialize(message = nil, error_code: 'SYSTEM_ERROR', http_status: 500, metadata: {})
      super
    end
  end

  # 外部サービスエラー
  class ExternalServiceError < SystemError
    attr_reader :service_name, :original_error

    def initialize(message = nil, service_name: nil, original_error: nil, metadata: {})
      @service_name = service_name
      @original_error = original_error
      super(
        message || "外部サービスエラー: #{service_name}",
        error_code: 'EXTERNAL_SERVICE_ERROR',
        http_status: 503,
        metadata: metadata.merge(
          service_name: service_name,
          original_error_class: original_error&.class&.name,
          original_message: original_error&.message
        )
      )
    end
  end

  # データベースエラー
  class DatabaseError < SystemError
    def initialize(message = nil, metadata: {})
      super(
        message || 'データベースエラー',
        error_code: 'DATABASE_ERROR',
        http_status: 500,
        metadata: metadata
      )
    end
  end

  module_function

  # === カスタム例外階層のデモンストレーション ===
  #
  # 例外階層を構築することで以下の利点がある:
  # - rescue 節で粒度を制御できる（個別 or カテゴリ単位）
  # - エラーに付随するメタデータを標準化できる
  # - エラー報告システムとの連携が容易になる
  def demonstrate_exception_hierarchy
    hierarchy = {
      # すべてのカスタム例外は StandardError のサブクラス
      all_inherit_standard_error: [
        ApplicationError, BusinessError, ValidationError,
        AuthorizationError, SystemError, ExternalServiceError, DatabaseError
      ].all? { |klass| klass < StandardError },

      # BusinessError は ApplicationError のサブクラス
      business_is_application: BusinessError < ApplicationError,
      validation_is_business: ValidationError < BusinessError,
      system_is_application: SystemError < ApplicationError,

      # rescue の粒度制御
      # rescue ApplicationError → すべてのアプリケーション例外をキャッチ
      # rescue BusinessError → ビジネスロジックエラーのみ
      # rescue ValidationError → バリデーションエラーのみ
      ancestors_chain: ValidationError.ancestors.select { |a| a <= ApplicationError }
    }

    # エラーコードと HTTP ステータスのマッピング
    errors = {
      validation: ValidationError.new('名前は必須です', field: :name, errors: ['blank']),
      authorization: AuthorizationError.new(resource: 'User', action: 'delete'),
      external: ExternalServiceError.new(service_name: 'PaymentAPI')
    }

    hierarchy[:error_codes] = errors.transform_values(&:error_code)
    hierarchy[:http_statuses] = errors.transform_values(&:http_status)

    hierarchy
  end

  # === rescue_from パターン ===
  #
  # Rails の ActionController::Base は rescue_from メソッドを提供する。
  # これにより、コントローラ全体で例外を統一的にハンドリングできる。
  #
  # 本メソッドでは rescue_from の概念をシンプルなクラスで再現する。
  # rescue_from の登録順序に注意: 後に登録したものが先にマッチする。
  def demonstrate_rescue_from_pattern
    # rescue_from パターンをシンプルに再現するクラス
    handler_class = Class.new do
      # rescue_from のハンドラを登録するクラスメソッド
      class << self
        def rescue_handlers
          @rescue_handlers ||= []
        end

        def rescue_from(exception_class, with: nil, &block)
          handler = block || method(with)
          # Rails と同様に後から登録したものを先頭に追加
          rescue_handlers.unshift([exception_class, handler])
        end
      end

      # 登録されたハンドラでエラーを処理する
      def handle_error(error)
        self.class.rescue_handlers.each do |exception_class, handler|
          return handler.call(error) if error.is_a?(exception_class)
        end
        raise error # ハンドラが見つからない場合は再 raise
      end
    end

    # ハンドラの登録（Rails コントローラと同様の書き方）
    handler_class.rescue_from(ApplicationError) do |error|
      { status: error.http_status, error: error.error_code, message: error.message }
    end

    handler_class.rescue_from(ValidationError) do |error|
      { status: 422, error: 'VALIDATION', field: error.field, details: error.errors }
    end

    instance = handler_class.new

    # ValidationError は先にマッチする（後に登録 → 先頭に追加）
    validation_result = instance.handle_error(
      ValidationError.new('不正な値', field: :email, errors: ['invalid'])
    )

    # SystemError は ApplicationError のハンドラにマッチ
    system_result = instance.handle_error(
      SystemError.new('サーバー内部エラー')
    )

    {
      validation_handled: validation_result,
      system_handled: system_result,
      handler_count: handler_class.rescue_handlers.size
    }
  end

  # === Exception vs StandardError ===
  #
  # Ruby の例外階層:
  #   Exception
  #   ├── NoMemoryError
  #   ├── ScriptError (SyntaxError, LoadError, NotImplementedError)
  #   ├── SecurityError
  #   ├── SignalException (Interrupt)
  #   ├── SystemExit
  #   └── StandardError ← rescue のデフォルトターゲット
  #       ├── RuntimeError
  #       ├── TypeError
  #       ├── ArgumentError
  #       ├── NameError (NoMethodError)
  #       └── ...
  #
  # 「rescue => e」は StandardError のみをキャッチする。
  # 「rescue Exception => e」は SystemExit や Interrupt もキャッチしてしまい、
  # Ctrl+C やプロセス終了を妨げるため、絶対に使ってはならない。
  def demonstrate_exception_vs_standard_error
    # rescue（クラス指定なし）は StandardError のみキャッチ
    caught_standard = begin
      raise 'ランタイムエラー'
    rescue => e # rubocop:disable Style/RescueStandardError
      { caught: true, class: e.class.name }
    end

    # StandardError 以外の例外は素通りする（教材用にシミュレーション）
    non_standard_errors = [NoMemoryError, SignalException, SystemExit]

    hierarchy_info = {
      # StandardError のサブクラスかどうかを確認
      runtime_is_standard: RuntimeError < StandardError,
      type_error_is_standard: TypeError < StandardError,
      # これらは StandardError のサブクラスではない
      signal_is_not_standard: !(SignalException < StandardError),
      system_exit_is_not_standard: !(SystemExit < StandardError),
      no_memory_is_not_standard: !(NoMemoryError < StandardError),
      # rescue のデフォルトターゲット
      default_rescue_target: 'StandardError',
      caught_standard: caught_standard,
      # 素の rescue ではキャッチされない例外クラス
      non_standard_examples: non_standard_errors.map(&:name)
    }

    # 危険なパターンの説明
    hierarchy_info[:dangerous_pattern] = <<~EXPLANATION.strip
      rescue Exception => e は以下をキャッチしてしまう:
      - SystemExit: exit 呼び出しが無効になる
      - Interrupt: Ctrl+C が効かなくなる
      - NoMemoryError: メモリ枯渇時の復旧が不可能
      常に rescue StandardError => e（または具体的な例外クラス）を使うこと
    EXPLANATION

    hierarchy_info
  end

  # === エラーコンテキスト付加 ===
  #
  # 例外にメタデータを付加して、デバッグや監視を容易にする。
  # エラーコード、HTTP ステータス、リクエスト情報などを構造化する。
  def demonstrate_error_context_enrichment
    # メタデータ付きのエラーを生成
    error = ValidationError.new(
      'メールアドレスの形式が不正です',
      field: :email,
      errors: ['invalid_format'],
      metadata: {
        request_id: 'req_abc123',
        user_id: 42,
        input_value: 'not-an-email'
      }
    )

    # 構造化されたエラーレポート
    report = error.to_error_report

    {
      error_class: report[:error_class],
      error_code: report[:error_code],
      http_status: report[:http_status],
      has_metadata: !report[:metadata].empty?,
      metadata_keys: report[:metadata].keys.sort,
      # エラーレポートには診断に必要な情報がすべて含まれる
      report_keys: report.keys.sort
    }
  end

  # === Circuit Breaker パターン ===
  #
  # 外部サービスの障害がアプリケーション全体に波及するのを防ぐパターン。
  # 3つの状態を持つ:
  #   - :closed（正常）: リクエストをそのまま通す
  #   - :open（遮断）: リクエストを即座に失敗させる（外部サービスを呼ばない）
  #   - :half_open（半開）: 試験的にリクエストを通し、回復を確認する
  #
  # 状態遷移:
  #   closed → (失敗が閾値に達する) → open
  #   open → (タイムアウト経過) → half_open
  #   half_open → (成功) → closed
  #   half_open → (失敗) → open
  class CircuitBreaker
    attr_reader :state, :failure_count, :success_count, :last_failure_time

    # @param failure_threshold [Integer] open に遷移するまでの失敗回数
    # @param recovery_timeout [Numeric] open → half_open に遷移するまでの秒数
    # @param success_threshold [Integer] half_open → closed に遷移するまでの成功回数
    def initialize(failure_threshold: 3, recovery_timeout: 30, success_threshold: 1)
      @failure_threshold = failure_threshold
      @recovery_timeout = recovery_timeout
      @success_threshold = success_threshold
      @state = :closed
      @failure_count = 0
      @success_count = 0
      @last_failure_time = nil
    end

    # ブロック内の処理を Circuit Breaker で保護して実行する
    # @yield 保護対象の処理
    # @return ブロックの戻り値
    # @raise ExternalServiceError サーキットが open の場合
    def call(&)
      case @state
      when :closed
        execute_in_closed(&)
      when :open
        handle_open_state(&)
      when :half_open
        execute_in_half_open(&)
      end
    end

    private

    def execute_in_closed(&block)
      result = block.call
      record_success
      result
    rescue StandardError => e
      record_failure
      raise e
    end

    def handle_open_state(&)
      if recovery_timeout_elapsed?
        transition_to(:half_open)
        execute_in_half_open(&)
      else
        raise ExternalServiceError.new(
          'Circuit breaker is open',
          service_name: 'protected_service',
          metadata: { state: @state, failure_count: @failure_count }
        )
      end
    end

    def execute_in_half_open(&block)
      result = block.call
      record_success
      transition_to(:closed) if @success_count >= @success_threshold
      result
    rescue StandardError => e
      transition_to(:open)
      raise e
    end

    def record_success
      @success_count += 1
      @failure_count = 0 if @state == :closed
    end

    def record_failure
      @failure_count += 1
      @last_failure_time = Time.now
      return unless @failure_count >= @failure_threshold

      transition_to(:open)
    end

    def transition_to(new_state)
      @state = new_state
      @failure_count = 0 if new_state == :closed
      @success_count = 0 if new_state == :half_open
    end

    def recovery_timeout_elapsed?
      return true if @last_failure_time.nil?

      Time.now - @last_failure_time >= @recovery_timeout
    end
  end

  # Circuit Breaker パターンのデモンストレーション
  def demonstrate_circuit_breaker
    breaker = CircuitBreaker.new(failure_threshold: 3, recovery_timeout: 0.1, success_threshold: 1)
    results = {}

    # 1. 正常時（closed 状態）
    results[:initial_state] = breaker.state
    results[:success_result] = breaker.call { '成功' }
    results[:after_success_state] = breaker.state

    # 2. 失敗を重ねて open に遷移
    3.times do
      breaker.call { raise '外部サービス障害' }
    rescue StandardError
      # 失敗を記録
    end
    results[:after_failures_state] = breaker.state
    results[:failure_count] = breaker.failure_count

    # 3. open 状態ではリクエストが即座に失敗する
    results[:open_raises] = begin
      breaker.call { 'この処理は実行されない' }
    rescue ExternalServiceError => e
      { error: true, message: e.message }
    end

    # 4. タイムアウト経過後、half_open に遷移して回復を試みる
    sleep(0.15)
    results[:recovery_result] = breaker.call { '回復成功' }
    results[:after_recovery_state] = breaker.state

    results
  end

  # === リトライ with バックオフ ===
  #
  # 一時的な障害に対して指数関数的バックオフで再試行する。
  # ジッター（ランダム遅延）を加えて thundering herd 問題を防ぐ。
  #
  # バックオフの計算式:
  #   delay = base_delay * (multiplier ^ attempt) + random_jitter
  #
  # リトライすべきエラーとすべきでないエラーを区別することが重要。
  # - リトライすべき: ネットワークタイムアウト、503、429
  # - リトライすべきでない: 400、401、404（再試行しても結果は同じ）
  class RetryWithBackoff
    attr_reader :attempts, :delays

    # @param max_retries [Integer] 最大リトライ回数
    # @param base_delay [Numeric] 基本待機時間（秒）
    # @param multiplier [Numeric] 指数バックオフの乗数
    # @param max_delay [Numeric] 最大待機時間（秒）
    # @param retryable_errors [Array<Class>] リトライ対象の例外クラス
    def initialize(max_retries: 3, base_delay: 0.1, multiplier: 2, max_delay: 30, retryable_errors: [StandardError])
      @max_retries = max_retries
      @base_delay = base_delay
      @multiplier = multiplier
      @max_delay = max_delay
      @retryable_errors = retryable_errors
      @attempts = 0
      @delays = []
    end

    # リトライ付きでブロックを実行する
    # @yield 実行対象の処理
    # @return ブロックの戻り値
    def call(&block)
      @attempts = 0
      @delays = []

      begin
        @attempts += 1
        block.call
      rescue *@retryable_errors => e
        if @attempts <= @max_retries
          delay = calculate_delay(@attempts)
          @delays << delay
          sleep(delay)
          retry
        end
        raise e
      end
    end

    private

    # 指数バックオフ + ジッターで待機時間を計算する
    def calculate_delay(attempt)
      # 指数バックオフ: base_delay * multiplier^(attempt-1)
      exponential = @base_delay * (@multiplier**(attempt - 1))
      # ジッター: 0〜指数バックオフ値のランダム値を加算
      jitter = rand * exponential * 0.1
      # 最大待機時間を超えないようにする
      [exponential + jitter, @max_delay].min
    end
  end

  # リトライ with バックオフのデモンストレーション
  def demonstrate_retry_with_backoff
    results = {}

    # 1. 最終的に成功するケース
    call_count = 0
    retry_handler = RetryWithBackoff.new(
      max_retries: 3,
      base_delay: 0.01,
      multiplier: 2,
      retryable_errors: [RuntimeError]
    )

    result = retry_handler.call do
      call_count += 1
      raise '一時的障害' if call_count < 3

      '3回目で成功'
    end

    results[:eventual_success] = {
      result: result,
      total_attempts: retry_handler.attempts,
      retries: retry_handler.delays.length,
      delays_increasing: retry_handler.delays.each_cons(2).all? { |a, b| b > a }
    }

    # 2. リトライ上限に達して失敗するケース
    always_fail_handler = RetryWithBackoff.new(
      max_retries: 2,
      base_delay: 0.01,
      retryable_errors: [RuntimeError]
    )

    results[:max_retries_exceeded] = begin
      always_fail_handler.call { raise '永続的障害' }
    rescue RuntimeError => e
      {
        error: e.message,
        total_attempts: always_fail_handler.attempts,
        retries: always_fail_handler.delays.length
      }
    end

    # 3. リトライ対象外のエラーは即座に失敗する
    selective_handler = RetryWithBackoff.new(
      max_retries: 3,
      base_delay: 0.01,
      retryable_errors: [RuntimeError]
    )

    results[:non_retryable] = begin
      selective_handler.call { raise ArgumentError, '不正な引数' }
    rescue ArgumentError => e
      {
        error: e.message,
        total_attempts: selective_handler.attempts,
        retries: selective_handler.delays.length
      }
    end

    results
  end

  # === エラーラッピング（cause チェーン） ===
  #
  # 低レベルの例外をドメイン固有の例外でラップする。
  # Ruby 2.1+ では raise で新しい例外を投げると、
  # 元の例外が cause として自動的にチェーンされる。
  #
  # これにより:
  # - 上位層はドメインの言葉でエラーを扱える
  # - デバッグ時は cause を辿って根本原因を追跡できる
  def demonstrate_error_wrapping
    results = {}

    # 低レベルエラーをドメインエラーにラップ
    begin
      simulate_payment_processing
    rescue ExternalServiceError => e
      results[:wrapped_error] = {
        domain_error_class: e.class.name,
        domain_message: e.message,
        service_name: e.service_name,
        # cause で元の例外にアクセスできる
        has_cause: !e.cause.nil?,
        cause_class: e.cause&.class&.name,
        cause_message: e.cause&.message,
        # cause チェーンを辿って根本原因を特定
        root_cause: root_cause(e).class.name
      }
    end

    # 多段階の cause チェーン
    begin
      simulate_multi_layer_error
    rescue ApplicationError => e
      chain = cause_chain(e)
      results[:cause_chain] = {
        chain_length: chain.length,
        chain_classes: chain.map { |err| err.class.name }
      }
    end

    results
  end

  # 決済処理のシミュレーション（低レベルエラーをラップする例）
  def simulate_payment_processing
    # 低レベルの HTTP エラーが発生
    raise Errno::ECONNREFUSED, 'Connection refused - connect(2) for 127.0.0.1:3000'
  rescue Errno::ECONNREFUSED => e
    # ドメイン固有の例外にラップして再 raise
    raise ExternalServiceError.new(
      '決済サービスに接続できません',
      service_name: 'PaymentGateway',
      original_error: e
    )
  end

  # 多段階エラーラッピングのシミュレーション
  # ネストした begin/rescue で多段階の cause チェーンを構築する
  def simulate_multi_layer_error
    begin
      begin
        raise IOError, 'stream closed'
      rescue IOError
        raise Errno::ECONNREFUSED, '接続拒否'
      end
    rescue Errno::ECONNREFUSED
      raise ExternalServiceError.new('外部API障害', service_name: 'UserAPI')
    end
  rescue ExternalServiceError
    raise ApplicationError.new('ユーザー同期に失敗しました', error_code: 'SYNC_FAILED')
  end

  # cause チェーンの根本原因を取得する
  def root_cause(error)
    current = error
    current = current.cause while current.cause
    current
  end

  # cause チェーン全体を配列として取得する
  def cause_chain(error)
    chain = [error]
    current = error
    while current.cause
      current = current.cause
      chain << current
    end
    chain
  end

  # === Fail-fast vs Resilient ===
  #
  # エラー発生時に即座にクラッシュすべきか、
  # 機能を縮退させて動き続けるべきかの判断基準:
  #
  # Fail-fast（即座にクラッシュ）:
  #   - データ不整合のリスクがある場合
  #   - 設定ファイルの読み込み失敗（起動時）
  #   - 必須環境変数の不足
  #   - データベース接続の確立失敗（起動時）
  #
  # Resilient（縮退運転）:
  #   - キャッシュが利用不可でも DB から取得可能
  #   - 外部通知サービスが停止（メイン処理は継続）
  #   - レコメンド機能の障害（デフォルトを表示）
  def demonstrate_fail_fast_vs_resilient
    results = {}

    # Fail-fast パターン: 必須設定の検証
    results[:fail_fast_missing_config] = begin
      require_config!('DATABASE_URL' => nil, 'SECRET_KEY' => 'abc123')
    rescue ApplicationError => e
      { failed: true, message: e.message }
    end

    results[:fail_fast_valid_config] = begin
      require_config!('DATABASE_URL' => 'postgres://localhost/myapp', 'SECRET_KEY' => 'abc123')
    rescue ApplicationError
      { failed: true }
                                       else
                                         { failed: false, message: '設定検証OK' }
    end

    # Resilient パターン: 縮退運転
    results[:resilient_cache_fallback] = fetch_with_fallback(
      primary: -> { raise 'Redis接続エラー' },
      fallback: -> { { source: 'database', data: 'フォールバックデータ' } },
      error_context: 'キャッシュ読み取り'
    )

    results[:resilient_primary_success] = fetch_with_fallback(
      primary: -> { { source: 'cache', data: 'キャッシュデータ' } },
      fallback: -> { { source: 'database', data: 'フォールバックデータ' } },
      error_context: 'キャッシュ読み取り'
    )

    results
  end

  # 必須設定の存在を検証する（Fail-fast パターン）
  def require_config!(config_hash)
    missing = config_hash.select { |_key, value| value.nil? || (value.respond_to?(:empty?) && value.empty?) }.keys
    return true if missing.empty?

    raise ApplicationError.new(
      "必須設定が不足しています: #{missing.join(', ')}",
      error_code: 'MISSING_CONFIG',
      metadata: { missing_keys: missing }
    )
  end

  # プライマリが失敗した場合にフォールバックを使用する（Resilient パターン）
  def fetch_with_fallback(primary:, fallback:, error_context: '')
    primary.call
  rescue StandardError => e
    # 本番ではエラー報告サービスに通知する
    fallback_result = fallback.call
    {
      used_fallback: true,
      error_context: error_context,
      original_error: e.message,
      result: fallback_result
    }
  end

  # === エラー報告統合 ===
  #
  # 本番アプリケーションでは、エラーを構造化して
  # 監視サービス（Sentry、Datadog、Honeybadger 等）に送る。
  #
  # Rails 7.1+ の error.reporter を使うと、
  # アプリケーション全体で統一的なエラー報告が可能になる。
  def demonstrate_error_reporting_integration
    # エラー報告サービスのシンプルなシミュレーション
    reporter = ErrorReporter.new

    # 1. 様々なエラーを報告
    begin
      raise ValidationError.new('不正な入力', field: :name, errors: ['too_short'])
    rescue ValidationError => e
      reporter.report(e, severity: :warning, context: { action: 'user_create' })
    end

    begin
      raise ExternalServiceError.new('タイムアウト', service_name: 'EmailService')
    rescue ExternalServiceError => e
      reporter.report(e, severity: :error, context: { action: 'send_welcome_email' })
    end

    # 2. handle メソッド: エラーを報告しつつ処理を続行（Rails 7.1+ の error.handle 相当）
    handled_result = reporter.handle(fallback: 'デフォルト値') do
      raise '非致命的エラー'
    end

    # 3. record メソッド: エラーを報告しつつ例外を再 raise（Rails 7.1+ の error.record 相当）
    recorded_error = begin
      reporter.record { raise '致命的エラー' }
    rescue RuntimeError => e
      e.message
    end

    {
      total_reports: reporter.reports.length,
      severity_counts: reporter.reports.group_by { |r| r[:severity] }.transform_values(&:length),
      handled_result: handled_result,
      recorded_error: recorded_error,
      report_structure: reporter.reports.first&.keys&.sort
    }
  end

  # エラー報告サービスのシンプルなシミュレーション
  # Rails 7.1+ の ActiveSupport::ErrorReporter に相当する概念
  class ErrorReporter
    attr_reader :reports

    def initialize
      @reports = []
    end

    # エラーを報告する
    def report(error, severity: :error, context: {})
      entry = {
        error_class: error.class.name,
        message: error.message,
        severity: severity,
        context: context,
        timestamp: Time.now.iso8601
      }

      # ApplicationError のサブクラスなら追加情報を付加
      if error.is_a?(ApplicationError)
        entry[:error_code] = error.error_code
        entry[:http_status] = error.http_status
        entry[:metadata] = error.metadata
      end

      @reports << entry
      entry
    end

    # エラーを報告しつつ処理を続行する（非致命的エラー向け）
    # Rails 7.1+ の Rails.error.handle に相当
    def handle(fallback: nil, severity: :warning, context: {})
      yield
    rescue StandardError => e
      report(e, severity: severity, context: context)
      fallback
    end

    # エラーを報告しつつ例外を再 raise する（致命的エラー向け）
    # Rails 7.1+ の Rails.error.record に相当
    def record(severity: :error, context: {})
      yield
    rescue StandardError => e
      report(e, severity: severity, context: context)
      raise
    end
  end
end
