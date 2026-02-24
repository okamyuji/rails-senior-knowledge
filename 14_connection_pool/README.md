# 14. コネクションプールの内部構造

## 概要

ActiveRecordのコネクションプールは、データベース接続という高コストなリソースを効率的に管理するための仕組みです。Railsアプリケーションでは、
各リクエストがDBアクセスを必要とするため、接続の生成・破棄を毎回行うのではなく、プールで再利用することでパフォーマンスを大幅に向上させます。

このトピックでは、`ActiveRecord::ConnectionAdapters::ConnectionPool`
の内部動作、スレッドとの関係、設定のベストプラクティス、そしてトラブルシューティング手法を学びます。

## コネクションプールの仕組み

### 基本アーキテクチャ

```json

┌─────────────────────────────────────────┐
│           ConnectionPool                 │
│                                         │
│  ┌──────────┐  ┌──────────┐             │
│  │ Mutex    │  │CondVar   │  同期制御    │
│  └──────────┘  └──────────┘             │
│                                         │
│  ┌─────────────────────────────┐        │
│  │  @connections (全接続配列)    │        │
│  │  [conn1, conn2, ..., connN] │        │
│  └─────────────────────────────┘        │
│                                         │
│  ┌─────────────────────────────┐        │
│  │  @available (利用可能キュー)   │        │
│  │  ConnectionLeasingQueue      │        │
│  └─────────────────────────────┘        │
│                                         │
│  ┌─────────────────────────────┐        │
│  │  @thread_cached_conns        │        │
│  │  { thread_id => connection } │        │
│  └─────────────────────────────┘        │
│                                         │
│  pool_size: 5                           │
│  checkout_timeout: 5s                   │
└─────────────────────────────────────────┘

```

### チェックアウト（接続取得）の流れ

1. 現在のスレッドに既にバインドされた接続があればそれを返します
2. `@available` キューから利用可能な接続を取得します
3. プールサイズに余裕があれば新規接続を作成します
4. 余裕がなければ `checkout_timeout` まで `ConditionVariable` で待機します
5. タイムアウトした場合は `ActiveRecord::ConnectionTimeoutError` を発生させます

```ruby

# 内部の疑似コード

def checkout
  mutex.synchronize do
    loop do
      return thread_cached_conn if thread_cached_conn
      return available.pop      if available.any?
      return new_connection     if can_create_new?
      cond.wait(mutex, remaining_timeout)
      raise ConnectionTimeoutError if timed_out?
    end
  end
end

```

### チェックイン（接続返却）の流れ

```ruby

def checkin(conn)
  mutex.synchronize do
    remove_thread_binding(conn)
    available.push(conn)
    cond.signal  # 待機中のスレッドに通知します
  end
end

```

## DB接続枯渇問題の診断

### 症状

- `ActiveRecord::ConnectionTimeoutError` が発生します
- リクエストのレスポンスが突然遅くなります
- アプリケーションログに「could not obtain a connection from the pool within 5.000
  seconds」と表示されます

### 診断手法

#### 1. プール統計の確認

```ruby

# Railsコンソールでリアルタイムに確認します

pool = ActiveRecord::Base.connection_pool
puts pool.stat

# => { size: 5, connections: 5, busy: 5, idle: 0, waiting: 3, checkout_timeout: 5 }

```

#### 2. 接続リークの検出

```ruby

# 各接続の所有スレッドを確認します

pool = ActiveRecord::Base.connection_pool
pool.connections.each do |conn|
  owner = conn.owner
  if owner && !owner.alive?
    puts "リーク検出: 死んだスレッドが接続を保持しています (thread: #{owner})"
  end
end

```

#### 3. 一般的な原因

| 原因 | 説明 | 対処法
| ------ | ------ | --------
| プールサイズ不足 | スレッド数がpool値を超えています | pool値をスレッド数以上に設定します
| 接続リーク | with_connectionを使わずに接続を取得しています | with_connectionパターンを徹底します
| 長時間トランザクション | 大量データ処理でロックを保持しています | バッチ処理をfind_in_batchesで分割します
| N+1クエリ | 大量のクエリが接続を長時間占有しています | includes/preloadで解決します
| 外部API呼び出し中のロック | トランザクション内で外部APIを呼び出しています | トランザクション外に移動します

#### 4. モニタリング

```ruby

# config/initializers/connection_pool_monitor.rb

ActiveSupport::Notifications.subscribe("!connection.active_record") do |_name, _start, _finish, _id, payload|
  pool = ActiveRecord::Base.connection_pool
  stat = pool.stat
  if stat[:waiting] > 0
    Rails.logger.warn "[ConnectionPool] 接続待ちスレッド数: #{stat[:waiting]}, " \
                      "busy: #{stat[:busy]}/#{stat[:size]}"
  end
end

```

## マルチスレッド環境での設定

### スレッドと接続の関係

