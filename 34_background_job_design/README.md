# バックグラウンドジョブ設計

## バックグラウンドジョブ設計の理解が重要な理由

Railsアプリケーションでは、レスポンスタイムに影響する重い処理をバックグラウンドジョブとして非同期実行します。メール送信、画像処理、外部API連携、
レポート生成など、多くの機能がバックグラウンドジョブに依存しています。

シニアエンジニアがジョブ設計を深く理解すべき理由は以下の通りです。

- システムの信頼性を確保するためです。ジョブの冪等性やリトライ戦略を適切に設計しないと、データの不整合や重複処理が発生します
- スケーラビリティを維持するためです。キュー設計やバッチ分割を理解していなければ、トラフィック増加時にジョブの滞留が発生します
- 障害耐性を高めるためです。エラーの分類と適切なハンドリングなしには、一時的な障害が永続的な問題に発展します
- 運用効率を向上させるためです。タイムアウト設定やデッドレターキューの知識がなければ、ジョブの監視・復旧が困難になります

## 冪等性の確保

### 冪等性が必要な理由

バックグラウンドジョブは以下の理由で複数回実行される可能性があります。

- ワーカープロセスのクラッシュ後の再起動
- ネットワーク障害によるACK未送信
- ジョブバックエンドの「at least once」配信保証
- 手動リトライによる再実行

冪等性が確保されていないと、メールの二重送信、決済の二重処理、データの重複作成などの問題が発生します。

### 冪等性キー（Idempotency Key）パターン

```ruby

class OrderConfirmationJob < ApplicationJob
  def perform(order_id)
    order = Order.find(order_id)
    idempotency_key = "order_confirmation:#{order_id}"

    # Redisを使った冪等性チェック
    return if Redis.current.exists?(idempotency_key)

    # 処理を実行します
    OrderMailer.confirmation(order).deliver_now

    # 処理済みフラグを設定します（TTL付き）
    Redis.current.set(idempotency_key, "1", ex: 24.hours.to_i)
  end
end

```

### UPSERTパターン

```ruby

class SyncUserProfileJob < ApplicationJob
  def perform(external_user_id)
    profile_data = ExternalAPI.fetch_profile(external_user_id)

    # UPSERT: 存在すれば更新、なければ作成します（冪等）
    UserProfile.upsert(
      {
        external_id: external_user_id,
        name: profile_data[:name],
        email: profile_data[:email],
        synced_at: Time.current
      },
      unique_by: :external_id
    )
  end
end

```

### 条件付き更新

```ruby

class ProcessPaymentJob < ApplicationJob
  def perform(payment_id)
    payment = Payment.find(payment_id)

    # 状態がpendingの場合のみ処理します（冪等性を保証）
    return unless payment.pending?

    result = PaymentGateway.charge(payment)

    # 楽観的ロックで安全に更新します
    payment.with_lock do
      return unless payment.pending?  # ダブルチェック
      payment.update!(status: :completed, transaction_id: result.id)
    end
  end
end

```

## リトライ戦略

### 指数バックオフ（Exponential Backoff）

即座にリトライすると、障害中のサービスにさらに負荷をかけてしまいます。指数バックオフにより、リトライ間隔を徐々に延長します。

| リトライ回数 | 待機時間 | 累積時間
| ------------ | --------- | ---------
| 1回目 | 2秒 | 2秒
| 2回目 | 4秒 | 6秒
| 3回目 | 8秒 | 14秒
| 4回目 | 16秒 | 30秒
| 5回目 | 32秒 | 62秒
| 10回目 | 1024秒（約17分） | 約34分

### ジッタ（Jitter）の重要性

多数のジョブが同時に失敗した場合、すべてが同じタイミングでリトライすると「thundering
herd」問題が発生します。ジッタ（ランダムな遅延）を追加することでリトライタイミングを分散させます。

```ruby

class ApiSyncJob < ApplicationJob
  retry_on Net::OpenTimeout,
           wait: :polynomially_longer,  # Railsの指数バックオフ + ジッタ
           attempts: 10

  # カスタムバックオフの実装例
  retry_on RateLimitError, wait: ->(executions) {
    # 指数バックオフ + フルジッタ
    delay = (2 ** executions) + rand(0..executions)
    [delay, 3600].min  # 最大1時間
  }, attempts: 15
end

```

