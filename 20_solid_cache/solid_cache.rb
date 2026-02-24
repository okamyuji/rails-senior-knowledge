# frozen_string_literal: true

# Solid Cacheの内部構造を解説するモジュール
#
# Solid CacheはRails 8のデフォルトキャッシュバックエンドである。
# Redisの代わりにRDBMS（SQLite/PostgreSQL/MySQL）をキャッシュストアとして使用し、
# FIFOエビクション戦略でキャッシュエントリを管理する。
#
# このモジュールでは、Solid Cacheの内部動作を簡易的に再現し、
# FIFOエビクション、TTL期限切れ、シャーディング、バッチ書き込みなどの
# 仕組みをシニアエンジニア向けに解説する。

require 'active_record'
require 'active_support'
require 'active_support/core_ext/numeric/time'
require 'digest'

module SolidCacheInternals
  # ==========================================================================
  # 1. データベースセットアップ: インメモリSQLiteでSolid Cacheのスキーマを再現
  # ==========================================================================
  module DatabaseSetup
    # Solid Cacheのテーブルスキーマをインメモリ SQLite に構築する
    # 実際のSolid Cacheは solid_cache_entries テーブルを使用する
    #
    # スキーマの要点:
    # - key: キャッシュキーのSHA256ハッシュ（固定長42バイト、Base64エンコード）
    # - value: シリアライズされたキャッシュ値（BLOB）
    # - byte_size: エントリ全体のバイトサイズ（key + value）
    # - created_at: 作成日時（FIFOエビクションの基準）
    #
    # 注意: Solid Cacheはupdated_atを持たない。これはLRUではなくFIFO戦略の
    # 設計上の選択であり、読み取り時にタイムスタンプを更新する必要がないため、
    # 読み取りパフォーマンスが向上する。
    def self.setup!
      unless ActiveRecord::Base.connected?
        ActiveRecord::Base.establish_connection(
          adapter: 'sqlite3',
          database: ':memory:'
        )
      end

      ActiveRecord::Schema.define do
        create_table :solid_cache_entries, force: true do |t|
          t.string  :key,        null: false, limit: 1024
          t.binary  :value,      null: false, limit: 536_870_912 # 512MB
          t.integer :byte_size,  null: false
          t.datetime :created_at, null: false

          t.index :key, unique: true
          t.index %i[key byte_size], name: 'index_solid_cache_entries_on_key_and_byte_size'
          t.index :byte_size, name: 'index_solid_cache_entries_on_byte_size'
        end
      end
    end
  end

  # ==========================================================================
  # 2. キャッシュエントリモデル: Solid Cacheのレコード構造を再現
  # ==========================================================================
  class CacheEntry < ActiveRecord::Base
    self.table_name = 'solid_cache_entries'

    # Solid CacheはキーをSHA256でハッシュ化して保存する
    # これにより固定長のキーが得られ、インデックス効率が向上する
    def self.normalize_key(key)
      "s3c-#{Digest::SHA256.base64digest(key)}"
    end
  end

  # ==========================================================================
  # 3. FIFOキャッシュストア: Solid Cacheの中核アーキテクチャを再現
  # ==========================================================================
  #
  # Solid CacheがFIFO（First-In, First-Out）を選択した理由:
  #
  # 【LRU（Least Recently Used）の問題点】
  # - 読み取り時にタイムスタンプを更新する必要がある（書き込みI/O発生）
  # - RDBMSでは毎回UPDATEが必要で、読み取り性能が低下する
  # - Redisはインメモリなので高速にLRUを実現できるが、DBでは不向き
  #
  # 【FIFOの利点】
  # - 読み取りがSELECTのみで完結する（書き込みI/Oなし）
  # - 十分な容量を確保すれば、アクセスパターンに関わらず安定した性能
  # - シンプルな実装でバグが少ない
  # - created_atのみでエビクション順序が決定する
  #
  # 【トレードオフ】
  # - ホットキー（頻繁にアクセスされるキー）も古くなれば追い出される
  # - 対策: キャッシュサイズを十分大きく設定する（ディスク容量はRAMより安価）
  class FifoCacheStore
    attr_reader :max_size, :max_age

    # @param max_size [Integer] キャッシュの最大バイトサイズ
    # @param max_age [Integer] エントリの最大生存時間（秒）。デフォルト2週間
    def initialize(max_size:, max_age: 14.days.to_i)
      @max_size = max_size
      @max_age = max_age
      @write_buffer = []
      @write_buffer_size = 0
      @write_buffer_max = 4096 # バッファサイズ上限（バイト）
    end

    # --- 読み取り操作 ---

    # キャッシュからエントリを読み取る
    # Solid CacheではSELECTのみで完結し、タイムスタンプの更新は行わない
    # これがFIFO戦略のパフォーマンス上の大きな利点
    def read(key)
      normalized = CacheEntry.normalize_key(key)
      entry = CacheEntry.find_by(key: normalized)
      return nil unless entry

      # TTL期限切れチェック
      if expired?(entry)
        # 期限切れエントリは遅延削除（lazy deletion）
        entry.destroy
        return nil
      end

      deserialize(entry.value)
    end

    # 複数キーの一括読み取り
    # Solid Cacheは read_multi でIN句による一括クエリを実行する
    def read_multi(*keys)
      normalized_map = keys.each_with_object({}) do |key, hash|
        hash[CacheEntry.normalize_key(key)] = key
      end

      entries = CacheEntry.where(key: normalized_map.keys)
      result = {}

      entries.each do |entry|
        original_key = normalized_map[entry.key]
        next if expired?(entry)

        result[original_key] = deserialize(entry.value)
      end

      result
    end

    # --- 書き込み操作 ---

    # キャッシュにエントリを書き込む
    #
    # Solid Cacheの書き込みパターン:
    # 1. UPSERT（INSERT ... ON CONFLICT UPDATE）でアトミックに書き込み
    # 2. 書き込み後にエビクションを非同期で実行
    # 3. バッチ書き込みで複数エントリをまとめて処理可能
    def write(key, value)
      normalized = CacheEntry.normalize_key(key)
      serialized = serialize(value)
      byte_size = normalized.bytesize + serialized.bytesize

      upsert_entry(normalized, serialized, byte_size)
      evict_if_needed
    end

    # 複数エントリの一括書き込み
    # Solid Cacheはwrite_multiでバッチINSERTを使用し、
    # 1回のSQLで複数エントリを書き込むことでI/Oを削減する
    def write_multi(entries)
      entries.each do |key, value|
        normalized = CacheEntry.normalize_key(key)
        serialized = serialize(value)
        byte_size = normalized.bytesize + serialized.bytesize
        upsert_entry(normalized, serialized, byte_size)
      end
      evict_if_needed
    end

    # --- 削除操作 ---

    def delete(key)
      normalized = CacheEntry.normalize_key(key)
      CacheEntry.where(key: normalized).delete_all
    end

    # --- 書き先行バッファ（Write-Ahead Buffer） ---
    #
    # Solid Cacheは書き込みをバッファリングし、一定量溜まったら
    # まとめてフラッシュする。これにより個別INSERTのオーバーヘッドを削減する。
    #
    # 実際のSolid CacheではActive Jobを使った非同期書き込みもサポートしている。
    def buffered_write(key, value)
      normalized = CacheEntry.normalize_key(key)
      serialized = serialize(value)
      byte_size = normalized.bytesize + serialized.bytesize

      @write_buffer << { key: normalized, value: serialized, byte_size: byte_size }
      @write_buffer_size += byte_size

      flush_buffer if @write_buffer_size >= @write_buffer_max
    end

    def flush_buffer
      return if @write_buffer.empty?

      @write_buffer.each do |entry|
        upsert_entry(entry[:key], entry[:value], entry[:byte_size])
      end
      @write_buffer.clear
      @write_buffer_size = 0
      evict_if_needed
    end

    # --- エビクション ---

    # FIFO エビクション: 最も古いエントリから順に削除する
    #
    # Solid Cacheのエビクション戦略:
    # 1. 合計バイトサイズが max_size を超えたらエビクション開始
    # 2. created_at が古い順にエントリを削除
    # 3. バッチ削除で効率的に処理（デフォルト100件ずつ）
    # 4. 合計サイズが max_size の 75% 以下になるまで削除を継続
    def evict_if_needed
      return unless over_size_limit?

      target_size = (max_size * 0.75).to_i

      while current_total_size > target_size
        # 最も古いエントリをバッチで削除（FIFO）
        oldest = CacheEntry.order(:created_at).limit(batch_eviction_size)
        break if oldest.empty?

        CacheEntry.where(id: oldest.map(&:id)).delete_all
      end
    end

    # TTL期限切れエントリの一括削除
    # Solid Cacheはバックグラウンドジョブでこれを定期実行する
    def expire_old_entries
      cutoff = Time.now - max_age
      CacheEntry.where('created_at < ?', cutoff).delete_all
    end

    # --- 統計情報 ---

    def stats
      {
        entry_count: CacheEntry.count,
        total_bytes: current_total_size,
        max_size: max_size,
        usage_percent: current_total_size.to_f / max_size * 100,
        oldest_entry: CacheEntry.order(:created_at).first&.created_at,
        newest_entry: CacheEntry.order(created_at: :desc).first&.created_at,
        buffer_entries: @write_buffer.size,
        buffer_bytes: @write_buffer_size
      }
    end

    private

    def upsert_entry(normalized_key, serialized_value, byte_size)
      existing = CacheEntry.find_by(key: normalized_key)
      if existing
        existing.update!(value: serialized_value, byte_size: byte_size, created_at: Time.now)
      else
        CacheEntry.create!(
          key: normalized_key,
          value: serialized_value,
          byte_size: byte_size,
          created_at: Time.now
        )
      end
    end

    def expired?(entry)
      entry.created_at < Time.now - max_age
    end

    def current_total_size
      CacheEntry.sum(:byte_size)
    end

    def over_size_limit?
      current_total_size > max_size
    end

    def batch_eviction_size
      10
    end

    def serialize(value)
      Marshal.dump(value)
    end

    def deserialize(data)
      Marshal.load(data) # rubocop:disable Security/MarshalLoad
    end
  end

  # ==========================================================================
  # 4. シャーディングシミュレーション: 水平スケーリング
  # ==========================================================================
  #
  # Solid Cacheは複数のデータベースシャードにキャッシュを分散できる。
  # これにより:
  # - 単一DBの容量制限を超えたキャッシュが可能
  # - 書き込み負荷を複数DBに分散
  # - シャードの追加/削除が容易
  #
  # シャード選定にはキーのハッシュ値を使ったコンシステントハッシングを使用する。
  module ShardingSimulator
    # シャード管理クラス
    # 実際のSolid Cacheはdatabase.ymlでシャード設定を行う
    class ShardRouter
      attr_reader :shard_count, :shard_data

      def initialize(shard_count:)
        @shard_count = shard_count
        # 各シャードを独立したハッシュで模擬
        @shard_data = Array.new(shard_count) { {} }
      end

      # キーからシャードインデックスを決定する
      # Solid CacheはMurmurHashなどを使うが、ここではCRC32で簡易化
      def shard_for(key)
        Digest::MD5.hexdigest(key).hex % shard_count
      end

      def write(key, value)
        shard_index = shard_for(key)
        @shard_data[shard_index][key] = value
        shard_index
      end

      def read(key)
        shard_index = shard_for(key)
        @shard_data[shard_index][key]
      end

      # 各シャードのエントリ数を返す（分散の均一性を確認）
      def distribution
        @shard_data.each_with_index.map do |data, index|
          { shard: index, entries: data.size }
        end
      end
    end

    # シャーディングの動作を示す
    def self.demonstrate_sharding
      router = ShardRouter.new(shard_count: 4)
      shard_assignments = {}

      # 100件のキーを書き込み、シャードへの分散を確認
      100.times do |i|
        key = "cache_key_#{i}"
        shard_index = router.write(key, "value_#{i}")
        shard_assignments[key] = shard_index
      end

      # 同じキーは常に同じシャードに振り分けられることを確認（2回呼んで一致するか）
      first_shard = router.shard_for('test_key')
      second_shard = router.shard_for('test_key')
      {
        distribution: router.distribution,
        consistent: first_shard == second_shard,
        sample_assignments: shard_assignments.first(5).to_h
      }
    end
  end

  # ==========================================================================
  # 5. Redis/Memcachedとの比較
  # ==========================================================================
  #
  # Solid Cache vs Redis vs Memcached の特性比較
  module ComparisonWithRedis
    def self.comparison_table
      {
        solid_cache: {
          storage: 'RDBMS（ディスクベース）',
          eviction: 'FIFO（First-In, First-Out）',
          max_capacity: 'ディスク容量に依存（TB級も可能）',
          hot_key_performance: 'FIFOのため頻繁アクセスでも追い出される可能性あり',
          persistence: 'デフォルトで永続化（DBに保存）',
          ops_complexity: '低い（既存DBインフラを活用）',
          cost: '低い（追加インフラ不要、ディスクはRAMより安価）',
          read_latency: '中程度（ディスクI/O + SQLパース）',
          write_latency: '中程度（バッチ書き込みで最適化）',
          use_case: '大容量キャッシュ、シンプルな運用、Rails 8デフォルト'
        },
        redis: {
          storage: 'インメモリ（オプションでディスク永続化）',
          eviction: 'LRU / LFU / TTL など選択可能',
          max_capacity: 'RAM容量に依存（通常数十GB）',
          hot_key_performance: 'LRUにより頻繁アクセスは保持される',
          persistence: 'RDB/AOFで永続化可能（設定が必要）',
          ops_complexity: '中程度（Redis専用サーバーの管理が必要）',
          cost: '中程度（RAM + 専用インフラ）',
          read_latency: '低い（インメモリ、ネットワーク越し）',
          write_latency: '低い（インメモリ）',
          use_case: '高スループット要件、セッション、リアルタイムデータ'
        },
        memcached: {
          storage: 'インメモリのみ',
          eviction: 'LRU',
          max_capacity: 'RAM容量に依存',
          hot_key_performance: 'LRUにより頻繁アクセスは保持される',
          persistence: 'なし（再起動でデータ消失）',
          ops_complexity: '中程度',
          cost: '中程度（RAM + 専用インフラ）',
          read_latency: '最低（シンプルなプロトコル）',
          write_latency: '最低',
          use_case: '単純なキー/バリューキャッシュ、セッション'
        }
      }
    end

    # 選定ガイドライン
    def self.selection_guide
      {
        choose_solid_cache: [
          'Rails 8を使用しており、追加インフラを避けたい',
          'キャッシュ容量が大きい（数百GB以上）',
          '運用の簡素化を優先する',
          'ホットキーのパフォーマンスが最重要ではない',
          '既にPostgreSQL/MySQLを運用している'
        ],
        choose_redis: [
          'ミリ秒単位のレイテンシが要件',
          'LRU/LFUによるスマートなエビクションが必要',
          'Pub/Sub、Sorted Setなどの高度なデータ構造が必要',
          'セッションストア、リアルタイムランキングなどの用途',
          'Sidekiqなど他のgemがRedisを必要としている'
        ],
        choose_memcached: %w[
          極めてシンプルなキャッシュのみ必要
          マルチスレッド対応が必要
          Redisの高度な機能が不要
        ]
      }
    end
  end

  # ==========================================================================
  # 6. 設定例: 本番環境での推奨構成
  # ==========================================================================
  module ConfigurationExamples
    # config/environments/production.rb での設定例
    def self.production_config
      {
        # 基本設定
        cache_store: [:solid_cache_store, {
          # エントリの最大生存時間（デフォルト: 2週間）
          max_age: 1_209_600, # 14.days.to_i
          # キャッシュの最大サイズ（バイト）
          max_size: 268_435_456, # 256MB
          # エビクションのバッチサイズ
          # 大きいほど一度に多く削除するが、ロック時間が長くなる
          batch_size: 100,
          # 名前空間（マルチアプリ環境での分離）
          namespace: 'myapp_production'
        }],

        # database.yml でのシャード設定例
        database_config: {
          production: {
            primary: { url: 'postgres://primary-db/myapp' },
            cache: {
              primary_shard: { url: 'postgres://cache-db-1/solid_cache' },
              secondary_shard: { url: 'postgres://cache-db-2/solid_cache' }
            }
          }
        },

        # config/solid_cache.yml での設定例
        solid_cache_yml: {
          production: {
            store_options: {
              max_age: 1_209_600,
              max_size: 268_435_456,
              namespace: 'myapp'
            },
            # 複数シャードの設定
            databases: %w[cache_shard1 cache_shard2 cache_shard3]
          }
        }
      }
    end

    # パフォーマンスチューニングのガイドライン
    def self.tuning_guidelines
      {
        max_size: {
          description: 'キャッシュの最大サイズ',
          recommendation: '利用可能ディスクの50-70%',
          note: 'FIFOなのでサイズが大きいほどヒット率が向上する'
        },
        max_age: {
          description: 'エントリの最大TTL',
          recommendation: 'アプリケーションに依存（通常1-4週間）',
          note: '長すぎると古いデータが残る、短すぎるとヒット率低下'
        },
        batch_size: {
          description: 'エビクション時の一括削除数',
          recommendation: '100-1000（DB性能に依存）',
          note: '大きすぎるとエビクション時のロック時間が長くなる'
        },
        shard_count: {
          description: 'データベースシャード数',
          recommendation: '書き込みスループットに応じて2-8',
          note: 'シャード追加は容易だが、削除時はデータ再配置が必要'
        }
      }
    end
  end

  # ==========================================================================
  # 7. デモンストレーション: 全機能の実行
  # ==========================================================================
  module Demonstration
    # データベースセットアップとFIFOキャッシュの基本操作を実行する
    def self.run_basic_operations
      DatabaseSetup.setup!
      store = FifoCacheStore.new(max_size: 1024, max_age: 3600)

      # 書き込みと読み取り
      store.write('user:1', { name: '田中太郎', role: 'admin' })
      store.write('user:2', { name: '佐藤花子', role: 'member' })

      user1 = store.read('user:1')
      user2 = store.read('user:2')
      missing = store.read('user:999')

      {
        user1: user1,
        user2: user2,
        missing: missing,
        stats: store.stats
      }
    end

    # FIFOエビクションの動作を確認する
    def self.run_fifo_eviction
      DatabaseSetup.setup!
      # 小さいmax_sizeでエビクションを発生させる
      store = FifoCacheStore.new(max_size: 500, max_age: 3600)

      write_order = []
      10.times do |i|
        key = "item:#{i}"
        store.write(key, "value_#{i}" * 5)
        write_order << key
      end

      # 最も古いエントリが追い出されていることを確認
      surviving = write_order.select { |key| store.read(key) }
      evicted = write_order.reject { |key| store.read(key) }

      {
        total_written: write_order.size,
        surviving_count: surviving.size,
        evicted_count: evicted.size,
        surviving_keys: surviving,
        evicted_keys: evicted,
        stats: store.stats
      }
    end

    # バッファリング書き込みの動作を確認する
    def self.run_buffered_write
      DatabaseSetup.setup!
      store = FifoCacheStore.new(max_size: 10_000, max_age: 3600)

      # バッファに書き込み（まだDBには反映されない）
      3.times { |i| store.buffered_write("buf:#{i}", "buffered_value_#{i}") }

      before_flush = {
        db_count: CacheEntry.count,
        buffer_entries: store.stats[:buffer_entries]
      }

      # フラッシュしてDBに反映
      store.flush_buffer

      after_flush = {
        db_count: CacheEntry.count,
        buffer_entries: store.stats[:buffer_entries]
      }

      { before_flush: before_flush, after_flush: after_flush }
    end

    # シャーディングの分散状況を確認する
    def self.run_sharding_demo
      ShardingSimulator.demonstrate_sharding
    end
  end
end