ActiveRecordは接続をスレッドにバインドします。同じスレッドから `connection`
を呼び出すと常に同じ接続が返されます。これによりトランザクションの整合性が保証されます。

```ruby

# 同一スレッドでは同じ接続が返されます

conn1 = ActiveRecord::Base.connection
conn2 = ActiveRecord::Base.connection
conn1.equal?(conn2)  # => true

# 異なるスレッドでは異なる接続が返されます

Thread.new { ActiveRecord::Base.connection.object_id }  # => 別のID

```

### バックグラウンドスレッドでの注意点

```ruby

# 悪い例: 接続がリークする可能性があります

Thread.new do
  ActiveRecord::Base.connection  # スレッドに接続がバインドされたまま
  # ... 処理 ...
end  # スレッド終了後、接続がリーパーに回収されるまで保持されます

# 良い例: with_connection で確実に返却します

Thread.new do
  ActiveRecord::Base.connection_pool.with_connection do |conn|
    # ... 処理 ...
  end  # ブロック終了で確実に返却されます
end

```

### リーパースレッド

リーパーは定期的にプール内の接続を検査するバックグラウンドスレッドです。

- reap: 所有スレッドが死んでいる接続をプールに返却します
- flush: `idle_timeout` を超えたアイドル接続を切断します

```yaml

# database.yml

production:
  adapter: postgresql
  pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
  reaping_frequency: 10    # 10秒ごとにリーパーを実行します（デフォルトは60秒）
  idle_timeout: 300        # 5分でアイドル接続を切断します（デフォルトは300秒）

```

## Pumaとの連携設定

### 基本原則

Pumaのスレッド数はDBプールサイズ以下でなければなりません。

```text

Pumaワーカー1つあたり:
  max_threads本のスレッドが同時にリクエストを処理します
  → 各スレッドが1つのDB接続を必要とします
  → pool >= max_threads が必須です

```

### Puma設定とdatabase.yml

```ruby

# config/puma.rb

workers ENV.fetch("WEB_CONCURRENCY") { 2 }
threads_count = ENV.fetch("RAILS_MAX_THREADS") { 5 }
threads threads_count, threads_count

preload_app!

on_worker_boot do
  # フォーク後に接続プールを再確立します
  ActiveRecord::Base.establish_connection
end

```

```yaml

# config/database.yml

production:
  adapter: postgresql
  encoding: unicode
  pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
  checkout_timeout: 5
  host: <%= ENV["DATABASE_HOST"] %>
  database: <%= ENV["DATABASE_NAME"] %>

```

### PostgreSQLの接続上限

```text

PostgreSQLのmax_connections（デフォルト100）に注意が必要です。
  Pumaワーカー数 × pool値 <= max_connections

例:
  workers: 4, pool: 5 → 4 × 5 = 20接続

  + Sidekiq(concurrency: 25) → 25接続

  合計: 45接続 < 100 (問題ありません)

```

### PgBouncerの活用

接続数が多い場合はPgBouncerを使ってコネクションプーリングを行います。

```text

アプリケーション (多数のプロセス)
    ↓
PgBouncer (接続を集約します)
    ↓
PostgreSQL (少数の実接続)

```

```yaml

# PgBouncer経由の場合のdatabase.yml

production:
  adapter: postgresql
  host: localhost
  port: 6432          # PgBouncerのポート
  pool: 5
  prepared_statements: false  # transactionモードでは無効にします

```

### Sidekiqとの連携

```ruby

# config/initializers/sidekiq.rb

Sidekiq.configure_server do |config|
  # Sidekiqのconcurrency以上のpool値が必要です
  # database.ymlのpool値がSidekiqのconcurrencyに合うよう設定します
  #
  # sidekiq.yml の concurrency: 25 なら
  # database.yml の pool: 25 以上にします
end

```

## 設定チェックリスト

- [ ] `pool` 値が `RAILS_MAX_THREADS` 以上であること
- [ ] Pumaの `workers × pool` がDBの `max_connections` 以下であること
- [ ] Sidekiqプロセスも含めた総接続数を計算していること
- [ ] バックグラウンドスレッドで `with_connection` を使用していること
- [ ] 長時間トランザクションを避けていること
- [ ] PgBouncer使用時に `prepared_statements: false` を設定していること
- [ ] `checkout_timeout` をモニタリングしていること
- [ ] `reaping_frequency` を適切に設定していること

## 参考情報

-
  [ActiveRecord::ConnectionAdapters::ConnectionPool](https://api.rubyonrails.org/classes/ActiveRecord/ConnectionAdapters/ConnectionPool.html)
- [Rails Guides - Configuring a
  Database](https://guides.rubyonrails.org/configuring.html#configuring-a-database)
- [Puma Configuration](https://puma.io/puma/Puma/DSL.html)
- [PgBouncer Documentation](https://www.pgbouncer.org/)
