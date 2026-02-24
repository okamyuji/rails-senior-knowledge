# frozen_string_literal: true

# バックグラウンドジョブ設計のベストプラクティスを解説するモジュール
#
# Railsアプリケーションでは、メール送信、画像処理、外部API連携など
# 時間のかかる処理をバックグラウンドジョブとして非同期実行する。
# このモジュールでは、シニアエンジニアが知るべきジョブ設計の
# ベストプラクティスを教育的な実装を通じて学ぶ。
#
# 実際のActiveJobやSidekiqの使用ではなく、設計パターンの理解に焦点を当てる。
module BackgroundJobDesign
  module_function

  # ==========================================================================
  # 1. 冪等性（Idempotency）: 安全にリトライできるジョブの設計
  # ==========================================================================
  #
  # ジョブは必ずリトライされる可能性がある（ネットワーク障害、ワーカー再起動など）。
  # 同じジョブが複数回実行されても結果が同じになる「冪等性」を確保することが重要。
  #
  # 冪等性を実現する手法：
  # - 冪等性キー（idempotency key）で処理済みチェック
  # - UPSERT（INSERT or UPDATE）の活用
  # - 条件付き更新（楽観的ロック等）
  def demonstrate_idempotency
    # --- 冪等性キーによる処理済みチェック ---
    # 処理済みジョブを記録するストア（実際にはRedisやDBを使用）
    processed_jobs = {}

    # 冪等性キー付きジョブの実装例
    idempotent_job = lambda { |idempotency_key, &action|
      # 既に処理済みなら結果を返すだけ（再実行しない）
      if processed_jobs.key?(idempotency_key)
        return { status: :already_processed, result: processed_jobs[idempotency_key] }
      end

      # 初回実行：処理を実行して結果を記録
      result = action.call
      processed_jobs[idempotency_key] = result
      { status: :processed, result: result }
    }

    # 同じキーで2回実行しても、実際の処理は1回だけ
    execution_count = 0
    key = 'order_confirmation_12345'

    first_run = idempotent_job.call(key) do
      execution_count += 1
      'メール送信完了'
    end

    second_run = idempotent_job.call(key) do
      execution_count += 1
      'メール送信完了'
    end

    # --- UPSERTパターン ---
    # データベースへの書き込みを冪等にする
    database = {}

    upsert_operation = lambda { |table, key_column, key_value, attributes|
      existing = database["#{table}:#{key_value}"]
      if existing
        # 既存レコードを更新（冪等）
        database["#{table}:#{key_value}"] = existing.merge(attributes).merge(updated_at: Time.now)
        :updated
      else
        # 新規レコードを挿入
        database["#{table}:#{key_value}"] = attributes.merge(
          key_column => key_value,
          created_at: Time.now,
          updated_at: Time.now
        )
        :inserted
      end
    }

    # 同じデータで2回UPSERTしても安全
    first_upsert = upsert_operation.call('reports', :report_id, 'RPT-001', { total: 1000, status: 'completed' })
    second_upsert = upsert_operation.call('reports', :report_id, 'RPT-001', { total: 1000, status: 'completed' })

    {
      # 冪等性キーによる重複防止
      first_run_status: first_run[:status],
      second_run_status: second_run[:status],
      actual_execution_count: execution_count,
      # UPSERTによる安全な書き込み
      first_upsert_result: first_upsert,
      second_upsert_result: second_upsert,
      database_record_count: database.size
    }
  end

  # ==========================================================================
  # 2. シリアライゼーション安全性: ジョブ引数の設計
  # ==========================================================================
  #
  # ジョブの引数はシリアライズされてキューに格納される。
  # 複雑なオブジェクトをそのまま渡すと以下の問題が発生する：
  #
  # - オブジェクトがシリアライズ不可能な場合がある
  # - ジョブがキューに入ってから実行されるまでにオブジェクトの状態が変わる
  # - シリアライズデータが巨大になりキューを圧迫する
  #
  # ベストプラクティス：
  # - ID（整数/文字列）のみを渡す
  # - ジョブ内でDBから最新のデータを取得する
  # - ActiveJobではGlobalIDを使ってモデルを自動的にID化/復元する
  def demonstrate_serialization_safety
    # --- 悪い例：オブジェクトをそのまま渡す ---
    bad_job_args = {
      description: '複雑なオブジェクトをジョブ引数に渡す（非推奨）',
      example: '{ user: User.find(1), order: Order.find(42) }',
      problems: %w[
        シリアライズ時にオブジェクトの状態がスナップショットされる
        ジョブ実行時にはデータが古くなっている可能性がある
        メモリ使用量が増大する
      ]
    }

    # --- 良い例：IDのみを渡す ---
    good_job_args = {
      description: 'プリミティブ値（ID、文字列）のみを渡す（推奨）',
      example: '{ user_id: 1, order_id: 42 }',
      benefits: [
        'シリアライズデータが小さい',
        'ジョブ実行時に最新データを取得できる',
        'シリアライズ/デシリアライズの失敗リスクが低い'
      ]
    }

    # --- GlobalIDの概念 ---
    # ActiveJobはGlobalIDを使ってActiveRecordオブジェクトを自動変換する
    #
    # 内部動作:
    #   ジョブ登録時: User.find(1) → "gid://app/User/1"（文字列化）
    #   ジョブ実行時: "gid://app/User/1" → User.find(1)（復元）

    # GlobalID風のシリアライザ実装（教育用）
    global_id_serializer = {
      serialize: lambda { |model_name, id|
        "gid://myapp/#{model_name}/#{id}"
      },
      deserialize: lambda { |gid_string|
        match = gid_string.match(%r{gid://\w+/(\w+)/(\d+)})
        { model: match[1], id: match[2].to_i } if match
      }
    }

    serialized = global_id_serializer[:serialize].call('User', 42)
    deserialized = global_id_serializer[:deserialize].call(serialized)

    # --- 許容される引数の型 ---
    safe_types = [
      { type: 'Integer', example: 'user_id: 42' },
      { type: 'String', example: 'email: "user@example.com"' },
      { type: 'Symbol', example: 'status: :pending' },
      { type: 'Boolean', example: 'force: true' },
      { type: 'Float', example: 'amount: 99.99' },
      { type: 'Array（プリミティブのみ）', example: 'ids: [1, 2, 3]' },
      { type: 'Hash（プリミティブのみ）', example: '{ key: "value" }' }
    ]

    {
      bad_pattern: bad_job_args,
      good_pattern: good_job_args,
      global_id_serialized: serialized,
      global_id_deserialized: deserialized,
      safe_argument_types: safe_types
    }
  end

  # ==========================================================================
  # 3. リトライ戦略: 指数バックオフとデッドレターキュー
  # ==========================================================================
  #
  # ジョブが失敗した場合のリトライ戦略は慎重に設計する必要がある。
  # 即座にリトライすると障害を悪化させる可能性がある（thundering herd問題）。
  #
  # 推奨パターン：
  # - 指数バックオフ（exponential backoff）+ ジッタ（jitter）
  # - 最大リトライ回数の制限
  # - デッドレターキュー（DLQ）で失敗ジョブを隔離
  def demonstrate_retry_strategies
    # --- 指数バックオフの計算 ---
    # wait = base ** attempt（ジッタなし）
    # wait = base ** attempt + rand(jitter)（ジッタあり）

    # リトライ間隔の例（ジッタなし、デモ用）
    backoff_schedule = (0..7).map do |attempt|
      interval = [2**attempt, 3600].min
      { attempt: attempt, wait_seconds: interval, wait_human: format_duration(interval) }
    end

    # --- リトライハンドラの実装例 ---
    retry_handler = create_retry_handler(max_retries: 3, base_interval: 2)

    # 一時的なエラーで3回失敗してから成功するシナリオ
    call_count = 0
    retry_result = retry_handler.call do
      call_count += 1
      raise '一時的なネットワークエラー' if call_count < 3

      '処理成功'
    end

    # --- デッドレターキュー（DLQ）の概念 ---
    dead_letter_queue = []
    dlq_handler = create_retry_handler(max_retries: 2, base_interval: 1)

    # 永続的に失敗するジョブ
    permanent_failure = dlq_handler.call do
      raise '外部サービスが永続的に停止中'
    end

    # 最大リトライ後にDLQに送信
    if permanent_failure[:status] == :max_retries_exceeded
      dead_letter_queue << {
        job_id: 'job_999',
        error: permanent_failure[:last_error],
        failed_at: Time.now,
        retry_count: permanent_failure[:attempts]
      }
    end

    {
      backoff_schedule: backoff_schedule,
      retry_result_status: retry_result[:status],
      retry_attempts: retry_result[:attempts],
      retry_call_count: call_count,
      permanent_failure_status: permanent_failure[:status],
      dead_letter_queue_size: dead_letter_queue.size,
      dead_letter_queue_entry: dead_letter_queue.first
    }
  end

  # ==========================================================================
  # 4. ジョブタイムアウト: スタックしたジョブの防止
  # ==========================================================================
  #
  # ジョブがハングアップするとワーカースレッドがブロックされ、
  # 他のジョブの処理に影響する。タイムアウトを設定して
  # スタックしたジョブを強制終了することが重要。
  #
  # タイムアウトの種類：
  # - ジョブ全体のタイムアウト
  # - 個別の外部API呼び出しのタイムアウト
  # - データベースクエリのタイムアウト
  def demonstrate_job_timeout
    # --- Timeout モジュールを使ったジョブタイムアウト ---
    require 'timeout'

    # 正常に完了するジョブ（タイムアウト内）
    normal_result = begin
      Timeout.timeout(2) do
        # 短い処理（タイムアウト前に完了）
        sleep(0.01)
        { status: :completed, message: '正常完了' }
      end
    rescue Timeout::Error
      { status: :timeout, message: 'タイムアウト' }
    end

    # タイムアウトするジョブ
    timeout_result = begin
      Timeout.timeout(0.05) do
        sleep(1) # タイムアウトを超える処理
        { status: :completed, message: '正常完了' }
      end
    rescue Timeout::Error
      { status: :timeout, message: 'ジョブがタイムアウトしました（制限: 0.05秒）' }
    end

    # --- タイムアウト設計のベストプラクティス ---
    timeout_config = {
      # ジョブ種別ごとにタイムアウトを設定
      email_sending: { timeout: 30, description: 'メール送信は30秒以内' },
      image_processing: { timeout: 120, description: '画像処理は120秒以内' },
      api_sync: { timeout: 60, description: '外部API同期は60秒以内' },
      report_generation: { timeout: 300, description: 'レポート生成は300秒以内' },

      # アンチパターン
      antipattern: {
        description: 'Timeout.timeout はThread#raiseを使用するため安全でない場合がある',
        recommendation: '外部接続にはNet::HTTPのopen_timeout/read_timeoutを使用する',
        alternative: 'process-levelのタイムアウト（SidekiqのJobTimeout等）が安全'
      }
    }

    # --- 個別操作のタイムアウト例 ---
    operation_timeouts = {
      http_request: {
        open_timeout: 5,
        read_timeout: 30,
        write_timeout: 30,
        code_example: 'Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 30)'
      },
      database_query: {
        statement_timeout: '5s',
        code_example: 'ActiveRecord::Base.connection.execute("SET statement_timeout = \'5s\'")'
      }
    }

    {
      normal_job: normal_result,
      timeout_job: timeout_result,
      timeout_config: timeout_config,
      operation_timeouts: operation_timeouts
    }
  end

  # ==========================================================================
  # 5. ジョブ優先度: キュー設計とワークロード分離
  # ==========================================================================
  #
  # すべてのジョブを単一キューで処理すると、重要なジョブが
  # 大量の低優先度ジョブに埋もれてしまう。
  # キューを分離し、優先度に応じたワーカー配置を行う。
  #
  # 設計原則：
  # - ユーザー体験に直結するジョブは高優先度キューに
  # - バッチ処理やレポートは低優先度キューに
  # - キューごとにワーカー数を調整
  def demonstrate_job_priority
    # --- キュー設計例 ---
    queue_design = {
      critical: {
        priority: 0,
        workers: 5,
        jobs: %w[パスワードリセットメール 二段階認証コード送信 決済処理],
        max_latency: '5秒以内',
        description: 'ユーザーが即座に結果を期待するジョブ'
      },
      default: {
        priority: 10,
        workers: 10,
        jobs: %w[注文確認メール 通知送信 Webhook配信],
        max_latency: '30秒以内',
        description: '通常のバックグラウンド処理'
      },
      low: {
        priority: 20,
        workers: 3,
        jobs: %w[日次レポート生成 データエクスポート キャッシュウォーミング],
        max_latency: '5分以内',
        description: '遅延が許容されるバッチ処理'
      },
      bulk: {
        priority: 30,
        workers: 2,
        jobs: %w[大量メール送信 データマイグレーション ログ集計],
        max_latency: '制限なし',
        description: '大量処理用の専用キュー'
      }
    }

    # --- 優先度付きキューのシミュレーション ---
    priority_queue = []

    enqueue = lambda { |job_name, queue_name, priority|
      priority_queue << { job: job_name, queue: queue_name, priority: priority, enqueued_at: Time.now }
      priority_queue.sort_by! { |j| j[:priority] }
    }

    # ジョブを異なる優先度で登録
    enqueue.call('データエクスポート', :low, 20)
    enqueue.call('注文確認メール', :default, 10)
    enqueue.call('パスワードリセット', :critical, 0)
    enqueue.call('ログ集計', :bulk, 30)
    enqueue.call('Webhook配信', :default, 10)

    # 優先度順に処理される
    execution_order = priority_queue.map { |j| j[:job] }

    # --- Solid Queueでの設定例 ---
    solid_queue_config = {
      description: 'Rails 8のデフォルトジョブバックエンド',
      config_example: {
        dispatchers: [
          { polling_interval: 1, batch_size: 500 }
        ],
        workers: [
          { queues: ['critical'], threads: 5, processes: 2 },
          { queues: ['default'], threads: 5, processes: 3 },
          { queues: %w[low bulk], threads: 3, processes: 1 }
        ]
      }
    }

    {
      queue_design: queue_design,
      execution_order: execution_order,
      total_queued_jobs: priority_queue.size,
      solid_queue_config: solid_queue_config
    }
  end

  # ==========================================================================
  # 6. バッチ操作: 大きなジョブの分割と進捗管理
  # ==========================================================================
  #
  # 100万件のレコードを処理するジョブを1つのジョブで実行すると：
  # - メモリを大量消費する
  # - 途中で失敗すると最初からやり直し
  # - タイムアウトのリスクが高い
  #
  # ベストプラクティス：
  # - 大きなジョブを小さなチャンクに分割
  # - 各チャンクを独立したジョブとして実行
  # - 進捗をトラッキングして再開可能にする
  def demonstrate_batch_operations
    # --- バッチジョブの分割パターン ---
    total_records = 10_000
    batch_size = 1_000

    # バッチ分割
    batches = (0...total_records).each_slice(batch_size).map.with_index do |chunk, index|
      {
        batch_id: "batch_#{index}",
        offset: chunk.first,
        limit: chunk.size,
        status: :pending
      }
    end

    # --- 進捗トラッカー ---
    progress_tracker = {
      job_id: 'bulk_email_campaign_123',
      total_batches: batches.size,
      completed_batches: 0,
      failed_batches: 0,
      started_at: Time.now,
      batches: batches.dup
    }

    # バッチ処理のシミュレーション（一部成功、一部失敗）
    batches.each_with_index do |batch, index|
      if index == 7 # 8番目のバッチだけ失敗
        batch[:status] = :failed
        batch[:error] = '一時的なDB接続エラー'
        progress_tracker[:failed_batches] += 1
      else
        batch[:status] = :completed
        batch[:processed_count] = batch[:limit]
        progress_tracker[:completed_batches] += 1
      end
    end

    progress_percentage = (progress_tracker[:completed_batches].to_f / progress_tracker[:total_batches] * 100).round(1)

    # --- 失敗バッチの再実行 ---
    failed_batches = batches.select { |b| b[:status] == :failed }
    retriable_batches = failed_batches.map { |b| b.merge(status: :pending_retry, retry_count: 1) }

    # --- ActiveJob風のバッチ分割コード例 ---
    batch_code_example = {
      description: 'find_each/find_in_batchesを使った分割パターン',
      code: <<~RUBY
        # 親ジョブ：バッチを分割して子ジョブを登録
        class BulkEmailJob < ApplicationJob
          def perform(campaign_id)
            campaign = Campaign.find(campaign_id)
            campaign.subscribers.find_in_batches(batch_size: 1000) do |batch|
              # 各バッチを独立したジョブとして登録
              SendBatchEmailJob.perform_later(
                campaign_id: campaign_id,
                subscriber_ids: batch.map(&:id)
              )
            end
          end
        end

        # 子ジョブ：個別バッチを処理
        class SendBatchEmailJob < ApplicationJob
          def perform(campaign_id:, subscriber_ids:)
            campaign = Campaign.find(campaign_id)
            Subscriber.where(id: subscriber_ids).find_each do |subscriber|
              CampaignMailer.send_email(campaign, subscriber).deliver_now
            end
          end
        end
      RUBY
    }

    {
      total_records: total_records,
      batch_size: batch_size,
      total_batches: batches.size,
      completed_batches: progress_tracker[:completed_batches],
      failed_batches_count: progress_tracker[:failed_batches],
      progress_percentage: progress_percentage,
      retriable_batches: retriable_batches.size,
      batch_code_example: batch_code_example[:description]
    }
  end

  # ==========================================================================
  # 7. エラーハンドリング: リトライ可能 vs 永続的失敗
  # ==========================================================================
  #
  # すべてのエラーがリトライで解決するわけではない。
  # エラーを適切に分類し、それぞれに適した処理を行うことが重要。
  #
  # リトライ可能（一時的エラー）：
  # - ネットワークタイムアウト
  # - 一時的なDB接続エラー
  # - レート制限（429 Too Many Requests）
  # - 楽観的ロックの競合
  #
  # リトライ不可（永続的エラー）：
  # - レコードが見つからない（ActiveRecord::RecordNotFound）
  # - バリデーションエラー
  # - 認証エラー（401 Unauthorized）
  # - ビジネスロジックエラー
  def demonstrate_error_handling
    # --- カスタムエラー階層 ---
    # 基底エラークラス
    base_error = Class.new(StandardError)

    # リトライ可能なエラー
    retriable_error = Class.new(base_error)
    network_error = Class.new(retriable_error)
    rate_limit_error = Class.new(retriable_error)
    timeout_error = Class.new(retriable_error)

    # 永続的エラー（リトライ不可）
    permanent_error = Class.new(base_error)
    record_not_found = Class.new(permanent_error)
    validation_error = Class.new(permanent_error)
    authorization_error = Class.new(permanent_error)

    # --- エラー分類に基づくハンドラ ---
    error_handler_results = []

    handle_job_error = lambda { |error|
      result = case error
               when retriable_error
                 { action: :retry, error_class: error.class.name, message: error.message }
               when permanent_error
                 { action: :discard, error_class: error.class.name, message: error.message }
               else
                 { action: :retry_with_alert, error_class: error.class.name, message: error.message }
               end
      error_handler_results << result
      result
    }

    # 各種エラーの処理を実行
    handle_job_error.call(network_error.new('接続タイムアウト'))
    handle_job_error.call(rate_limit_error.new('APIレート制限超過'))
    handle_job_error.call(timeout_error.new('リクエストタイムアウト'))
    handle_job_error.call(record_not_found.new('User ID 999 が見つかりません'))
    handle_job_error.call(validation_error.new('メールアドレスの形式が不正です'))
    handle_job_error.call(authorization_error.new('権限が不足しています'))

    # --- ActiveJob風のエラーハンドリング設定例 ---
    active_job_config = {
      description: 'ActiveJobのretry_on/discard_onパターン',
      code: <<~RUBY
        class PaymentProcessJob < ApplicationJob
          # リトライ可能なエラー：指数バックオフで最大5回
          retry_on Net::OpenTimeout, wait: :polynomially_longer, attempts: 5
          retry_on ActiveRecord::Deadlocked, wait: 5.seconds, attempts: 3

          # 永続的エラー：即座に破棄してログ記録
          discard_on ActiveRecord::RecordNotFound
          discard_on ArgumentError

          def perform(order_id)
            order = Order.find(order_id)
            PaymentGateway.charge(order)
          end
        end
      RUBY
    }

    retry_count = error_handler_results.count { |r| r[:action] == :retry }
    discard_count = error_handler_results.count { |r| r[:action] == :discard }

    {
      error_handler_results: error_handler_results,
      retry_errors: retry_count,
      discard_errors: discard_count,
      total_errors_handled: error_handler_results.size,
      active_job_config: active_job_config[:description]
    }
  end

  # ==========================================================================
  # 8. テストパターン: ジョブのテスト戦略
  # ==========================================================================
  #
  # ジョブのテストは以下の3つのレベルで行う：
  #
  # 1. ユニットテスト: perform メソッドのロジックをテスト
  # 2. エンキューテスト: ジョブが正しくキューに登録されるかテスト
  # 3. 統合テスト: ジョブの非同期実行を含めたE2Eテスト
  #
  # 重要な考慮点：
  # - perform_now を使ってジョブロジックを同期的にテスト
  # - perform_later を使ってキュー登録をテスト（実行はしない）
  # - テスト環境ではキューアダプタを :test に設定
  def demonstrate_testing_patterns
    # --- 教育用のジョブクラス ---
    job_class = create_testable_job_class

    # --- テストパターン1: 同期実行テスト（perform_now 相当） ---
    # ジョブロジックを直接テスト
    job = job_class.new(user_id: 1, action: :welcome_email)
    sync_result = job.perform

    # --- テストパターン2: エンキューテスト（perform_later 相当） ---
    # ジョブがキューに追加されるかをテスト
    job_queue = []
    enqueue_job = lambda { |job_args|
      job_queue << { job_class: job_class.name, args: job_args, enqueued_at: Time.now }
    }

    enqueue_job.call(user_id: 1, action: :welcome_email)
    enqueue_job.call(user_id: 2, action: :reminder)

    # --- テストパターン3: 副作用の検証 ---
    # ジョブの結果（メール送信、DB更新等）をモックで検証
    side_effects = []
    job_with_tracking = job_class.new(
      user_id: 42,
      action: :notification,
      on_complete: ->(result) { side_effects << result }
    )
    job_with_tracking.perform

    # --- テスト用ヘルパーの概念 ---
    test_helpers = {
      assert_enqueued: 'ジョブがキューに登録されたことを確認',
      assert_performed: 'ジョブが実行されたことを確認',
      perform_enqueued_jobs: 'キュー内のジョブをすべて同期実行',
      queue_adapter_test: 'テスト用アダプタでキュー操作を記録'
    }

    # --- ActiveJob テスト設定例 ---
    test_config = {
      description: 'ActiveJobのテストヘルパー使用例',
      code: <<~RUBY
        # spec/rails_helper.rb
        RSpec.configure do |config|
          config.include ActiveJob::TestHelper
        end

        # spec/jobs/payment_process_job_spec.rb
        RSpec.describe PaymentProcessJob do
          # perform_now でロジックをテスト
          it "支払いを処理する" do
            order = create(:order)
            expect { described_class.perform_now(order.id) }
              .to change { order.reload.paid? }.from(false).to(true)
          end

          # perform_later でエンキューをテスト
          it "ジョブがキューに登録される" do
            expect {
              described_class.perform_later(42)
            }.to have_enqueued_job(described_class).with(42).on_queue("default")
          end
        end
      RUBY
    }

    {
      sync_result: sync_result,
      enqueued_jobs_count: job_queue.size,
      enqueued_job_classes: job_queue.map { |j| j[:args][:action] },
      side_effects_recorded: side_effects.size,
      test_helpers: test_helpers,
      test_config: test_config[:description]
    }
  end

  # ==========================================================================
  # プライベートヘルパーメソッド
  # ==========================================================================

  # 秒数を人間が読める形式に変換する
  def format_duration(seconds)
    if seconds < 60
      "#{seconds}秒"
    elsif seconds < 3600
      "#{seconds / 60}分#{seconds % 60}秒"
    else
      hours = seconds / 3600
      minutes = (seconds % 3600) / 60
      "#{hours}時間#{minutes}分"
    end
  end

  # リトライハンドラを生成する
  # @param max_retries [Integer] 最大リトライ回数
  # @param base_interval [Integer] 基本待機秒数（指数バックオフの底）
  # @return [Proc] リトライロジックを含むProc
  def create_retry_handler(max_retries:, base_interval:)
    lambda { |&block|
      attempts = 0
      last_error = nil

      loop do
        attempts += 1
        result = begin
          block.call
        rescue StandardError => e
          last_error = e
          nil
        end

        # 成功した場合
        return { status: :success, result: result, attempts: attempts } if last_error.nil?

        # 最大リトライ回数に到達
        if attempts >= max_retries
          return { status: :max_retries_exceeded, last_error: last_error.message, attempts: attempts }
        end

        # 指数バックオフで待機（テスト用に実際のsleepはスキップ）
        _wait_time = base_interval**attempts
        last_error = nil
      end
    }
  end

  # テスト可能なジョブクラスを生成する
  # @return [Class] 教育用ジョブクラス
  def create_testable_job_class
    Class.new do
      attr_reader :user_id, :action, :on_complete

      def initialize(user_id:, action:, on_complete: nil)
        @user_id = user_id
        @action = action
        @on_complete = on_complete
      end

      def perform
        # ジョブロジック（教育用の簡略実装）
        result = case action
                 when :welcome_email
                   { sent_to: user_id, type: :welcome, status: :delivered }
                 when :reminder
                   { sent_to: user_id, type: :reminder, status: :delivered }
                 when :notification
                   { sent_to: user_id, type: :notification, status: :delivered }
                 else
                   { sent_to: user_id, type: action, status: :unknown_action }
                 end

        # コールバック実行（副作用の追跡用）
        on_complete&.call(result)

        result
      end

      def self.name
        'TestableJob'
      end
    end
  end
end
