# 21: Solid Cable - Rails 8のデータベースベースAction Cableバックエンド

## 概要

Solid CableはRails 8で導入されたAction
Cableのデフォルトバックエンドです。従来のRedisアダプターに代わり、リレーショナルデータベース（SQLite、PostgreSQL等）をメッセージブローカーとして使用します。Redisという外部依存を排除することで、Railsアプリケーションの運用をシンプルにするという設計思想に基づいています。

## Solid Cableの仕組み

### アーキテクチャ

Solid Cableのアーキテクチャは「データベースベースのPub/Sub」です。

```sql

[クライアント] ─WebSocket─→ [Action Cable Server]
                                    │
                            broadcast(channel, data)
                                    │
                                    ▼
                        INSERT INTO cable_messages
                       (channel, payload, created_at)
                                    │
                                    ▼
                            [Database Table]
                                    │
                            SELECT (polling)
                                    │
                                    ▼
                        [Action Cable Server]
                                    │
                            WebSocket push
                                    │
                                    ▼
                            [クライアント]

```

### メッセージの流れ

1. Publish（発行）:
   `ActionCable.server.broadcast`が呼ばれると、`SolidCable::Message`レコードがデータベースにINSERTされます
2. Store（格納）: メッセージは`solid_cable_messages`テーブルに一時的に保存されます
3. Poll（取得）: 各サーバープロセスの`SolidCable::Listener`がポーリングで新しいメッセージをSELECTします
4. Deliver（配信）: 取得したメッセージが、該当チャンネルを購読しているWebSocket接続に配信されます
5. Trim（削除）: `SolidCable::TrimJob`が古いメッセージを定期的にDELETEします

### ポーリングメカニズム

Solid
Cableの核心はポーリングベースの配信モデルです。RedisのSUBSCRIBE/PUBLISHのようなリアルタイムプッシュではなく、一定間隔でデータベースをクエリします。

```ruby

# SolidCable::Listenerの内部動作（簡略化）

loop do
  messages = SolidCable::Message
               .where("id > ?", last_seen_id)
               .order(:id)

  messages.each do |msg|
    deliver_to_subscribers(msg.channel, msg.payload)
    last_seen_id = msg.id
  end

  sleep polling_interval  # デフォルト: 0.1秒
end

```

ポーリング間隔のトレードオフを以下に示します。

| 間隔 | 最大遅延 | DB負荷 | 用途
| ------ | --------- | -------- | ------
| 10ms | 10ms | 高（100クエリ/秒） | 低遅延が必要な場合
| 100ms（デフォルト） | 100ms | 中（10クエリ/秒） | 一般的な用途
| 1000ms | 1秒 | 低（1クエリ/秒） | 通知程度の用途

### メッセージトリミング

Solid Cableはメッセージを永続的に保存しません。テーブルの肥大化を防ぐために、古いメッセージは自動的にトリミングされます。

```ruby

# SolidCable::TrimJobの内部動作（簡略化）

class TrimJob < ApplicationJob
  def perform
    SolidCable::Message
      .where("created_at < ?", message_retention.ago)
      .limit(trim_batch_size)
      .delete_all
  end
end

```

- message_retention: メッセージ保持期間です（デフォルト: 1日）
- trim_batch_size: 一度に削除するレコード数です
- autotrim: 自動トリミングの有効/無効を制御します（デフォルト: true）

## Redisアダプターとの比較

### 配信モデルの違い

```sql

【Solid Cable（ポーリング型）】
Publisher → INSERT → Database → SELECT（定期的） → Subscriber
                                  ↑
                            polling_intervalごと

【Redis（プッシュ型）】
Publisher → PUBLISH → Redis → SUBSCRIBE（即時通知） → Subscriber
                              ↑
                         常時接続・リアルタイム

```

### 詳細比較

| 観点 | Solid Cable | Redisアダプター
| ------ | ------------- | -----------------
| 配信方式 | ポーリング（SELECT） | プッシュ（SUBSCRIBE/PUBLISH）
| 遅延 | polling_intervalに依存（100ms〜） | サブミリ秒
| スループット | 中程度（DB I/Oに依存） | 高い（メモリ内操作）
| 追加インフラ | 不要（既存DBを利用） | Redisサーバーが必要です
| メッセージ永続性 | あり（DB保存） | なし（揮発性）
| サーバー再起動時 | メッセージが保持されます | メッセージが失われる可能性があります
| 運用コスト | 低い | Redisの運用・監視が必要です
| 同時接続数 | 数百接続程度に適します | 数千〜数万接続に対応します
| メモリ使用量 | DB側で管理します | Redisメモリに依存します

### 選定基準

Solid Cableが適するケースは以下の通りです。

- 小〜中規模のWebSocket通信（ライブ通知、ダッシュボード更新など）
- インフラをシンプルに保ちたい場合
- 100ms程度の遅延が許容できる場合
- SQLiteで十分な規模のアプリケーション

Redisアダプターが適するケースは以下の通りです。

- 大規模なリアルタイムチャットシステム
- ミリ秒単位の低遅延が必要な場合
- 数千以上の同時WebSocket接続がある場合
- 高頻度なメッセージ配信（1秒に数百回以上のbroadcast）

