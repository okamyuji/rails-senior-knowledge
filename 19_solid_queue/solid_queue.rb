# frozen_string_literal: true

# ============================================================================
# Solid Queue の内部構造を解説するモジュール（Rails 8 デフォルトジョブバックエンド）
# ============================================================================
#
# Solid Queue は Rails 8 で採用されたデータベースベースのジョブキューシステムである。
# Redis を必要とせず、PostgreSQL / MySQL / SQLite のみでジョブキューイングを実現する。
#
# このモジュールでは、シニアエンジニアが理解すべき以下の内部動作を
# インメモリ SQLite を使った教育的実装で学ぶ：
#
# - アーキテクチャ概要: データベーステーブルによるジョブキューイング
# - FOR UPDATE SKIP LOCKED: 安全なジョブ取得のロック機構
# - ジョブライフサイクル: Ready → Claimed → Executed (or Failed) の状態遷移
# - キューポーリング: ワーカーによるジョブ取得の仕組み
# - 同時実行制御: 定期タスクとキュー単位の同時実行制限
# - ジョブ優先度: 優先度に基づく実行順序制御
# - 失敗ハンドリング: failed_executions テーブルとリトライ戦略
# - Sidekiq/Redis との比較: メリット（シンプルさ）とトレードオフ（スループット）
# ============================================================================

require 'active_record'

# === インメモリ SQLite でSolid Queueのスキーマを再現 ===
#
# Solid Queue は以下の主要テーブルを使用する:
#   - solid_queue_jobs: すべてのジョブのマスターレコード
#   - solid_queue_ready_executions: 実行可能なジョブ（ポーリング対象）
#   - solid_queue_claimed_executions: ワーカーが取得済みのジョブ
#   - solid_queue_failed_executions: 実行に失敗したジョブ
#   - solid_queue_scheduled_executions: 将来実行予定のジョブ
#   - solid_queue_recurring_executions: 定期実行ジョブの管理
#   - solid_queue_processes: アクティブなワーカープロセスの登録
#   - solid_queue_semaphores: 同時実行制御用セマフォ
#
# 実際の Solid Queue は FOR UPDATE SKIP LOCKED を使ってジョブを安全に取得するが、
# SQLite はこの構文をサポートしないため、教育的な代替実装で概念を示す。

ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:') unless ActiveRecord::Base.connected?

ActiveRecord::Schema.define do # rubocop:disable Metrics/BlockLength
  # ジョブのマスターテーブル（solid_queue_jobs 相当）
  create_table :sq_jobs, force: true do |t|
    t.string :queue_name, null: false, default: 'default'
    t.string :class_name, null: false
    t.text :arguments
    t.integer :priority, null: false, default: 0
    t.string :active_job_id
    t.datetime :scheduled_at
    t.datetime :finished_at
    t.timestamps
  end

  add_index :sq_jobs, :queue_name
  add_index :sq_jobs, :active_job_id, unique: true
  add_index :sq_jobs, :priority

  # 実行可能ジョブのテーブル（solid_queue_ready_executions 相当）
  # ポーリング対象のテーブル。ジョブが enqueue されるとここにレコードが作られる。
  create_table :sq_ready_executions, force: true do |t|
    t.references :job, null: false, foreign_key: { to_table: :sq_jobs }
    t.string :queue_name, null: false
    t.integer :priority, null: false, default: 0
    t.datetime :created_at, null: false
  end

  add_index :sq_ready_executions, %i[queue_name priority created_at],
            name: 'index_sq_ready_poll'

  # 取得済みジョブのテーブル（solid_queue_claimed_executions 相当）
  # ワーカーがジョブを取得すると、ready_executions から削除され、ここに移動する。
  create_table :sq_claimed_executions, force: true do |t|
    t.references :job, null: false, foreign_key: { to_table: :sq_jobs }
    t.integer :process_id
    t.datetime :created_at, null: false
  end

  # 失敗ジョブのテーブル（solid_queue_failed_executions 相当）
  create_table :sq_failed_executions, force: true do |t|
    t.references :job, null: false, foreign_key: { to_table: :sq_jobs }
    t.text :error_class
    t.text :error_message
    t.text :backtrace
    t.datetime :created_at, null: false
  end

  # スケジュール済みジョブのテーブル（solid_queue_scheduled_executions 相当）
  # perform_later(wait: 5.minutes) のように遅延実行するジョブはここに入る。
  create_table :sq_scheduled_executions, force: true do |t|
    t.references :job, null: false, foreign_key: { to_table: :sq_jobs }
    t.string :queue_name, null: false
    t.integer :priority, null: false, default: 0
    t.datetime :scheduled_at, null: false
    t.datetime :created_at, null: false
  end

  add_index :sq_scheduled_executions, :scheduled_at

  # ワーカープロセスの管理テーブル（solid_queue_processes 相当）
  create_table :sq_processes, force: true do |t|
    t.string :kind, null: false
    t.datetime :last_heartbeat_at, null: false
    t.integer :pid
    t.string :hostname
    t.text :metadata
    t.timestamps
  end

  # 同時実行制御用セマフォテーブル（solid_queue_semaphores 相当）
  create_table :sq_semaphores, force: true do |t|
    t.string :key, null: false
    t.integer :value, null: false, default: 1
    t.datetime :expires_at, null: false
    t.timestamps
  end

  add_index :sq_semaphores, :key, unique: true
  add_index :sq_semaphores, :expires_at
