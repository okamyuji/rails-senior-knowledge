# Solid Cache - Rails 8のデフォルトキャッシュバックエンド

## Solid Cacheの概要

Solid CacheはRails
8で導入されたデフォルトのキャッシュバックエンドです。従来のRedisやMemcachedの代わりに、RDBMSをキャッシュストアとして使用します。37signalsのHEYやBasecampでの実運用経験を基に設計されており、「ディスクはRAMより安い」という現実的な判断に基づいています。

### 主な特徴

- データベースバックドで、PostgreSQL、MySQL、SQLiteに対応しています
- FIFOエビクションにより、最も古いエントリから順に追い出します
- 水平シャーディングで、複数DBにキャッシュを分散できます
- ゼロ追加インフラで、既存のDBインフラをそのまま活用できます
- 大容量対応で、ディスクベースのためTB級のキャッシュも実現できます

## Solid Cacheの仕組み

### アーキテクチャ概要

```text

┌──────────────────┐
│   Rails App      │
│                  │
│  cache.read(key) │
│  cache.write(k,v)│
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│  SolidCache::    │
│  Store           │
│                  │
│  - キー正規化     │  キーをSHA256でハッシュ化します
│  - シリアライズ   │  MarshalまたはJSONを使用します
│  - シャード選定   │  キーハッシュでシャードを決定します
└────────┬─────────┘
         │
    ┌────┴────┐
    ▼         ▼
┌────────┐ ┌────────┐
│ Shard1 │ │ Shard2 │  ... 複数シャード対応
│ (DB)   │ │ (DB)   │
└────────┘ └────────┘

```

### テーブル構造

Solid Cacheは `solid_cache_entries` テーブルを使用します。

```sql

CREATE TABLE solid_cache_entries (
  id         BIGINT PRIMARY KEY AUTO_INCREMENT,
  key        VARCHAR(1024) NOT NULL,     -- SHA256ハッシュ化されたキー
  value      BLOB NOT NULL,              -- シリアライズされた値（最大512MB）
  byte_size  INTEGER NOT NULL,           -- エントリ全体のバイトサイズ
  created_at DATETIME NOT NULL,          -- 作成日時（FIFOの基準）

  UNIQUE INDEX (key),
  INDEX (key, byte_size),
  INDEX (byte_size)
);

```

重要な設計上の特徴は以下の通りです。

- `updated_at` カラムが存在しません。FIFOではアクセス時のタイムスタンプ更新が不要なためです
- `key` はハッシュ化されています。任意長のキーを固定長（48バイト）に正規化してインデックス効率を向上させています
- `byte_size` を記録しています。エビクション判断を高速に行うためのメタデータです

### キャッシュエントリのライフサイクル

```text

書き込み (write)
  │
  ├─ キー正規化 (SHA256)
  ├─ 値シリアライズ (Marshal.dump)
  ├─ UPSERT実行
  └─ エビクション判定
       │
       ├─ サイズ超過なし → 完了
       └─ サイズ超過あり → FIFO削除実行
                           (created_at ASC順にバッチ削除)

読み取り (read)
  │
  ├─ キー正規化 (SHA256)
  ├─ SELECT実行
  ├─ TTL期限切れチェック
  │   ├─ 期限内 → デシリアライズして返します
  │   └─ 期限切れ → 遅延削除し、nilを返します
  └─ ヒットしない → nilを返します

```

## FIFOとLRUの比較

### LRU（Least Recently Used）

最後にアクセスされた時刻が最も古いエントリを追い出す戦略です。

メリットは以下の通りです。

- 頻繁にアクセスされる「ホットキー」は長期間保持されます
- キャッシュヒット率が理論上高くなります

デメリットは以下の通りです。

- 読み取りのたびに `updated_at` の更新（WRITE操作）が必要です
- RDBMSでは毎回UPDATEが発生し、読み取り性能が大幅に低下します
- インデックスの書き換えによるI/Oが増大します
- 行ロックの競合が発生しやすくなります

### FIFO（First-In, First-Out）

最初に書き込まれた時刻が最も古いエントリを追い出す戦略です。

