# frozen_string_literal: true

# ============================================================================
# Rails Error Reporter API - エラー報告の統一インターフェース
# ============================================================================
#
# Rails 7.0 で導入された Error Reporter は、アプリケーション内のエラーを
# 統一的に報告するための仕組みである。Sentry、Bugsnag、Honeybadger などの
# 外部監視サービスへの統合を標準化し、エラー処理のベストプラクティスを
# フレームワークレベルで提供する。
#
# シニアRailsエンジニアにとって、以下の理由で重要な知識である:
# - エラー報告の一貫性を保ちつつ、監視サービスの切り替えが容易になる
# - handle / record / report の使い分けでエラー処理戦略を明確にできる
# - コンテキスト情報の付与により、デバッグ効率が大幅に向上する
# - 複数の監視サービスを同時に利用するマルチサブスクライバ構成が可能
# ============================================================================

require 'active_support'

module ErrorReporterDemo
  # ==========================================================================
  # エラーサブスクライバのインターフェース
  # ==========================================================================
  #
  # Rails の Error Reporter は、サブスクライバパターンを採用している。
  # 各サブスクライバは `report` メソッドを実装し、エラー発生時に呼び出される。
  #
  # report メソッドのシグネチャ:
  #   report(error, handled:, severity:, context:, source:)
  #
  # - error    : 発生した例外オブジェクト
  # - handled  : エラーが処理済みか（handle: true, record: false）
  # - severity : エラーの深刻度（:error, :warning, :info）
  # - context  : 追加のコンテキスト情報（Hash）
  # - source   : エラーの発生源を示す文字列

  # 基本的なエラーサブスクライバ（ログ収集用）
  class LogSubscriber
    attr_reader :reported_errors

    def initialize
      @reported_errors = []
    end

    # Rails Error Reporter から呼び出されるインターフェース
    def report(error, handled:, severity:, context:, source: 'application')
      @reported_errors << {
        error_class: error.class.name,
        message: error.message,
        handled: handled,
        severity: severity,
        context: context,
        source: source,
        reported_at: Time.now
      }
    end

    def last_error
      @reported_errors.last
    end

    def clear!
      @reported_errors.clear
    end
  end

  # 外部監視サービスを模した高機能サブスクライバ（Sentry風）
  class SentryLikeSubscriber
    attr_reader :events

    def initialize
      @events = []
    end

    def report(error, handled:, severity:, context:, source: 'application')
      # Sentry では severity に応じてイベントレベルを変換する
      level = case severity
              when :error then 'error'
              when :warning then 'warning'
              when :info then 'info'
              else 'error'
              end

      @events << {
        exception: {
          type: error.class.name,
          value: error.message
        },
        level: level,
        tags: {
          handled: handled.to_s,
          source: source
        },
        extra: context,
        timestamp: Time.now.iso8601
      }
    end

    def last_event
      @events.last
    end

    def error_count
      @events.count { |e| e[:level] == 'error' }
    end

    def warning_count
      @events.count { |e| e[:level] == 'warning' }
    end
  end

  # メトリクス収集用サブスクライバ（StatsD / Datadog風）
  class MetricsSubscriber
    attr_reader :counters

    def initialize
      @counters = Hash.new(0)
    end

    def report(error, handled:, severity:, context:, source: 'application') # rubocop:disable Lint/UnusedMethodArgument
      # エラークラスごとにカウント
      @counters["error.#{error.class.name.downcase}"] += 1
      # handled/unhandled でカウント
      @counters[handled ? 'error.handled' : 'error.unhandled'] += 1
      # severity ごとにカウント
      @counters["error.severity.#{severity}"] += 1
      # source ごとにカウント
      @counters["error.source.#{source}"] += 1
    end
  end

  # ==========================================================================
  # ErrorReporter 本体の教育用実装
  # ==========================================================================
  #
  # Rails 本体の ActiveSupport::ErrorReporter を模した教育用実装。
  # 実際の Rails では Rails.error でアクセスできるシングルトンである。
  #
  # 主要な3つのAPI:
  #   handle  - 例外を捕捉し報告する（例外は握りつぶされる）
  #   record  - 例外を報告した後、再送出する
  #   report  - 例外オブジェクトを直接報告する（ブロック不要）

  class ErrorReporter
    attr_reader :subscribers

    # severity 定数
    SEVERITIES = %i[error warning info].freeze

    def initialize
      @subscribers = []
    end

    # --- サブスクライバ管理 ---

    # サブスクライバを登録する
    # 複数の監視サービスを同時に利用する場合、複数のサブスクライバを登録する
    def subscribe(subscriber)
      raise ArgumentError, 'サブスクライバは report メソッドを実装する必要があります' unless subscriber.respond_to?(:report)

      @subscribers << subscriber
      subscriber
    end

    # サブスクライバを解除する
    def unsubscribe(subscriber)
      @subscribers.delete(subscriber)
    end

    # --- handle: 例外を握りつぶして報告する ---
    #
    # ブロック内で発生した例外を捕捉し、サブスクライバに報告した上で
    # nil（またはフォールバック値）を返す。処理は中断されない。
    #
    # 用途:
    # - 失敗しても処理を継続したい場合（メール送信、キャッシュ更新など）
    # - フォールバック値を返したい場合
    # - バックグラウンドジョブの非致命的エラー
    #
    # 使用例（Rails）:
    #   Rails.error.handle(fallback: []) do
    #     ExternalApi.fetch_recommendations(user)
    #   end
    def handle(error_class = StandardError, severity: :warning, context: {}, fallback: nil, source: 'application')
      yield
    rescue error_class => e
      report_to_subscribers(e, handled: true, severity: severity, context: context, source: source)
      fallback
    end

    # --- record: 例外を報告してから再送出する ---
    #
    # ブロック内で発生した例外をサブスクライバに報告した後、
    # 同じ例外を再度 raise する。処理は中断される。
    #
    # 用途:
    # - エラーを監視サービスに確実に報告しつつ、呼び出し元でもハンドリングしたい場合
    # - トランザクション境界でのエラー報告
    # - ミドルウェアでのエラー記録
    #
    # 使用例（Rails）:
    #   Rails.error.record do
    #     CriticalService.process!(order)
    #   end
    def record(error_class = StandardError, severity: :error, context: {}, source: 'application')
      yield
    rescue error_class => e
      report_to_subscribers(e, handled: false, severity: severity, context: context, source: source)
      raise
    end

    # --- report: 例外オブジェクトを直接報告する ---
    #
    # ブロックを使わずに、既に捕捉済みの例外オブジェクトを報告する。
    # Rails 7.1 で追加された API。
    #
    # 用途:
    # - rescue 節で既に例外を捕捉済みの場合
    # - 独自のエラーハンドリングロジックと組み合わせる場合
    # - 条件付きでエラーを報告したい場合
    #
    # 使用例（Rails）:
    #   begin
    #     risky_operation
    #   rescue SpecificError => e
    #     log_locally(e)
    #     Rails.error.report(e, handled: true, severity: :warning)
    #     use_fallback_value
    #   end
    def report(error, handled: true, severity: :warning, context: {}, source: 'application')
      report_to_subscribers(error, handled: handled, severity: severity, context: context, source: source)
    end

    # --- コンテキスト設定（スレッドローカル） ---
    #
    # Rails 7.1 では set_context でスレッドごとのコンテキストを設定できる。
    # ここでは教育用に簡易実装する。
    #
    # 使用例（Rails）:
    #   Rails.error.set_context(user_id: current_user.id, request_id: request.uuid)
    def set_context(ctx)
      thread_context.merge!(ctx)
    end

    def context
      thread_context.dup
    end

    def clear_context!
      Thread.current[:error_reporter_context] = {}
    end

    private

    # すべてのサブスクライバにエラーを通知する
    # 一つのサブスクライバの失敗が他のサブスクライバに影響しないようにする
    def report_to_subscribers(error, handled:, severity:, context:, source:)
      validate_severity!(severity)

      # スレッドコンテキストとメソッド引数のコンテキストをマージ
      merged_context = thread_context.merge(context)

      @subscribers.each do |subscriber|
        subscriber.report(error, handled: handled, severity: severity, context: merged_context, source: source)
      rescue StandardError
        # サブスクライバ自体のエラーは握りつぶす
        # 実際の Rails でも同様の挙動をする
        nil
      end
    end

    def validate_severity!(severity)
      return if SEVERITIES.include?(severity)

      raise ArgumentError, "severity は #{SEVERITIES.inspect} のいずれかでなければなりません（#{severity.inspect} が指定されました）"
    end

    def thread_context
      Thread.current[:error_reporter_context] ||= {}
    end
  end

  module_function

  # ==========================================================================
  # 1. handle - 例外を握りつぶして報告する
  # ==========================================================================

  def demonstrate_handle
    reporter = ErrorReporter.new
    subscriber = LogSubscriber.new
    reporter.subscribe(subscriber)

    # handle はブロック内の例外を捕捉して nil を返す
    result = reporter.handle do
      raise StandardError, 'API接続エラー'
    end

    {
      # handle は例外を握りつぶすので nil が返る
      result_is_nil: result.nil?,
      # サブスクライバにはエラーが報告される
      error_reported: subscriber.last_error[:message],
      # handled フラグは true
      was_handled: subscriber.last_error[:handled],
      # handle のデフォルト severity は :warning
      default_severity: subscriber.last_error[:severity]
    }
  end

  # ==========================================================================
  # 2. handle のフォールバック値
  # ==========================================================================

  def demonstrate_handle_with_fallback
    reporter = ErrorReporter.new
    subscriber = LogSubscriber.new
    reporter.subscribe(subscriber)

    # fallback を指定すると、例外時にその値が返る
    result = reporter.handle(fallback: []) do
      raise StandardError, 'レコメンドAPI障害'
    end

    # 例外が発生しない場合はブロックの戻り値がそのまま返る
    success_result = reporter.handle(fallback: []) do
      %w[item_a item_b item_c]
    end

    {
      # 例外時はフォールバック値が返る
      fallback_result: result,
      # 成功時はブロックの戻り値が返る
      success_result: success_result,
      # エラーは1件のみ報告される（成功時は報告されない）
      total_errors: subscriber.reported_errors.size
    }
  end

  # ==========================================================================
  # 3. record - 例外を報告してから再送出する
  # ==========================================================================

  def demonstrate_record
    reporter = ErrorReporter.new
    subscriber = LogSubscriber.new
    reporter.subscribe(subscriber)

    # record はブロック内の例外を報告した後、再度 raise する
    re_raised = false
    begin
      reporter.record do
        raise '決済処理エラー'
      end
    rescue RuntimeError
      re_raised = true
    end

    {
      # record は例外を再送出する
      exception_re_raised: re_raised,
      # サブスクライバにもエラーが報告される
      error_reported: subscriber.last_error[:message],
      # handled フラグは false（再送出されるため）
      was_handled: subscriber.last_error[:handled],
      # record のデフォルト severity は :error
      default_severity: subscriber.last_error[:severity]
    }
  end

  # ==========================================================================
  # 4. report - 例外オブジェクトを直接報告する
  # ==========================================================================

  def demonstrate_report
    reporter = ErrorReporter.new
    subscriber = LogSubscriber.new
    reporter.subscribe(subscriber)

    # 既に捕捉済みの例外を直接報告する
    begin
      raise ArgumentError, '不正な入力パラメータ'
    rescue ArgumentError => e
      # 独自のハンドリングを行いつつ、報告もする
      reporter.report(e, handled: true, severity: :warning)
    end

    {
      error_class: subscriber.last_error[:error_class],
      message: subscriber.last_error[:message],
      handled: subscriber.last_error[:handled],
      severity: subscriber.last_error[:severity]
    }
  end

  # ==========================================================================
  # 5. 複数サブスクライバの同時利用
  # ==========================================================================
  #
  # 実運用では複数の監視サービスを同時に利用することが多い:
  # - Sentry: エラートラッキングとスタックトレース分析
  # - Datadog: メトリクス収集とダッシュボード表示
  # - 社内ログシステム: 監査ログとコンプライアンス対応

  def demonstrate_multiple_subscribers
    reporter = ErrorReporter.new
    log_subscriber = LogSubscriber.new
    sentry_subscriber = SentryLikeSubscriber.new
    metrics_subscriber = MetricsSubscriber.new

    # 複数のサブスクライバを登録
    reporter.subscribe(log_subscriber)
    reporter.subscribe(sentry_subscriber)
    reporter.subscribe(metrics_subscriber)

    # エラーを報告すると全サブスクライバに通知される
    reporter.handle(severity: :error) do
      raise StandardError, '外部API障害'
    end

    reporter.handle(severity: :warning) do
      raise StandardError, 'キャッシュ更新失敗'
    end

    {
      # 全サブスクライバにエラーが報告された
      log_count: log_subscriber.reported_errors.size,
      sentry_count: sentry_subscriber.events.size,
      metrics_handled: metrics_subscriber.counters['error.handled'],
      # Sentry風サブスクライバにはレベル情報が付与される
      sentry_last_level: sentry_subscriber.last_event[:level],
      # メトリクスサブスクライバには集計情報がある
      metrics_severity_warning: metrics_subscriber.counters['error.severity.warning']
    }
  end

  # ==========================================================================
  # 6. コンテキスト情報の付与
  # ==========================================================================
  #
  # エラーレポートにコンテキスト情報を付与することで、
  # デバッグ時に問題の原因特定が格段に容易になる。
  #
  # 付与すべき代表的なコンテキスト:
  # - user_id: 影響を受けたユーザー
  # - request_id: リクエストの追跡ID
  # - action: 実行中のアクション
  # - params: 関連するパラメータ（個人情報に注意）

  def demonstrate_context_enrichment
    reporter = ErrorReporter.new
    subscriber = LogSubscriber.new
    reporter.subscribe(subscriber)

    # スレッドコンテキストを設定（リクエストの開始時など）
    reporter.set_context(
      user_id: 42,
      request_id: 'req-abc-123'
    )

    # handle/record/report 呼び出し時の context 引数と
    # スレッドコンテキストがマージされる
    reporter.handle(context: { action: 'checkout', cart_id: 999 }) do
      raise StandardError, '在庫確認エラー'
    end

    reported_context = subscriber.last_error[:context]

    # コンテキストをクリア
    reporter.clear_context!

    {
      # スレッドコンテキストと引数コンテキストがマージされる
      has_user_id: reported_context.key?(:user_id),
      has_request_id: reported_context.key?(:request_id),
      has_action: reported_context.key?(:action),
      has_cart_id: reported_context.key?(:cart_id),
      # マージ後の完全なコンテキスト
      full_context: reported_context,
      # クリア後は空になる
      context_after_clear: reporter.context
    }
  end

  # ==========================================================================
  # 7. severity レベルの使い分け
  # ==========================================================================
  #
  # :error   - 致命的なエラー。ユーザー影響あり。即時対応が必要。
  #            例: 決済失敗、データ不整合、認証エラー
  #
  # :warning - 注意が必要だが即時対応は不要。劣化したサービス提供。
  #            例: 外部API障害によるフォールバック、キャッシュミス、レート制限
  #
  # :info    - 情報提供目的。異常だが影響は軽微。
  #            例: 非推奨機能の使用、設定値の自動補正、リトライ成功

  def demonstrate_severity_levels
    reporter = ErrorReporter.new
    sentry_subscriber = SentryLikeSubscriber.new
    reporter.subscribe(sentry_subscriber)

    # :error - 致命的エラー（record のデフォルト）
    begin
      reporter.record(severity: :error) do
        raise StandardError, '決済処理に失敗しました'
      end
    rescue StandardError
      # record は再送出するので rescue が必要
    end

    # :warning - 注意レベル（handle のデフォルト）
    reporter.handle(severity: :warning) do
      raise StandardError, 'レコメンドAPIがタイムアウトしました'
    end

    # :info - 情報レベル
    reporter.handle(severity: :info) do
      raise StandardError, '非推奨のAPIバージョンが使用されています'
    end

    {
      total_events: sentry_subscriber.events.size,
      error_count: sentry_subscriber.error_count,
      warning_count: sentry_subscriber.warning_count,
      # 各イベントのレベルを確認
      event_levels: sentry_subscriber.events.map { |e| e[:level] }
    }
  end

  # ==========================================================================
  # 8. source パラメータによるエラー発生源の識別
  # ==========================================================================
  #
  # source パラメータは、エラーがどの部分から発生したかを示す文字列である。
  # Rails 内部では以下のような source が使われる:
  # - "application"     : アプリケーションコード（デフォルト）
  # - "action_controller" : コントローラ層
  # - "active_record"   : データベース層
  # - "active_job"      : バックグラウンドジョブ
  # - "action_mailer"   : メール送信

  def demonstrate_source_parameter
    reporter = ErrorReporter.new
    metrics_subscriber = MetricsSubscriber.new
    reporter.subscribe(metrics_subscriber)

    # アプリケーションコードからのエラー
    reporter.handle(source: 'application') do
      raise StandardError, 'アプリケーションエラー'
    end

    # Active Job からのエラー
    reporter.handle(source: 'active_job') do
      raise StandardError, 'ジョブ実行エラー'
    end

    # サードパーティライブラリからのエラー
    reporter.handle(source: 'stripe_gem') do
      raise StandardError, 'Stripe API エラー'
    end

    {
      application_errors: metrics_subscriber.counters['error.source.application'],
      active_job_errors: metrics_subscriber.counters['error.source.active_job'],
      stripe_errors: metrics_subscriber.counters['error.source.stripe_gem'],
      total_handled: metrics_subscriber.counters['error.handled']
    }
  end

  # ==========================================================================
  # 9. 特定の例外クラスのみをキャッチする
  # ==========================================================================
  #
  # handle / record の第一引数で、捕捉対象の例外クラスを指定できる。
  # 指定したクラスとそのサブクラスのみが捕捉される。

  def demonstrate_specific_error_class
    reporter = ErrorReporter.new
    subscriber = LogSubscriber.new
    reporter.subscribe(subscriber)

    # ArgumentError のみをキャッチ
    result = reporter.handle(ArgumentError, fallback: 'フォールバック') do
      raise ArgumentError, '不正な引数'
    end

    # RuntimeError は ArgumentError のサブクラスではないのでキャッチされない
    runtime_caught = false
    begin
      reporter.handle(ArgumentError) do
        raise 'ランタイムエラー'
      end
    rescue RuntimeError
      runtime_caught = true
    end

    {
      argument_error_handled: result,
      runtime_error_not_caught: runtime_caught,
      # ArgumentError のみが報告される
      reported_count: subscriber.reported_errors.size,
      reported_class: subscriber.last_error[:error_class]
    }
  end

  # ==========================================================================
  # 10. 実践的な統合パターン
  # ==========================================================================
  #
  # 実際の Rails アプリケーションでの Error Reporter 設定例:
  #
  #   # config/initializers/error_reporting.rb
  #
  #   # Sentry の統合
  #   Rails.error.subscribe(SentrySubscriber.new)
  #
  #   # Datadog の統合
  #   Rails.error.subscribe(DatadogSubscriber.new)
  #
  #   # コントローラでの使用
  #   class OrdersController < ApplicationController
  #     def create
  #       Rails.error.handle(PaymentError, fallback: nil, severity: :error,
  #         context: { order_id: params[:id] }) do
  #         PaymentService.charge!(current_order)
  #       end
  #     end
  #   end
  #
  #   # ジョブでの使用
  #   class ImportJob < ApplicationJob
  #     def perform(file_path)
  #       Rails.error.record(context: { file: file_path }) do
  #         Importer.process!(file_path)
  #       end
  #     end
  #   end

  def demonstrate_integration_pattern
    reporter = ErrorReporter.new
    sentry = SentryLikeSubscriber.new
    metrics = MetricsSubscriber.new
    reporter.subscribe(sentry)
    reporter.subscribe(metrics)

    # リクエストコンテキストを設定（Before Action 相当）
    reporter.set_context(
      user_id: 123,
      request_id: 'req-xyz-789',
      environment: 'production'
    )

    # コントローラアクション内での使用パターン
    # パターン1: 失敗しても継続（レコメンド取得など）
    recommendations = reporter.handle(fallback: [], context: { action: 'show' }) do
      raise StandardError, 'レコメンドエンジン障害'
    end

    # パターン2: 致命的エラーは record で報告して再送出
    payment_error = nil
    begin
      reporter.record(context: { order_id: 456, amount: 9800 }) do
        raise StandardError, '決済プロバイダ通信エラー'
      end
    rescue StandardError => e
      payment_error = e.message
    end

    # リクエスト終了時にコンテキストをクリア
    reporter.clear_context!

    {
      # handle でフォールバック値を使用して処理を継続
      recommendations_fallback: recommendations,
      # record で報告された致命的エラー
      payment_error: payment_error,
      # Sentry に2件のイベントが送信された
      sentry_events: sentry.events.size,
      # handled と unhandled が1件ずつ
      handled_count: metrics.counters['error.handled'],
      unhandled_count: metrics.counters['error.unhandled'],
      # コンテキストにユーザー情報が含まれている
      sentry_first_context: sentry.events.first[:extra]
    }
  end
end
