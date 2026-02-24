# Solid Queueの内部構造

## Solid Queueの理解が重要な理由

Solid QueueはRails
8で採用されたデフォルトのジョブキューバックエンドです。従来のRedisベースのSidekiqに代わり、データベースのみでジョブキューイングを実現します。シニアエンジニアがこの仕組みを理解すべき理由は以下の通りです。

- Rails 8の標準として採用されています。新規Rails 8プロジェクトではデフォルトでSolid Queueが設定されます
- インフラの簡素化につながります。Redisサーバーの管理が不要になり、運用コストが下がります
- DBの知識の活用に役立ちます。FOR UPDATE SKIP LOCKEDなど、DBのロック機構の理解が深まります
- 障害対応が容易になります。ジョブの状態がすべてDBに保存されるため、SQLで直接調査・復旧できます
- 設計判断に役立ちます。Solid QueueとSidekiqの選択基準を理解し、適切な技術選定ができます

## アーキテクチャ概要

### データベーステーブルによるジョブキューイング

Solid Queueは以下の主要テーブルでジョブを管理します。

```text

solid_queue_jobs                 ← すべてのジョブのマスターレコード
solid_queue_ready_executions     ← 即時実行可能なジョブ（ポーリング対象）
solid_queue_claimed_executions   ← ワーカーが取得済みのジョブ
solid_queue_failed_executions    ← 実行に失敗したジョブ
solid_queue_scheduled_executions ← 将来実行予定のジョブ
solid_queue_recurring_executions ← 定期実行ジョブの管理
solid_queue_processes            ← アクティブなワーカープロセス
solid_queue_semaphores           ← 同時実行制御用セマフォ

```

### ジョブライフサイクル

ジョブは以下の状態遷移を辿ります。

```text

[Enqueue]
    │
    ├─ scheduled_at が未来
    │    → scheduled_executions に登録
    │         │
    │    時間到来 → ready_executions に移動します（Dispatcherが実行します）
    │
    └─ 即時実行
         → ready_executions に登録
              │
        ワーカーがclaim → claimed_executions に移動します
              │             （ready_executions から削除します）
              │
        ジョブ実行
              │
         ├─ 成功 → jobs.finished_at を設定します
         │         claimed_executions を削除します
         │
         └─ 失敗 → failed_executions に登録します
                   claimed_executions を削除します

```

### プロセスの種類

Solid Queueは以下のプロセスで構成されます。

| プロセス | 役割
| --------- | ------
| Worker | ready_executionsからジョブを取得・実行します
| Dispatcher | scheduled_executionsを監視し、時間到来したジョブをready_executionsに移動します
| Supervisor | WorkerとDispatcherを管理し、クラッシュ時に再起動します

## FOR UPDATE SKIP LOCKEDの解説

### 問題 - 複数ワーカーの競合

複数のワーカーが同時にジョブを取得しようとすると、同じジョブを複数回実行してしまう危険があります（二重実行問題）。

```sql

-- ワーカーA と ワーカーB が同時にこのクエリを実行すると...
SELECT * FROM solid_queue_ready_executions
WHERE queue_name = 'default'
ORDER BY priority ASC, created_at ASC
LIMIT 1;
-- → 同じレコードが返されてしまう可能性があります

```

### 解決策 - FOR UPDATE SKIP LOCKED

PostgreSQLとMySQLが提供する行ロック機構を使って解決します。

```sql

SELECT * FROM solid_queue_ready_executions
WHERE queue_name = 'default'
ORDER BY priority ASC, created_at ASC
LIMIT 1
FOR UPDATE SKIP LOCKED;

```

- FOR UPDATE: 選択した行に排他ロック（行ロック）をかけます
- SKIP LOCKED: 既に他のトランザクションがロックしている行をスキップします

これにより以下のように動作します。

1. ワーカーAがジョブ1にロックをかけます
2. ワーカーBは同時にクエリを実行しますが、ジョブ1はロック済みなのでスキップします
3. ワーカーBはジョブ2を取得します
4. 結果として、各ジョブは1つのワーカーだけが取得します

### SQLiteでの代替方式

SQLiteはFOR UPDATE SKIP LOCKEDをサポートしないため、
Solid QueueはSQLite使用時にトランザクション内での
DELETE + INSERTアプローチを使用します。

```ruby

ActiveRecord::Base.transaction do
  # トランザクション内でready_executionを選択・削除します
  ready = ReadyExecution
    .where(queue_name: "default")
    .order(priority: :asc, created_at: :asc)
    .limit(1)

  ready.each do |execution|
    ClaimedExecution.create!(job: execution.job, process_id: current_process_id)
    execution.destroy!
  end
end

```

SQLiteのトランザクション分離レベル（SERIALIZABLE）により、同時アクセスの安全性が保証されます。ただし、高スループット環境では本番環境にPostgreSQLを使用すべきです。

## 同時実行制御

### セマフォによる制限

特定のキーに対して同時実行数を制限できます。例えば、同じユーザーへの課金処理を同時に1つだけに制限する場合は以下のようにします。

```ruby

class BillingJob < ApplicationJob
  limits_concurrency to: 1, key: ->(user_id) { "billing_user_#{user_id}" }

  def perform(user_id)
    PaymentGateway.charge(user_id)
  end
end

```