メリットは以下の通りです。

- 読み取りがSELECTのみで完結します（書き込みI/Oがありません）
- 読み取り性能が安定し予測可能です
- 実装がシンプルでバグが少なくなります
- created_atのみで順序が決まるため、インデックス設計が容易です

デメリットは以下の通りです。

- ホットキーでも古くなれば追い出されます
- 理論上のキャッシュヒット率はLRUに劣ります

### Solid CacheがFIFOを選択した理由

```sql

RDBMS上でのパフォーマンス比較（概念図）

       LRU (Redis)     FIFO (Solid Cache)    LRU (RDBMS)
READ:  O(1) メモリ      O(1) インデックス     O(1) + UPDATE
WRITE: O(1) メモリ      O(1) INSERT          O(1) INSERT

       ★★★★★          ★★★★               ★★ ← UPDATEがボトルネック

```

Solid Cacheの設計哲学は以下の通りです。

1. ディスクはRAMより安いです。十分なキャッシュサイズを確保すれば、FIFOでも高いヒット率を達成できます
2. 読み取りの最適化を優先します。キャッシュの読み取り/書き込み比率は通常10:1以上です。読み取り性能を優先します
3. 運用の簡素化を実現します。LRUの複雑さ（ロック競合、インデックスメンテナンス）を排除しています

### ヒット率の実測値（37signals公開データ）

37signalsの実運用では、十分なキャッシュサイズ（ホットデータの数倍）を確保することで、FIFOでもLRUと遜色ないヒット率を達成しています。キャッシュサイズが十分に大きい場合、エビクション戦略による差は小さくなります。

## Redis/Memcachedとの使い分け

### 特性比較

| 項目 | Solid Cache | Redis | Memcached
| ------ | ------------- | ------- | -----------
| ストレージ | ディスク（RDBMS）です | メモリ（+ディスク永続化）です | メモリのみです
| エビクション | FIFOです | LRU / LFU / TTLです | LRUです
| 最大容量 | TB級です（ディスク依存） | 数十GBです（RAM依存） | 数十GBです（RAM依存）
| 読み取り遅延 | 中程度です（1-5ms） | 低いです（0.1-1ms） | 最低です（0.1ms未満）
| 永続化 | デフォルトで永続です | 設定が必要です | ありません
| 運用コスト | 低いです | 中程度です | 中程度です
| 追加インフラ | 不要です | Redis専用サーバーが必要です | Memcached専用サーバーが必要です

### 選定フローチャート

```text

キャッシュバックエンドの選定

Q1: ミリ秒以下のレイテンシが必須ですか？
  ├─ Yes → Redis or Memcached
  │   Q2: Pub/Sub、Sorted Setなどが必要ですか？
  │     ├─ Yes → Redis
  │     └─ No  → Memcached
  └─ No
      Q3: キャッシュ容量が100GB以上必要ですか？
        ├─ Yes → Solid Cache（ディスクベースで大容量対応）
        └─ No
            Q4: 運用の簡素化が最優先ですか？
              ├─ Yes → Solid Cache（追加インフラ不要）
              └─ No  → Redis（高機能、エコシステムが豊富）

```

### Solid Cacheが適するケース

- Rails 8プロジェクトの新規立ち上げでは、デフォルト設定でそのまま使えます
- 大容量フラグメントキャッシュでは、HTMLフラグメントは容量が大きくなりやすいです
- インフラ簡素化では、Redis専用サーバーの管理コストを削減できます
- コスト最適化では、ディスクストレージはRAMの10分の1以下のコストです
- 既存DB活用では、PostgreSQL/MySQLを既に運用している場合に有利です

### Redisが適するケース

- リアルタイム性が重要な場合は、チャット、ライブフィード、ゲームなどに適しています
- 高度なデータ構造が必要な場合は、ランキング（Sorted Set）、Pub/Subに適しています
- Sidekiq/Resqueを使用している場合は、バックグラウンドジョブ基盤がRedisを前提としています
- セッションストアとしては、高頻度アクセスされるセッションデータに適しています

## 本番運用設定