### ActiveJobのリトライ設定

```ruby

class RobustJob < ApplicationJob
  # 一時的なエラーはリトライします
  retry_on Net::OpenTimeout, wait: :polynomially_longer, attempts: 5
  retry_on ActiveRecord::Deadlocked, wait: 5.seconds, attempts: 3
  retry_on Redis::ConnectionError, wait: 10.seconds, attempts: 5

  # 永続的なエラーは破棄します
  discard_on ActiveRecord::RecordNotFound
  discard_on ArgumentError

  # すべてのエラーをキャッチするフォールバック
  rescue_from StandardError do |exception|
    ErrorReporter.report(exception, context: { job: self.class.name })
    raise  # 再raiseしてデフォルトのリトライに委ねます
  end
end

```

## ジョブ設計のベストプラクティス

### 1. シリアライゼーション安全性

ジョブの引数にはプリミティブ値（ID、文字列、数値）のみを渡します。ActiveRecordオブジェクトを直接渡してはいけません。

```ruby

# 悪い例（非推奨）

UserMailer.welcome(user).deliver_later  # userオブジェクトがシリアライズされます

# 良い例（推奨）

WelcomeEmailJob.perform_later(user_id: user.id)

class WelcomeEmailJob < ApplicationJob
  def perform(user_id:)
    user = User.find(user_id)  # ジョブ実行時に最新のデータを取得します
    UserMailer.welcome(user).deliver_now
  end
end

```

ActiveJobはGlobalIDを使用して、ActiveRecordオブジェクトを自動的にIDに変換し、実行時に復元します。

```ruby

# GlobalIDの内部動作

user = User.find(42)
user.to_global_id.to_s  # => "gid://myapp/User/42"

# ActiveJobは内部的にこの変換を行います

# ジョブ登録時: User#42 → "gid://myapp/User/42"

# ジョブ実行時: "gid://myapp/User/42" → User.find(42)

```

### 2. ジョブタイムアウト

```ruby

class ImageProcessingJob < ApplicationJob
  # Sidekiqの場合
  sidekiq_options timeout: 120

  # Solid Queueの場合（Rails 8）
  limits_concurrency to: 5, key: ->(*) { "image_processing" }

  def perform(image_id)
    image = Image.find(image_id)

    # 個別の外部呼び出しにもタイムアウトを設定します
    processed = Timeout.timeout(90) do
      ImageProcessor.process(image.file)
    end

    image.update!(processed_file: processed, status: :completed)
  rescue Timeout::Error
    image.update!(status: :timeout_failed)
    raise  # リトライに委ねます
  end
end

```

### 3. キュー優先度設計

```yaml

# config/solid_queue.yml（Rails 8）

production:
  dispatchers:

    - polling_interval: 1

      batch_size: 500
  workers:

    - queues: [critical]

      threads: 5
      processes: 2

    - queues: [default, mailers]

      threads: 5
      processes: 3

    - queues: [low, bulk]

      threads: 3
      processes: 1

```

```ruby

class PasswordResetJob < ApplicationJob
  queue_as :critical
end

class WelcomeEmailJob < ApplicationJob
  queue_as :default
end

class DataExportJob < ApplicationJob
  queue_as :low
end

```

### 4. バッチ分割パターン

```ruby

class BulkNotificationJob < ApplicationJob
  BATCH_SIZE = 1000

  def perform(campaign_id)
    campaign = Campaign.find(campaign_id)

    campaign.target_users.find_in_batches(batch_size: BATCH_SIZE) do |batch|
      SendBatchNotificationJob.perform_later(
        campaign_id: campaign_id,
        user_ids: batch.map(&:id)
      )
    end
  end
end

class SendBatchNotificationJob < ApplicationJob
  queue_as :bulk

  def perform(campaign_id:, user_ids:)
    campaign = Campaign.find(campaign_id)

    User.where(id: user_ids).find_each do |user|
      NotificationService.send(campaign, user)
    rescue StandardError => e
      # 個別のエラーでバッチ全体を失敗させません
      Rails.error.report(e, context: { user_id: user.id, campaign_id: campaign_id })
    end
  end
end

```

## 障害耐性パターン

### デッドレターキュー（DLQ）

最大リトライ回数を超えたジョブを隔離し、後で調査・再実行できるようにします。