end

module SolidQueueInternals
  # ============================================================================
  # ActiveRecord モデル定義
  # ============================================================================

  # --- ジョブマスターレコード ---
  class Job < ActiveRecord::Base
    self.table_name = 'sq_jobs'

    has_one :ready_execution, dependent: :destroy
    has_one :claimed_execution, dependent: :destroy
    has_one :failed_execution, dependent: :destroy
    has_one :scheduled_execution, dependent: :destroy

    scope :finished, -> { where.not(finished_at: nil) }
    scope :pending, -> { where(finished_at: nil) }
    scope :by_priority, -> { order(priority: :asc, created_at: :asc) }
  end

  # --- 実行可能ジョブ ---
  # Solid Queue のポーリング対象テーブル。
  # 実際の実装では FOR UPDATE SKIP LOCKED を使って
  # 複数ワーカー間の競合を防ぐ。
  class ReadyExecution < ActiveRecord::Base
    self.table_name = 'sq_ready_executions'
    belongs_to :job

    scope :queued_as, ->(queue_name) { where(queue_name: queue_name) }
    scope :ordered, -> { order(priority: :asc, created_at: :asc) }
  end

  # --- 取得済みジョブ ---
  class ClaimedExecution < ActiveRecord::Base
    self.table_name = 'sq_claimed_executions'
    belongs_to :job
  end

  # --- 失敗ジョブ ---
  class FailedExecution < ActiveRecord::Base
    self.table_name = 'sq_failed_executions'
    belongs_to :job
  end

  # --- スケジュール済みジョブ ---
  class ScheduledExecution < ActiveRecord::Base
    self.table_name = 'sq_scheduled_executions'
    belongs_to :job
  end

  # --- ワーカープロセス ---
  class Process < ActiveRecord::Base
    self.table_name = 'sq_processes'
  end

  # --- セマフォ（同時実行制御） ---
  class Semaphore < ActiveRecord::Base
    self.table_name = 'sq_semaphores'
  end

  module_function

  # ============================================================================
  # 1. ジョブのエンキュー（ジョブ投入）
  # ============================================================================
  #
  # Solid Queue でジョブを enqueue すると以下が起こる:
  #   1. sq_jobs テーブルにマスターレコードを作成
  #   2. scheduled_at が未来の場合 → sq_scheduled_executions に登録
  #      scheduled_at が nil または過去の場合 → sq_ready_executions に登録
  #
  # これにより、即時実行ジョブと遅延実行ジョブを分離して管理できる。
  def demonstrate_enqueue
    cleanup_all_tables

    # 即時実行ジョブを enqueue
    immediate_job = Job.create!(
      queue_name: 'default',
      class_name: 'WelcomeEmailJob',
      arguments: '{"user_id": 1}',
      priority: 0,
      active_job_id: SecureRandom.uuid
    )
    ReadyExecution.create!(
      job: immediate_job,
      queue_name: immediate_job.queue_name,
      priority: immediate_job.priority,
      created_at: Time.now
    )

    # 遅延実行ジョブを enqueue（5分後に実行）
    scheduled_time = Time.now + 300
    scheduled_job = Job.create!(
      queue_name: 'default',
      class_name: 'ReminderJob',
      arguments: '{"user_id": 2}',
      priority: 0,
      active_job_id: SecureRandom.uuid,
      scheduled_at: scheduled_time
    )
    ScheduledExecution.create!(
      job: scheduled_job,
      queue_name: scheduled_job.queue_name,
      priority: scheduled_job.priority,
      scheduled_at: scheduled_time,
      created_at: Time.now
    )

    {
      total_jobs: Job.count,
      ready_count: ReadyExecution.count,
      scheduled_count: ScheduledExecution.count,
      immediate_job_class: immediate_job.class_name,
      scheduled_job_class: scheduled_job.class_name,
      # 即時ジョブは ready_executions にある
      immediate_in_ready: ReadyExecution.exists?(job_id: immediate_job.id),
      # 遅延ジョブは scheduled_executions にある
      scheduled_in_scheduled: ScheduledExecution.exists?(job_id: scheduled_job.id)
    }
  end

  # ============================================================================
  # 2. FOR UPDATE SKIP LOCKED の概念と教育的実装
  # ============================================================================
  #
  # === FOR UPDATE SKIP LOCKED とは ===
  #
  # PostgreSQL / MySQL が提供する行ロック機構:
  #   SELECT * FROM sq_ready_executions
  #   WHERE queue_name = 'default'
  #   ORDER BY priority ASC, created_at ASC
  #   LIMIT 1
  #   FOR UPDATE SKIP LOCKED
  #
  # - FOR UPDATE: 選択した行に排他ロックをかける
  # - SKIP LOCKED: 既にロックされている行をスキップする
  #
  # これにより、複数のワーカーが同時にポーリングしても、
  # 同じジョブを取得することがない（二重実行防止）。
  #
  # === SQLite での代替実装 ===
  #
  # SQLite は FOR UPDATE SKIP LOCKED をサポートしないため、
  # Solid Queue は SQLite 使用時にトランザクション + DELETE で代替する。
  # ここでは教育目的でこの代替アルゴリズムを実装する。
  def demonstrate_skip_locked_concept
    cleanup_all_tables

    # 3つのジョブを enqueue（異なる優先度）
    [
      { class_name: 'HighPriorityJob', priority: 1 },
      { class_name: 'MediumPriorityJob', priority: 5 },
      { class_name: 'LowPriorityJob', priority: 10 }
    ].map do |attrs|
      job = Job.create!(
        queue_name: 'default',
        class_name: attrs[:class_name],
        priority: attrs[:priority],
        active_job_id: SecureRandom.uuid
      )
      ReadyExecution.create!(
        job: job,
        queue_name: 'default',
        priority: attrs[:priority],
        created_at: Time.now
      )
      job
    end

    # ワーカー1がジョブを取得（claim）
    # 実際の Solid Queue では FOR UPDATE SKIP LOCKED を使う
    claimed_by_worker1 = claim_jobs(queue_name: 'default', limit: 1, process_id: 1001)

    # ワーカー2がジョブを取得
    # ワーカー1が取得済みのジョブはスキップされる（SKIP LOCKED の効果）
    claimed_by_worker2 = claim_jobs(queue_name: 'default', limit: 1, process_id: 1002)

    {
      total_jobs: Job.count,
      ready_remaining: ReadyExecution.count,
      claimed_count: ClaimedExecution.count,
      # ワーカー1は最も高優先度のジョブを取得
      worker1_claimed: claimed_by_worker1.map(&:class_name),
      # ワーカー2は次の優先度のジョブを取得（ワーカー1のジョブはスキップ）
      worker2_claimed: claimed_by_worker2.map(&:class_name),
      # 残りの ready ジョブ
      remaining_ready: ReadyExecution.ordered.map { |re| re.job.class_name }
    }
  end

  # ============================================================================
  # 3. ジョブライフサイクル: Ready → Claimed → Executed (or Failed)
  # ============================================================================
  #
  # Solid Queue のジョブは以下の状態遷移を辿る:
  #
  #   [Enqueue]
  #       │
  #       ├─ scheduled_at が未来 → ScheduledExecution に登録
  #       │                            │
  #       │                     時間到来 → ReadyExecution に移動
  #       │
  #       └─ 即時実行 → ReadyExecution に登録
  #                         │
  #                   ワーカーが claim → ClaimedExecution に移動
  #                         │             （ReadyExecution は削除）
  #                         │
  #                   ジョブ実行
  #                         │
  #                    ├─ 成功 → Job.finished_at を設定
  #                    │         ClaimedExecution を削除
  #                    │
  #                    └─ 失敗 → FailedExecution に登録
  #                              ClaimedExecution を削除
  def demonstrate_job_lifecycle
    cleanup_all_tables

    # Step 1: ジョブを enqueue
    job = Job.create!(
      queue_name: 'default',
      class_name: 'ProcessOrderJob',
      arguments: '{"order_id": 42}',
      priority: 0,
      active_job_id: SecureRandom.uuid
    )
    ReadyExecution.create!(
      job: job,
      queue_name: 'default',
      priority: 0,
      created_at: Time.now
    )

    state_after_enqueue = {
      ready: ReadyExecution.exists?(job_id: job.id),
      claimed: ClaimedExecution.exists?(job_id: job.id),
      failed: FailedExecution.exists?(job_id: job.id),
      finished: job.finished_at.present?
    }

    # Step 2: ワーカーがジョブを claim
    claim_jobs(queue_name: 'default', limit: 1, process_id: 2001)

    state_after_claim = {
      ready: ReadyExecution.exists?(job_id: job.id),
      claimed: ClaimedExecution.exists?(job_id: job.id),
      failed: FailedExecution.exists?(job_id: job.id),
      finished: job.reload.finished_at.present?
    }

    # Step 3: ジョブ実行完了
    finish_job(job)

    state_after_finish = {
      ready: ReadyExecution.exists?(job_id: job.id),
      claimed: ClaimedExecution.exists?(job_id: job.id),
      failed: FailedExecution.exists?(job_id: job.id),
      finished: job.reload.finished_at.present?
    }

    {
      after_enqueue: state_after_enqueue,
      after_claim: state_after_claim,
      after_finish: state_after_finish
    }
  end

  # ============================================================================
  # 4. 優先度によるジョブ実行順序
  # ============================================================================
  #
  # Solid Queue では priority の値が小さいほど優先度が高い（0 が最高）。
  # 同じ優先度のジョブは created_at の昇順（FIFO）で実行される。
  #
  # ready_executions テーブルのインデックス:
  #   (queue_name, priority ASC, created_at ASC)
  #
  # これにより、ポーリング時に常に最も優先度の高いジョブが取得される。
  def demonstrate_priority_ordering
    cleanup_all_tables

    # 異なる優先度のジョブを逆順で投入
    job_configs = [
      { class_name: 'LowPriorityJob', priority: 10 },
      { class_name: 'CriticalJob', priority: 0 },
      { class_name: 'NormalJob', priority: 5 },
      { class_name: 'AnotherCriticalJob', priority: 0 },
      { class_name: 'BackgroundJob', priority: 20 }
    ]

    job_configs.each_with_index do |config, i|
      job = Job.create!(
        queue_name: 'default',
        class_name: config[:class_name],
        priority: config[:priority],
        active_job_id: SecureRandom.uuid,
        created_at: Time.now + i # 投入順序を区別するため
      )
      ReadyExecution.create!(
        job: job,
        queue_name: 'default',
        priority: config[:priority],
        created_at: Time.now + i
      )
    end

    # 優先度順にジョブを取得
    execution_order = ReadyExecution.ordered.map do |re|
      { class_name: re.job.class_name, priority: re.priority }
    end

    # 1つずつ claim して実行順序を確認
    claimed_order = []
    5.times do |i|
      claimed = claim_jobs(queue_name: 'default', limit: 1, process_id: 3000 + i)
      claimed_order << claimed.first&.class_name
    end

    {
      execution_order: execution_order,
      claimed_order: claimed_order,
      # priority=0 のジョブが最初に取得される
      first_claimed_is_critical: claimed_order.first == 'CriticalJob'
    }
  end

  # ============================================================================
  # 5. 失敗ハンドリング
  # ============================================================================
  #
  # ジョブ実行中に例外が発生すると:
  #   1. ClaimedExecution が削除される
  #   2. FailedExecution が作成される（エラー情報を記録）
  #   3. Job レコードは残る（finished_at は nil のまま）
  #
  # Solid Queue 自体にはリトライ機構がない。
  # リトライは ActiveJob の retry_on / discard_on に委ねている。
  # これは「ジョブキューの責務はキューイングと配信」という設計思想に基づく。
  def demonstrate_failure_handling
    cleanup_all_tables

    # ジョブを enqueue
    job = Job.create!(
      queue_name: 'default',
      class_name: 'PaymentProcessJob',
      arguments: '{"payment_id": 99}',
      priority: 0,
      active_job_id: SecureRandom.uuid
    )
    ReadyExecution.create!(
      job: job,
      queue_name: 'default',
      priority: 0,
      created_at: Time.now
    )

    # ワーカーがジョブを claim
    claim_jobs(queue_name: 'default', limit: 1, process_id: 4001)

    # ジョブ実行中にエラー発生をシミュレート
    fail_job(job, error_class: 'PaymentGatewayError',
                  error_message: 'Connection timeout to payment provider',
                  backtrace: "app/jobs/payment_process_job.rb:15:in `perform'\n" \
                             "app/services/payment_gateway.rb:42:in `charge'")

    failed = FailedExecution.find_by(job_id: job.id)

    {
      job_finished: job.reload.finished_at.present?,
      claimed_exists: ClaimedExecution.exists?(job_id: job.id),
      failed_exists: FailedExecution.exists?(job_id: job.id),
      error_class: failed.error_class,
      error_message: failed.error_message,
      has_backtrace: failed.backtrace.present?,
      # 失敗ジョブは手動またはリトライロジックで再投入できる
      can_retry: !job.reload.finished_at.present? && FailedExecution.exists?(job_id: job.id)
    }
  end

  # ============================================================================
  # 6. 同時実行制御（セマフォ）
  # ============================================================================
  #
  # Solid Queue はセマフォを使って特定キーの同時実行数を制限できる。
  # 例: 同じユーザーに対する課金処理は同時に1つだけ実行したい場合
  #
  # ActiveJob 側の設定例:
  #   class BillingJob < ApplicationJob
  #     limits_concurrency to: 1, key: ->(user_id) { "billing_user_#{user_id}" }
  #   end
  #
  # セマフォの動作:
  #   1. ジョブ実行前にセマフォを取得（value をデクリメント）
  #   2. value が 0 になったらそのキーの新しいジョブは待機
  #   3. ジョブ完了後にセマフォを解放（value をインクリメント）
  #   4. expires_at で期限切れセマフォを自動クリーンアップ
  def demonstrate_concurrency_control
    cleanup_all_tables

    semaphore_key = 'billing_user_42'
    max_concurrent = 2
    expires_at = Time.now + 3600

    # セマフォを作成（最大同時実行数 = 2）
    Semaphore.create!(
      key: semaphore_key,
      value: max_concurrent,
      expires_at: expires_at
    )

    # ジョブ1がセマフォを取得
    acquired_first = acquire_semaphore(semaphore_key)
    value_after_first = Semaphore.find_by(key: semaphore_key).value

    # ジョブ2がセマフォを取得
    acquired_second = acquire_semaphore(semaphore_key)
    value_after_second = Semaphore.find_by(key: semaphore_key).value

    # ジョブ3はセマフォを取得できない（上限到達）
    acquired_third = acquire_semaphore(semaphore_key)
    value_after_third = Semaphore.find_by(key: semaphore_key).value

    # ジョブ1が完了してセマフォを解放
    release_semaphore(semaphore_key)
    value_after_release = Semaphore.find_by(key: semaphore_key).value

    # ジョブ3が再度セマフォを取得（今度は成功）
    acquired_after_release = acquire_semaphore(semaphore_key)

    {
      max_concurrent: max_concurrent,
      first_acquired: acquired_first,
      value_after_first: value_after_first,
      second_acquired: acquired_second,
      value_after_second: value_after_second,
      # 3番目のジョブはセマフォ取得に失敗
      third_acquired: acquired_third,
      value_after_third: value_after_third,
      # 解放後は取得可能
      value_after_release: value_after_release,
      acquired_after_release: acquired_after_release
    }
  end

  # ============================================================================
  # 7. キューポーリングとワーカープロセス管理
  # ============================================================================
  #
  # Solid Queue のワーカーは定期的にデータベースをポーリングしてジョブを取得する。
  #
  # 設定例（config/solid_queue.yml）:
  #   production:
  #     dispatchers:
  #       - polling_interval: 1    # 1秒ごとにポーリング
  #         batch_size: 500        # 一度に最大500ジョブ
  #     workers:
  #       - queues: ["default", "mailers"]
  #         threads: 5             # 5スレッドで並行実行
  #         processes: 2           # 2プロセスを起動
  #         polling_interval: 0.1  # 0.1秒ごとにポーリング
  #
  # ワーカープロセスはハートビートを送信し続け、
  # 一定時間ハートビートがないプロセスは dead とみなされる。
  def demonstrate_worker_process_management
    cleanup_all_tables

    # ワーカープロセスを登録
    worker1 = Process.create!(
      kind: 'Worker',
      last_heartbeat_at: Time.now,
      pid: 12_345,
      hostname: 'web-server-01',
      metadata: '{"queues": ["default"], "threads": 5}'
    )

    worker2 = Process.create!(
      kind: 'Worker',
      last_heartbeat_at: Time.now,
      pid: 12_346,
      hostname: 'web-server-01',
      metadata: '{"queues": ["mailers"], "threads": 3}'
    )

    dispatcher = Process.create!(
      kind: 'Dispatcher',
      last_heartbeat_at: Time.now,
      pid: 12_347,
      hostname: 'web-server-01',
      metadata: '{"polling_interval": 1, "batch_size": 500}'
    )

    # ワーカー1のハートビートが古い（dead とみなす）
    dead_threshold = Time.now - 300 # 5分前
    worker1.update!(last_heartbeat_at: dead_threshold - 60)

    alive_processes = Process.where('last_heartbeat_at > ?', dead_threshold)
    dead_processes = Process.where('last_heartbeat_at <= ?', dead_threshold)

    {
      total_processes: Process.count,
      alive_count: alive_processes.count,
      dead_count: dead_processes.count,
      alive_kinds: alive_processes.pluck(:kind).sort,
      dead_pids: dead_processes.pluck(:pid),
      # dead プロセスが claim していたジョブは解放される
      worker1_is_dead: dead_processes.exists?(id: worker1.id),
      worker2_is_alive: alive_processes.exists?(id: worker2.id),
      dispatcher_is_alive: alive_processes.exists?(id: dispatcher.id)
    }
  end

  # ============================================================================
  # 8. Sidekiq/Redis との比較
  # ============================================================================
  #
  # Solid Queue と Sidekiq の比較を返す。
  # これはデータベース操作ではなく、知識の整理のためのメソッド。
  def demonstrate_comparison_with_sidekiq
    {
      solid_queue: {
        backend: 'データベース（PostgreSQL / MySQL / SQLite）',
        dependencies: '追加インフラ不要（DB のみ）',
        throughput: '中程度（DB の I/O に依存）',
        job_claiming: 'FOR UPDATE SKIP LOCKED（DB ネイティブロック）',
        persistence: 'デフォルトで永続化（DB に保存）',
        monitoring: 'Mission Control（Rails エンジン）',
        deployment: 'Rails プロセスに組み込み可能',
        use_case: '中小規模アプリ、シンプルな運用を重視する場合',
        rails_default: 'Rails 8 以降のデフォルト',
        concurrency_control: 'DB セマフォによる同時実行制限',
        scheduled_jobs: 'DB テーブルで管理（cron 的な定期実行対応）',
        advantages: [
          'Redis 不要でインフラがシンプル',
          'ACID トランザクションによる信頼性',
          'ジョブデータの SQL クエリが可能',
          'Rails との密結合による開発体験の良さ',
          'デプロイ・運用コストの削減'
        ]
      },
      sidekiq: {
        backend: 'Redis（インメモリデータストア）',
        dependencies: 'Redis サーバーが必要',
        throughput: '高い（Redis のインメモリ操作）',
        job_claiming: 'BRPOPLPUSH（Redis のアトミック操作）',
        persistence: 'Redis の設定に依存（RDB / AOF）',
        monitoring: 'Sidekiq Web UI（Pro 版で高機能）',
        deployment: '別プロセスとして起動が必要',
        use_case: '大規模アプリ、高スループットが必要な場合',
        rails_default: 'Rails 7 以前の事実上の標準',
        concurrency_control: 'Sidekiq Enterprise の Rate Limiting',
        scheduled_jobs: 'Redis Sorted Set で管理',
        advantages: [
          '非常に高いスループット',
          '成熟したエコシステム（Pro / Enterprise）',
          '豊富なプラグイン・ミドルウェア',
          'リアルタイムモニタリング UI',
          'バッチ処理（Enterprise）'
        ]
      },
      migration_considerations: [
        '既存の Sidekiq ジョブは ActiveJob 経由なら設定変更のみで移行可能',
        'Sidekiq 固有の API（perform_async 等）を使っている場合はコード修正が必要',
        'Redis を他の用途（キャッシュ、Pub/Sub）でも使っている場合は Redis を完全に廃止できない',
        'スループット要件が高い場合は Sidekiq のままが適切',
        '小〜中規模アプリでは Solid Queue への移行でインフラ簡素化の恩恵が大きい'
      ]
    }
  end

  # ============================================================================
  # プライベートヘルパーメソッド
  # ============================================================================

  # --- ジョブの claim（取得）---
  # 実際の Solid Queue での SQL:
  #   SELECT id FROM solid_queue_ready_executions
  #   WHERE queue_name = ?
  #   ORDER BY priority ASC, created_at ASC
  #   LIMIT ?
  #   FOR UPDATE SKIP LOCKED
  #
  # SQLite ではトランザクション内での DELETE + INSERT で代替する。
  def self.claim_jobs(queue_name:, limit:, process_id:)
    claimed_jobs = []

    ActiveRecord::Base.transaction do
      ready = ReadyExecution
              .where(queue_name: queue_name)
              .order(priority: :asc, created_at: :asc)
              .limit(limit)

      ready.each do |execution|
        ClaimedExecution.create!(
          job: execution.job,
          process_id: process_id,
          created_at: Time.now
        )
        claimed_jobs << execution.job
        execution.destroy!
      end
    end

    claimed_jobs
  end

  # --- ジョブの完了処理 ---
  def self.finish_job(job)
    ActiveRecord::Base.transaction do
      job.update!(finished_at: Time.now)
      ClaimedExecution.where(job_id: job.id).destroy_all
    end
  end

  # --- ジョブの失敗処理 ---
  def self.fail_job(job, error_class:, error_message:, backtrace: nil)
    ActiveRecord::Base.transaction do
      FailedExecution.create!(
        job: job,
        error_class: error_class,
        error_message: error_message,
        backtrace: backtrace,
        created_at: Time.now
      )
      ClaimedExecution.where(job_id: job.id).destroy_all
    end
  end

  # --- セマフォの取得 ---
  def self.acquire_semaphore(key)
    ActiveRecord::Base.transaction do
      semaphore = Semaphore.find_by(key: key)
      return false unless semaphore
      return false if semaphore.value <= 0

      semaphore.update!(value: semaphore.value - 1)
      true
    end
  end

  # --- セマフォの解放 ---
  def self.release_semaphore(key)
    ActiveRecord::Base.transaction do
      semaphore = Semaphore.find_by(key: key)
      return false unless semaphore

      semaphore.update!(value: semaphore.value + 1)
      true
    end
  end

  # --- テーブルのクリーンアップ ---
  def self.cleanup_all_tables
    FailedExecution.delete_all
    ClaimedExecution.delete_all
    ReadyExecution.delete_all
    ScheduledExecution.delete_all
    Job.delete_all
    Process.delete_all
    Semaphore.delete_all
  end
end