### 基本設定

```ruby

# config/environments/production.rb

Rails.application.configure do
  config.cache_store = :solid_cache_store
end

```

### config/solid_cache.yml

```yaml

production:
  store_options:
    max_age: <%= 2.weeks.to_i %>   # エントリの最大生存時間
    max_size: <%= 256.megabytes %>  # キャッシュの最大サイズ
    namespace: myapp_prod           # 名前空間（マルチアプリ分離）

```

### シャード設定（大規模環境向け）

```yaml

# config/database.yml

production:
  primary:
    <<: *default
    database: myapp_production

  cache_shard1:
    <<: *default
    database: myapp_cache_shard1
    migrations_paths: db/cache_migrate

  cache_shard2:
    <<: *default
    database: myapp_cache_shard2
    migrations_paths: db/cache_migrate

```

```yaml

# config/solid_cache.yml

production:
  databases: [cache_shard1, cache_shard2]
  store_options:
    max_age: <%= 2.weeks.to_i %>
    max_size: <%= 1.gigabyte %>

```

### パフォーマンスチューニング

#### max_sizeの設定指針

```text

推奨値 = ホットデータサイズ × 3〜5倍

例:

- ホットデータ10GB → max_size: 30〜50GB
- FIFOのため、余裕を持たせるほどヒット率が向上します
- ディスクはRAMより安いので大きめに設定して問題ありません

```

#### max_ageの設定指針

```text

アプリケーションのデータ更新頻度に合わせます

- ECサイト（価格変動あり）: 1日〜3日
- ブログ/CMS（更新頻度低）: 2週間〜1ヶ月
- APIレスポンスキャッシュ: 1時間〜1日

```

#### 監視すべきメトリクス

```ruby

# キャッシュヒット率の監視（ActiveSupport::Notifications利用）

ActiveSupport::Notifications.subscribe("cache_read.active_support") do |*args|
  event = ActiveSupport::Notifications::Event.new(*args)
  hit = event.payload[:hit]
  StatsD.increment("cache.#{hit ? 'hit' : 'miss'}")
end

```

監視項目は以下の通りです。

| メトリクス | 目標値 | 対処
| ----------- | -------- | ------
| ヒット率 | 90%以上 | max_sizeを増加し、max_ageを延長します
| 平均読み取り時間 | 5ms以下 | インデックスの最適化、シャード追加を行います
| エビクション頻度 | 低頻度 | max_sizeを増加します
| ディスク使用量 | max_sizeの80%以下 | 正常運用の範囲です

### マイグレーション

Solid Cacheのテーブルを作成するマイグレーションは以下のように実行します。

```bash

# Rails 8ではデフォルトで含まれますが、手動追加する場合

bin/rails solid_cache:install:migrations
bin/rails db:migrate

```

### トラブルシューティング

#### キャッシュヒット率が低い場合

1. `max_size` が十分か確認します（ホットデータの3倍以上）
2. `max_age` が短すぎないか確認します
3. キャッシュキーの設計を見直します（バージョニング戦略）

#### 書き込みが遅い場合

1. シャードの追加を検討します
2. バッチ書き込みが有効か確認します
3. DBのWAL（Write-Ahead Log）設定を最適化します

#### ディスク使用量が急増する場合

1. エビクションが正常に動作しているか確認します
2. 巨大な値をキャッシュしていないか確認します
3. `max_size` の設定値が適切か見直します

## 実行方法

```bash

# テストの実行

bundle exec rspec 20_solid_cache/solid_cache_spec.rb

# 個別のデモンストレーションを試します

ruby -r ./20_solid_cache/solid_cache -e "pp SolidCacheInternals::Demonstration.run_basic_operations"
ruby -r ./20_solid_cache/solid_cache -e "pp SolidCacheInternals::Demonstration.run_fifo_eviction"
ruby -r ./20_solid_cache/solid_cache -e "pp SolidCacheInternals::Demonstration.run_buffered_write"
ruby -r ./20_solid_cache/solid_cache -e "pp SolidCacheInternals::Demonstration.run_sharding_demo"

```