```ruby

class ApplicationJob < ActiveJob::Base
  # すべてのリトライを使い果たした後のフォールバック
  after_discard do |job, error|
    DeadLetterEntry.create!(
      job_class: job.class.name,
      arguments: job.arguments,
      queue_name: job.queue_name,
      error_class: error.class.name,
      error_message: error.message,
      backtrace: error.backtrace&.first(20),
      failed_at: Time.current
    )

    # 運用チームに通知します
    SlackNotifier.alert(
      channel: "#job-failures",
      message: "ジョブが最終的に失敗しました: #{job.class.name} - #{error.message}"
    )
  end
end

```

### サーキットブレーカーパターン

外部サービスが停止している場合、リトライを繰り返すのではなく、一定期間ジョブの実行を停止します。

```ruby

class ExternalApiJob < ApplicationJob
  CIRCUIT_BREAKER_KEY = "circuit_breaker:external_api"
  FAILURE_THRESHOLD = 5
  RECOVERY_TIME = 5.minutes

  before_perform do
    if circuit_open?
      # サーキットが開いている場合はジョブを後で再実行します
      self.class.set(wait: RECOVERY_TIME).perform_later(*arguments)
      throw :abort
    end
  end

  def perform(resource_id)
    result = ExternalAPI.fetch(resource_id)
    reset_circuit  # 成功したらサーキットをリセットします
    process_result(result)
  rescue ExternalAPI::Error => e
    record_failure
    raise e  # リトライに委ねます
  end

  private

  def circuit_open?
    failure_count = Redis.current.get(CIRCUIT_BREAKER_KEY).to_i
    failure_count >= FAILURE_THRESHOLD
  end

  def record_failure
    Redis.current.incr(CIRCUIT_BREAKER_KEY)
    Redis.current.expire(CIRCUIT_BREAKER_KEY, RECOVERY_TIME.to_i)
  end

  def reset_circuit
    Redis.current.del(CIRCUIT_BREAKER_KEY)
  end
end

```

### ジョブの監視とアラート

```ruby

# ActiveSupport::Notificationsを使ったジョブメトリクス収集

ActiveSupport::Notifications.subscribe("perform.active_job") do |event|
  job = event.payload[:job]
  duration = event.duration

  # メトリクスを記録します
  StatsD.timing("jobs.#{job.class.name}.duration", duration)
  StatsD.increment("jobs.#{job.class.name}.performed")

  # 異常に時間がかかったジョブをアラートします
  if duration > job.class.try(:expected_duration) || 60_000
    Rails.logger.warn("ジョブが想定時間を超過しました: #{job.class.name} (#{duration}ms)")
  end
end

ActiveSupport::Notifications.subscribe("discard.active_job") do |event|
  job = event.payload[:job]
  error = event.payload[:error]

  StatsD.increment("jobs.#{job.class.name}.discarded")
  AlertService.notify("ジョブが破棄されました: #{job.class.name} - #{error.message}")
end

```

## Solid Queue（Rails 8）での実装

Rails 8ではSolid
Queueがデフォルトのジョブバックエンドとなりました。データベースをキューストレージとして使用し、Redisなどの外部依存を排除しています。

```ruby

# Solid Queueの主な特徴

# - データベースベース（PostgreSQL/MySQL/SQLite対応）

# - 並行実行制御（limits_concurrency）

# - 定期実行（recurring tasks）

# - 複数キュー・複数ワーカー対応

class ImportantJob < ApplicationJob
  # 同じキーを持つジョブの同時実行を制限します
  limits_concurrency to: 1, key: ->(user_id) { "user_import:#{user_id}" }

  queue_as :default

  def perform(user_id)
    # user_idごとに直列化されて実行されます
    UserImportService.call(user_id)
  end
end

```

## 実行方法

```bash

# テストの実行

bundle exec rspec 34_background_job_design/background_job_design_spec.rb

# 個別のメソッドを試す

ruby -r ./34_background_job_design/background_job_design -e "pp BackgroundJobDesign.demonstrate_idempotency"
ruby -r ./34_background_job_design/background_job_design -e "pp BackgroundJobDesign.demonstrate_retry_strategies"
ruby -r ./34_background_job_design/background_job_design -e "pp BackgroundJobDesign.demonstrate_error_handling"

```