内部的には `solid_queue_semaphores` テーブルの `value` カラムをデクリメント/インクリメントすることで制御しています。

### 定期実行タスク（Recurring Tasks）

cron的な定期実行ジョブもサポートされています。

```yaml

# config/recurring.yml

production:
  cleanup_old_records:
    class: CleanupJob
    schedule: every day at 3am
    queue: maintenance

  sync_external_data:
    class: SyncJob
    schedule: every 30 minutes
    queue: default

```

## Sidekiqとの比較

### 性能特性

| 観点 | Solid Queue | Sidekiq
| ------ | ------------- | ---------
| バックエンド | データベースです | Redisです
| スループット | 中程度です（DB I/O依存） | 高いです（インメモリ操作）
| レイテンシ | ポーリング間隔に依存します（0.1〜1秒） | ほぼリアルタイムです（BRPOPLPUSH）
| ジョブ取得方式 | FOR UPDATE SKIP LOCKEDを使用します | BRPOPLPUSH（Redisネイティブ）を使用します
| 永続性 | デフォルトで永続です（DBに保存されます） | Redis設定に依存します
| モニタリング | Mission Controlを使用します | Sidekiq Web UIを使用します
| ライセンス | MITです | OSSです（Pro/Enterpriseは有料です）

### 使い分けの指針

Solid Queueが適切な場合は以下の通りです。

- 中小規模のアプリケーション（数千ジョブ/時間程度）
- インフラの簡素化を重視する場合
- Redisの運用コストを削減したい場合
- Rails 8の新規プロジェクト
- ジョブデータのSQL分析が必要な場合

Sidekiqが適切な場合は以下の通りです。

- 大規模アプリケーション（数百万ジョブ/日）
- 低レイテンシが求められる場合
- Sidekiq Pro/Enterpriseの機能（バッチ、レート制限等）が必要な場合
- 既存のSidekiqエコシステムへの投資がある場合

## 本番運用設定

### 基本設定（config/solid_queue.yml）

```yaml

production:
  dispatchers:

    - polling_interval: 1      # スケジュール済みジョブの確認間隔（秒）

      batch_size: 500          # 一度に移動するジョブ数

  workers:

    - queues: ["default"]

      threads: 5               # 並行実行スレッド数
      processes: 2             # 起動するプロセス数
      polling_interval: 0.1    # ジョブ取得のポーリング間隔（秒）

    - queues: ["mailers"]

      threads: 2
      processes: 1
      polling_interval: 0.5

    - queues: ["critical"]

      threads: 3
      processes: 2
      polling_interval: 0.1

```

### キュー優先度の設定

```ruby

# app/jobs/application_job.rb

class ApplicationJob < ActiveJob::Base
  # デフォルトキューと優先度
  queue_as :default
end

# 高優先度ジョブ

class PaymentJob < ApplicationJob
  queue_as :critical
  queue_with_priority 0   # 0が最高優先度です
end

# 低優先度ジョブ

class ReportJob < ApplicationJob
  queue_as :default
  queue_with_priority 20  # 値が大きいほど低優先度です
end

```

### データベース設定

本番環境ではSolid Queue専用のデータベース接続を推奨します。

```yaml

# config/database.yml

production:
  primary:
    <<: *default
    database: myapp_production

  queue:
    <<: *default
    database: myapp_queue_production
    migrations_paths: db/queue_migrate

```

```ruby

# config/application.rb

config.solid_queue.connects_to = { database: { writing: :queue } }

```

### 監視とメンテナンス

```ruby

# Mission Control（Solid QueueのWeb UI）をマウントします

# config/routes.rb

mount MissionControl::Jobs::Engine, at: "/jobs"

# 失敗ジョブの確認（Railsコンソール）

SolidQueue::FailedExecution.count
SolidQueue::FailedExecution.last(10).each do |fe|
  puts "#{fe.job.class_name}: #{fe.error_message}"
end

# 失敗ジョブのリトライ

SolidQueue::FailedExecution.find(id).retry

# 古い完了済みジョブのクリーンアップ

SolidQueue::Job.where("finished_at < ?", 7.days.ago).destroy_all

```

### Pumaとの統合

Rails 8ではPumaの設定でSolid Queueを同一プロセスで起動できます。

```ruby

# config/puma.rb

plugin :solid_queue if ENV.fetch("SOLID_QUEUE_IN_PUMA", false)

```

これにより、別途ワーカープロセスを起動する必要がなくなり、小規模なデプロイが簡素化されます。ただし、大規模な環境ではワーカーを別プロセスとして起動することを推奨します。

## 実行方法

```bash

# テストの実行

bundle exec rspec 19_solid_queue/solid_queue_spec.rb

# 個別のメソッドを試します

ruby -r ./19_solid_queue/solid_queue -e "pp SolidQueueInternals.demonstrate_enqueue"
ruby -r ./19_solid_queue/solid_queue -e "pp SolidQueueInternals.demonstrate_job_lifecycle"
ruby -r ./19_solid_queue/solid_queue -e "pp SolidQueueInternals.demonstrate_comparison_with_sidekiq"

```