## WebSocket接続管理

### Action Cableとの統合

Solid CableはAction Cableのアダプターインターフェースを実装しており、アプリケーションコードを変更する必要はありません。

```ruby

# app/channels/chat_channel.rb（変更不要）

class ChatChannel < ApplicationCable::Channel
  def subscribed
    stream_from "chat_room_#{params[:room_id]}"
  end

  def receive(data)
    ActionCable.server.broadcast(
      "chat_room_#{params[:room_id]}",
      data
    )
  end
end

```

### マルチサーバー環境

Solid Cableはデータベースを共有メッセージストアとして使用するため、マルチサーバー環境でも自然に動作します。

```text

[Server A] ──broadcast──→ [Database] ←──polling── [Server A]
[Server B] ──broadcast──→ [Database] ←──polling── [Server B]
[Server C] ──broadcast──→ [Database] ←──polling── [Server C]

```

各サーバーが同じデータベーステーブルにINSERT/SELECTするため、サーバー間のメッセージ同期が自動的に行われます。

### コネクション管理の注意点

```ruby

# ポーリングによるDBコネクション消費に注意してください

# 各Action Cable workerがポーリング用のDB接続を保持します

# database.ymlで十分なpoolサイズを設定してください

cable:
  adapter: postgresql
  database: myapp_cable
  pool: 20  # Action Cable worker数 + マージン

```

## 本番設定

### 基本設定（config/cable.yml）

```yaml

# config/cable.yml

development:
  adapter: solid_cable
  polling_interval: 0.1.seconds
  message_retention: 1.day

test:
  adapter: test

production:
  adapter: solid_cable
  polling_interval: 0.1.seconds
  message_retention: 1.day
  connects_to:
    database:
      writing: cable
      reading: cable
  silence_polling: true

```

### 専用データベース（config/database.yml）

本番環境ではメインDBとは別にSolid Cable専用のデータベースを設定することが推奨されます。

```yaml

# config/database.yml

production:
  primary:
    adapter: postgresql
    database: myapp_production
    pool: 25

  cable:
    adapter: postgresql
    database: myapp_cable_production
    pool: 20
    migrations_paths: db/cable_migrate

```

専用DBを使う理由は以下の通りです。

1. ポーリングクエリがメインDBに負荷をかけません
2. cable_messagesテーブルの高頻度INSERT/DELETEがメインDBのWAL（Write-Ahead Log）に影響しません
3. バックアップ・メンテナンスを独立して行えます
4. メインDBのマイグレーションに影響しません

### インストールと初期設定

```bash

# Solid Cableのインストール

bin/rails solid_cable:install

# マイグレーションの実行

bin/rails db:migrate

# 専用DBを使う場合

bin/rails db:migrate:cable

```

### 監視すべきメトリクス

本番運用時に監視すべき項目を以下に示します。

| メトリクス | 目安 | 対処
| ----------- | ------ | ------
| cable_messagesテーブルの行数 | 数千行以下 | trimming設定の見直し
| ポーリングクエリの実行時間 | 10ms以下 | インデックスの確認
| DB接続プール使用率 | 80%以下 | poolサイズの拡大
| メッセージ配信遅延 | polling_interval以下 | polling_intervalの調整

### SQLite（開発環境）での注意

開発環境でSQLiteを使用する場合の注意点を以下に示します。

```ruby

# SQLiteのWALモードを有効にします（同時読み書きの性能向上）

# config/initializers/solid_cable.rb

if Rails.env.development?
  ActiveRecord::Base.connection.execute("PRAGMA journal_mode=WAL")
end

```

### Solid Queue・Solid Cacheとの併用

Rails 8ではSolid Cable、Solid Queue、Solid Cacheの「Solid三兄弟」をすべてデータベースベースで運用できます。

```yaml

# config/database.yml（3つの専用DBを設定）

production:
  primary:
    <<: *default
    database: myapp_production
  queue:
    <<: *default
    database: myapp_queue_production
    migrations_paths: db/queue_migrate
  cache:
    <<: *default
    database: myapp_cache_production
    migrations_paths: db/cache_migrate
  cable:
    <<: *default
    database: myapp_cable_production
    migrations_paths: db/cable_migrate

```

これにより、Redis・Memcachedなどの外部依存を完全に排除したRailsアプリケーションの構築が可能になります。

## 実行方法

```bash

# テストの実行

bundle exec rspec 21_solid_cable/solid_cable_spec.rb

# 個別のメソッドを試す

ruby -r ./21_solid_cable/solid_cable -e "pp SolidCableInternals.demonstrate_architecture"
ruby -r ./21_solid_cable/solid_cable -e "pp SolidCableInternals.demonstrate_polling_mechanism"

```

## 参考資料

- [Solid Cable GitHub](https://github.com/rails/solid_cable)
- [Rails 8 リリースノート](https://rubyonrails.org/2024/11/7/rails-8-no-paas-required)
- [Action Cable Overview (Rails
  Guides)](https://guides.rubyonrails.org/action_cable_overview.html)
- [DHH - Rails 8: No PaaS
  Required](https://world.hey.com/dhh/rails-8-no-paas-required-f82f3e0b)
