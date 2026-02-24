# frozen_string_literal: true

# Railsキャッシング戦略の包括的解説モジュール
#
# Railsは統一されたキャッシュストアインターフェース（ActiveSupport::Cache::Store）を
# 提供し、MemoryStore、FileStore、MemCacheStore、RedisCacheStoreなどの
# バックエンドを透過的に切り替えられる。
#
# このモジュールでは、シニアエンジニアが知るべきキャッシング戦略の
# 内部動作を実例を通じて学ぶ：
# - キャッシュストアの統一API（read/write/fetch/delete/exist?）
# - Cache-asideパターン（fetchブロック）
# - 有効期限とrace_condition_ttlによるthundering herd対策
# - キャッシュバージョニングとロシアンドールキャッシング
# - HTTPキャッシングの概念（ETag, Last-Modified, stale?）
# - マルチレベルキャッシング戦略

require 'active_support'
require 'active_support/cache'
require 'active_support/core_ext/numeric/time'
require 'digest'
require 'json'

module CachingStrategies
  # ==========================================================================
  # 1. キャッシュストアインターフェース: 統一API
  # ==========================================================================
  #
  # ActiveSupport::Cache::Store は全キャッシュバックエンドの基底クラスであり、
  # 以下の統一APIを提供する：
  #
  # - read(key)       : キャッシュ値の読み取り。ミスならnil
  # - write(key, val) : キャッシュ値の書き込み
  # - fetch(key) { }  : 読み取り or ブロック実行して書き込み（cache-aside）
  # - delete(key)     : キャッシュエントリの削除
  # - exist?(key)     : キャッシュエントリの存在確認
  # - increment(key)  : カウンター値のインクリメント
  # - decrement(key)  : カウンター値のデクリメント
  # - clear           : 全キャッシュのクリア
  #
  # 全バックエンドがこの共通APIを実装するため、
  # コードを変更せずにバックエンドを切り替えられる。
  module CacheStoreInterface
    # MemoryStoreを使って統一APIの動作を示す
    #
    # MemoryStoreはプロセス内メモリにキャッシュを保持する。
    # テスト環境や単一プロセスのアプリケーションに適している。
    # マルチプロセス環境では共有されないため、本番では通常
    # Redis/Memcached/SolidCacheを使用する。
    #
    # @param size [Integer] MemoryStoreの最大サイズ（バイト）
    # @return [Hash] 各API操作の結果
    def self.demonstrate_unified_api(size: 32.kilobytes)
      store = ActiveSupport::Cache::MemoryStore.new(size: size)

      # write: キャッシュに値を書き込む
      store.write('user:1', { name: '田中太郎', role: 'admin' })
      store.write('user:2', { name: '佐藤花子', role: 'member' })

      # read: キャッシュから値を読み取る
      user1 = store.read('user:1')
      missing = store.read('user:999')

      # exist?: キャッシュキーの存在確認
      exists = store.exist?('user:1')
      not_exists = store.exist?('user:999')

      # delete: キャッシュエントリの削除
      store.delete('user:2')
      deleted_read = store.read('user:2')

      {
        write_and_read: user1,
        read_missing: missing,
        exist_true: exists,
        exist_false: not_exists,
        after_delete: deleted_read,
        store_class: store.class.name
      }
    end

    # MemoryStoreのサイズ制限とエビクション動作を示す
    #
    # MemoryStoreはLRU（Least Recently Used）エビクション戦略を使用する。
    # キャッシュサイズが制限を超えると、最も古くアクセスされたエントリから
    # 自動的に削除される。
    #
    # @return [Hash] サイズ制限とエビクションの結果
    def self.demonstrate_memory_store_eviction
      # 非常に小さいサイズのストアを作成（エビクションを発生させる）
      store = ActiveSupport::Cache::MemoryStore.new(size: 1.kilobyte)

      written_keys = []
      20.times do |i|
        key = "item:#{i}"
        # 各エントリは約50バイト以上消費する
        store.write(key, 'x' * 40)
        written_keys << key
      end

      surviving = written_keys.select { |key| store.exist?(key) }
      evicted = written_keys.reject { |key| store.exist?(key) }

      {
        total_written: written_keys.size,
        surviving_count: surviving.size,
        evicted_count: evicted.size,
        # MemoryStoreはLRUなので古いエントリが先に追い出される
        eviction_strategy: 'LRU（Least Recently Used）',
        note: 'MemoryStoreはサイズ超過時にLRUで自動エビクションする'
      }
    end
  end

  # ==========================================================================
  # 2. fetchとCache-asideパターン
  # ==========================================================================
  #
  # fetchメソッドはCache-asideパターンを実装している:
  # 1. キャッシュにキーが存在すればその値を返す（キャッシュヒット）
  # 2. 存在しなければブロックを実行し、結果をキャッシュに格納して返す
  #
  # これにより、キャッシュの読み取り・書き込みロジックを一か所にまとめ、
  # 呼び出し側のコードをシンプルに保てる。
  module FetchPattern
    # fetchの基本動作を示す
    #
    # fetchはRailsのキャッシング戦略の中核であり、
    # コントローラやモデルで最も頻繁に使用されるメソッドである。
    #
    # @return [Hash] fetchの動作結果（ヒット/ミス）
    def self.demonstrate_fetch_basic
      store = ActiveSupport::Cache::MemoryStore.new
      computation_count = 0

      # 初回: ブロックが実行される（キャッシュミス）
      result1 = store.fetch('expensive_query') do
        computation_count += 1
        { data: '計算結果', computed_at: Time.now.to_s }
      end

      # 2回目: ブロックは実行されない（キャッシュヒット）
      result2 = store.fetch('expensive_query') do
        computation_count += 1
        { data: '新しい計算結果', computed_at: Time.now.to_s }
      end

      {
        first_result: result1[:data],
        second_result: result2[:data],
        computation_count: computation_count,
        # ブロックは1回だけ実行された
        cache_hit_on_second: computation_count == 1,
        results_identical: result1[:data] == result2[:data]
      }
    end

    # fetchのforce:trueオプション
    #
    # force: true を指定すると、キャッシュの有無に関わらず
    # 常にブロックを実行して結果を書き直す。
    # キャッシュの明示的なリフレッシュに使用する。
    #
    # @return [Hash] force:trueの動作結果
    def self.demonstrate_fetch_force
      store = ActiveSupport::Cache::MemoryStore.new
      store.write('data', '古いデータ')

      # force: true でキャッシュを強制更新
      refreshed = store.fetch('data', force: true) do
        '新しいデータ'
      end

      {
        refreshed_value: refreshed,
        is_new_value: refreshed == '新しいデータ'
      }
    end

    # fetchの条件付きキャッシュ（skip_nil）
    #
    # Rails 7.1+ では skip_nil: true を指定すると、
    # ブロックがnilを返した場合にキャッシュへの書き込みをスキップする。
    # これにより、一時的な障害でnilが返された場合にキャッシュが汚染されるのを防ぐ。
    #
    # @return [Hash] skip_nilの動作結果
    def self.demonstrate_fetch_skip_nil
      store = ActiveSupport::Cache::MemoryStore.new

      # nilを返すブロック（skip_nil未使用 → nilがキャッシュされる）
      store.fetch('may_be_nil_cached') { nil } # rubocop:disable Style/RedundantFetchBlock
      cached_nil = store.exist?('may_be_nil_cached')

      # skip_nil: true → nilはキャッシュされない
      store.fetch('may_be_nil_skipped', skip_nil: true) { nil }
      skipped_nil = store.exist?('may_be_nil_skipped')

      {
        nil_without_skip_nil_cached: cached_nil,
        nil_with_skip_nil_cached: skipped_nil,
        note: 'skip_nil: trueでnil結果のキャッシュ汚染を防止できる'
      }
    end
  end

  # ==========================================================================
  # 3. キャッシュ有効期限: expires_in と race_condition_ttl
  # ==========================================================================
  #
  # キャッシュエントリに有効期限を設定することで、古いデータが
  # 無期限に残り続けることを防止する。
  #
  # race_condition_ttl はキャッシュ期限切れ時のthundering herd問題
  # （多数のリクエストが同時にキャッシュを再構築しようとする現象）を
  # 緩和するための仕組みである。
  module CacheExpiration
    # expires_in による有効期限の設定を示す
    #
    # @return [Hash] 有効期限の動作結果
    def self.demonstrate_expires_in
      store = ActiveSupport::Cache::MemoryStore.new

      # 1秒後に期限切れになるエントリを書き込む
      store.write('short_lived', '一時データ', expires_in: 1.second)
      store.write('long_lived', '長期データ', expires_in: 1.hour)
      store.write('no_expiry', '無期限データ')

      # 書き込み直後は全て存在する
      before_expiry = {
        short_lived: store.exist?('short_lived'),
        long_lived: store.exist?('long_lived'),
        no_expiry: store.exist?('no_expiry')
      }

      # 1.5秒待機して短期エントリを期限切れにする
      sleep(1.5)

      after_expiry = {
        short_lived: store.exist?('short_lived'),
        long_lived: store.exist?('long_lived'),
        no_expiry: store.exist?('no_expiry')
      }

      {
        before_expiry: before_expiry,
        after_expiry: after_expiry,
        short_lived_expired: !after_expiry[:short_lived],
        long_lived_still_valid: after_expiry[:long_lived],
        no_expiry_still_valid: after_expiry[:no_expiry]
      }
    end

    # race_condition_ttl によるthundering herd対策の概念を示す
    #
    # race_condition_ttl の動作原理：
    # 1. キャッシュが期限切れになった時、最初のリクエストがキャッシュを再構築する
    # 2. その間、他のリクエストには古い（期限切れの）キャッシュ値が返される
    # 3. race_condition_ttl で指定した時間だけ、古い値が「延長」される
    # 4. 再構築が完了すると、新しい値で上書きされる
    #
    # これにより、大量のリクエストが同時にDBクエリを発行する
    # thundering herd（集団暴走）を防止できる。
    #
    # @return [Hash] race_condition_ttlの概念説明
    def self.demonstrate_race_condition_ttl_concept
      store = ActiveSupport::Cache::MemoryStore.new
      computation_count = 0

      # race_condition_ttl付きでキャッシュを書き込む
      # expires_in: 1秒で期限切れ、race_condition_ttl: 10秒で古い値を延長
      result = store.fetch('popular_data', expires_in: 1.second, race_condition_ttl: 10.seconds) do
        computation_count += 1
        "計算結果_#{computation_count}"
      end

      {
        initial_result: result,
        computation_count: computation_count,
        explanation: {
          without_race_condition_ttl: [
            'キャッシュ期限切れ → 100リクエストが同時にfetchを呼ぶ',
            '100リクエスト全てがブロックを実行（100回のDBクエリ）',
            'サーバーに一時的な高負荷（thundering herd）'
          ],
          with_race_condition_ttl: [
            'キャッシュ期限切れ → 最初の1リクエストがブロックを実行',
            '残りの99リクエストには古いキャッシュ値が返される',
            '最初のリクエストがキャッシュを更新 → 次回から新しい値',
            'サーバー負荷は最小限（1回のDBクエリのみ）'
          ]
        },
        best_practice: '人気のあるキャッシュキーには必ずrace_condition_ttlを設定する'
      }
    end

    # race_condition_ttl の実際の動作をシミュレートする
    #
    # @return [Hash] シミュレーション結果
    def self.simulate_race_condition_ttl
      store = ActiveSupport::Cache::MemoryStore.new
      fetch_count = 0

      # 短い期限のキャッシュを設定
      store.fetch('hot_key', expires_in: 1.second, race_condition_ttl: 5.seconds) do
        fetch_count += 1
        "value_v#{fetch_count}"
      end

      initial_value = store.read('hot_key')
      initial_fetch_count = fetch_count

      # 期限切れを待つ
      sleep(1.5)

      # 期限切れ後にfetchを呼ぶとブロックが再実行される
      refreshed = store.fetch('hot_key', expires_in: 1.second, race_condition_ttl: 5.seconds) do
        fetch_count += 1
        "value_v#{fetch_count}"
      end

      {
        initial_value: initial_value,
        refreshed_value: refreshed,
        total_fetch_count: fetch_count,
        was_recomputed: fetch_count > initial_fetch_count
      }
    end
  end

  # ==========================================================================
  # 4. キャッシュバージョニング: cache_version による自動無効化
  # ==========================================================================
  #
  # Rails 5.2+ のキャッシュバージョニングでは、キャッシュキーとバージョンが分離された。
  #
  # 従来のキャッシュキー: "users/1-20241001120000"（id + updated_at）
  # 新方式:
  #   キー: "users/1"
  #   バージョン: "20241001120000"（cache_version）
  #
  # この分離により:
  # - キャッシュストア内のキーが安定する（バージョン変更でキーが変わらない）
  # - recyclable cache keys: 古いエントリが自然に上書きされる
  # - メモリ使用量の削減（古いキーのゴミが残らない）
  module CacheVersioning
    # キャッシュバージョニングの動作を示すモデルのシミュレーション
    class VersionedModel
      attr_reader :id, :name, :updated_at, :version

      def initialize(id:, name:, updated_at: Time.now, version: 1)
        @id = id
        @name = name
        @updated_at = updated_at
        @version = version
      end

      # ActiveRecordのcache_keyに相当する
      # Rails 5.2+ではupdated_atを含まない安定したキーを返す
      def cache_key
        "versioned_models/#{id}"
      end

      # ActiveRecordのcache_versionに相当する
      # モデルが更新されるとバージョンが変わり、キャッシュが無効化される
      def cache_version
        "v#{version}-#{updated_at.to_i}"
      end

      # cache_key_with_versionはキーとバージョンを結合したもの
      # Rails内部ではfetch時にバージョン比較が行われる
      def cache_key_with_version
        "#{cache_key}:#{cache_version}"
      end

      # モデルを「更新」した新しいインスタンスを返す
      def update(name:)
        self.class.new(
          id: id,
          name: name,
          updated_at: Time.now,
          version: version + 1
        )
      end
    end

    # キャッシュバージョニングの動作を示す
    #
    # @return [Hash] バージョニングの結果
    def self.demonstrate_cache_versioning
      store = ActiveSupport::Cache::MemoryStore.new

      model_v1 = VersionedModel.new(id: 1, name: '初期名前')

      # バージョン付きでキャッシュに格納
      store.write(model_v1.cache_key, 'キャッシュデータv1', version: model_v1.cache_version)

      # 同じバージョンで読み取り → ヒット
      hit = store.read(model_v1.cache_key, version: model_v1.cache_version)

      # モデルを更新（バージョンが変わる）
      model_v2 = model_v1.update(name: '更新名前')

      # 新しいバージョンで読み取り → ミス（バージョン不一致）
      miss = store.read(model_v2.cache_key, version: model_v2.cache_version)

      # 新しいバージョンでキャッシュを書き直す
      store.write(model_v2.cache_key, 'キャッシュデータv2', version: model_v2.cache_version)
      new_hit = store.read(model_v2.cache_key, version: model_v2.cache_version)

      {
        model_v1_cache_key: model_v1.cache_key,
        model_v1_cache_version: model_v1.cache_version,
        model_v2_cache_key: model_v2.cache_key,
        model_v2_cache_version: model_v2.cache_version,
        # 同じキーだがバージョンが異なる
        same_cache_key: model_v1.cache_key == model_v2.cache_key,
        different_version: model_v1.cache_version != model_v2.cache_version,
        v1_cache_hit: hit,
        v2_cache_miss_before_write: miss,
        v2_cache_hit_after_write: new_hit
      }
    end

    # Recyclable cache keysの利点を示す
    #
    # 従来方式ではupdated_atがキーに含まれるため、更新のたびに
    # 新しいキーが生成され、古いキーのエントリがゴミとして残った。
    #
    # 新方式ではキーが安定しているため、同じスロットが上書きされ、
    # メモリの無駄遣いが発生しない。
    #
    # @return [Hash] recyclable cache keysの解説
    def self.demonstrate_recyclable_keys
      store = ActiveSupport::Cache::MemoryStore.new

      model = VersionedModel.new(id: 1, name: 'テスト')

      # 5回更新してもキーは同じ
      keys_used = []
      versions_used = []
      current = model
      5.times do |i|
        keys_used << current.cache_key
        versions_used << current.cache_version
        store.write(current.cache_key, "データ_#{i}", version: current.cache_version)
        current = current.update(name: "更新#{i}") # rubocop:disable Style/RedundantSelfAssignment
        sleep(0.01) # タイムスタンプを変えるため
      end

      {
        all_keys_identical: keys_used.uniq.size == 1,
        all_versions_unique: versions_used.uniq.size == versions_used.size,
        key_example: keys_used.first,
        version_examples: versions_used,
        benefit: '同じキーが再利用されるため、古いエントリのゴミが溜まらない'
      }
    end
  end

  # ==========================================================================
  # 5. ロシアンドールキャッシング: 入れ子キャッシュフラグメント
  # ==========================================================================
  #
  # ロシアンドールキャッシングは、ビューのキャッシュフラグメントを入れ子にする
  # テクニックである。外側のキャッシュが有効なら、内側の個別キャッシュの
  # チェックすら不要になり、レンダリング速度が大幅に向上する。
  #
  # 構造例:
  # <% cache @collection do %>          ← 外側キャッシュ（コレクション全体）
  #   <% @collection.each do |item| %>
  #     <% cache item do %>             ← 内側キャッシュ（個別アイテム）
  #       <%= render item %>
  #     <% end %>
  #   <% end %>
  # <% end %>
  #
  # touchオプション:
  # belongs_to :parent, touch: true
  # → 子モデルが更新されると親のupdated_atも更新される
  # → 親のキャッシュバージョンが変わり、外側キャッシュが自動無効化される
  module RussianDollCaching
    # ロシアンドールキャッシングの動作をシミュレートする
    #
    # @return [Hash] ネストされたキャッシュの動作結果
    def self.demonstrate_russian_doll
      store = ActiveSupport::Cache::MemoryStore.new
      render_count = { outer: 0, inner: 0 }

      # モデルデータの準備
      items = [
        { id: 1, name: 'アイテムA', updated_at: Time.now },
        { id: 2, name: 'アイテムB', updated_at: Time.now },
        { id: 3, name: 'アイテムC', updated_at: Time.now }
      ]

      # コレクション全体のキャッシュバージョン
      collection_version = items.map { |i| "#{i[:id]}-#{i[:updated_at].to_i}" }.join('/')

      # --- 初回レンダリング: 全てキャッシュミス ---
      outer_result = store.fetch('collection', version: collection_version) do
        render_count[:outer] += 1
        items.map do |item|
          item_version = "#{item[:id]}-#{item[:updated_at].to_i}"
          store.fetch("item:#{item[:id]}", version: item_version) do
            render_count[:inner] += 1
            "<div>#{item[:name]}</div>"
          end
        end.join
      end

      first_pass = { outer: render_count[:outer], inner: render_count[:inner] }

      # --- 2回目: 外側キャッシュがヒット → 内側チェック不要 ---
      outer_result2 = store.fetch('collection', version: collection_version) do
        render_count[:outer] += 1
        items.map do |item|
          item_version = "#{item[:id]}-#{item[:updated_at].to_i}"
          store.fetch("item:#{item[:id]}", version: item_version) do
            render_count[:inner] += 1
            "<div>#{item[:name]}</div>"
          end
        end.join
      end

      second_pass = { outer: render_count[:outer], inner: render_count[:inner] }

      {
        first_pass_renders: first_pass,
        second_pass_renders: second_pass,
        outer_html: outer_result,
        second_same_as_first: outer_result == outer_result2,
        # 2回目ではouterもinnerも実行されていない
        no_rerender_on_hit: first_pass == second_pass
      }
    end

    # touch: true によるカスケード無効化をシミュレートする
    #
    # ActiveRecordの belongs_to :parent, touch: true は、
    # 子レコードが更新されたとき親のupdated_atを自動更新する。
    # これによりキャッシュバージョンが変わり、親のキャッシュが無効化される。
    #
    # @return [Hash] touchによるカスケード無効化の結果
    def self.demonstrate_touch_cascade
      store = ActiveSupport::Cache::MemoryStore.new

      # 親モデル
      parent = { id: 1, name: '親カテゴリ', updated_at: Time.now }
      # 子モデル
      children = [
        { id: 1, name: '子A', parent_id: 1, updated_at: Time.now },
        { id: 2, name: '子B', parent_id: 1, updated_at: Time.now }
      ]

      parent_version = "#{parent[:id]}-#{parent[:updated_at].to_f}"

      # 親のキャッシュを構築
      store.fetch("parent:#{parent[:id]}", version: parent_version) do
        children.map { |c| c[:name] }.join(', ')
      end

      cached_before = store.read("parent:#{parent[:id]}", version: parent_version)

      # 子が更新 → touch: true により親の updated_at も更新される
      sleep(0.01) # タイムスタンプを変えるため
      parent_after_touch = parent.merge(updated_at: Time.now)
      new_parent_version = "#{parent_after_touch[:id]}-#{parent_after_touch[:updated_at].to_f}"

      # 古いバージョンでの読み取り → まだ有効
      still_cached = store.read("parent:#{parent[:id]}", version: parent_version)

      # 新しいバージョンでの読み取り → ミス（バージョン不一致）
      cache_miss = store.read("parent:#{parent[:id]}", version: new_parent_version)

      {
        cached_before_touch: cached_before,
        still_valid_with_old_version: still_cached,
        miss_with_new_version: cache_miss,
        parent_version_changed: parent_version != new_parent_version,
        explanation: 'touch: trueにより子の更新が親のキャッシュ無効化をトリガーする'
      }
    end
  end

  # ==========================================================================
  # 6. キャッシュキー生成: ActiveRecordの自動キー生成
  # ==========================================================================
  #
  # ActiveRecordモデルは以下のルールでキャッシュキーを自動生成する:
  #
  # cache_key（Rails 5.2+）:
  #   "モデル名/id" 例: "users/1"
  #
  # cache_version（Rails 5.2+）:
  #   "updated_atのタイムスタンプ" 例: "20241001120000000000"
  #
  # cache_key_with_version（従来互換）:
  #   "モデル名/id-updated_at" 例: "users/1-20241001120000000000"
  #
  # コレクションのキャッシュキー:
  #   ActiveRecordは関連のcollection cache keyも生成できる
  #   COUNT + MAX(updated_at) を使い、1つでも更新されるとキーが変わる
  module CacheKeyGeneration
    # キャッシュキー生成のルールをシミュレートする
    #
    # @return [Hash] 各種キャッシュキーの例
    def self.demonstrate_cache_key_patterns
      now = Time.now

      # 単一モデルのキャッシュキー
      model = {
        class_name: 'User',
        id: 42,
        updated_at: now
      }

      single_cache_key = "#{model[:class_name].downcase.tr('::', '/')}s/#{model[:id]}"
      single_cache_version = now.utc.to_fs(:usec)

      # コレクションのキャッシュキー
      models = [
        { id: 1, updated_at: now - 100 },
        { id: 2, updated_at: now - 50 },
        { id: 3, updated_at: now }
      ]

      collection_count = models.size
      collection_max_updated = models.map { |m| m[:updated_at] }.max
      collection_cache_key = "users/query-#{Digest::SHA256.hexdigest('all')}-" \
                             "#{collection_count}-#{collection_max_updated.utc.to_fs(:usec)}"

      {
        single_model: {
          cache_key: single_cache_key,
          cache_version: single_cache_version,
          cache_key_with_version: "#{single_cache_key}-#{single_cache_version}"
        },
        collection: {
          cache_key: collection_cache_key,
          count: collection_count,
          max_updated_at: collection_max_updated.to_s
        },
        key_components: {
          model_name: 'テーブル名の複数形',
          id: 'レコードのプライマリキー',
          updated_at: '最終更新日時（バージョニング用）'
        }
      }
    end

    # 名前空間付きキャッシュキーの構築
    #
    # キャッシュキーに名前空間を付けることで、
    # アプリケーション間やバージョン間でのキー衝突を防止できる。
    #
    # @return [Hash] 名前空間付きキャッシュキーの例
    def self.demonstrate_namespaced_keys
      store = ActiveSupport::Cache::MemoryStore.new(namespace: 'myapp-v2')

      store.write('user:1', 'データ')
      value = store.read('user:1')

      # 異なる名前空間のストアでは読めない
      other_store = ActiveSupport::Cache::MemoryStore.new(namespace: 'myapp-v1')
      cross_read = other_store.read('user:1')

      {
        value_in_namespace: value,
        cross_namespace_read: cross_read,
        namespace_benefit: '名前空間によりアプリバージョン間のキャッシュ衝突を防止'
      }
    end
  end

  # ==========================================================================
  # 7. 条件付きキャッシュ: HTTPキャッシングの概念
  # ==========================================================================
  #
  # RailsはHTTPレベルのキャッシング機能も提供している:
  #
  # - ETag: レスポンスのハッシュ値。変更がなければ304 Not Modifiedを返す
  # - Last-Modified: レスポンスの最終更新日時
  # - stale?: ETag/Last-Modifiedの変更をチェックするヘルパー
  # - fresh_when: 条件付きGETレスポンスを設定するヘルパー
  # - expires_in: Cache-Control ヘッダーでブラウザキャッシュ期限を設定
  #
  # HTTPキャッシングにより、変更のないリソースの再ダウンロードを省略でき、
  # ネットワーク帯域とサーバー負荷を大幅に削減できる。
  module ConditionalCaching
    # ETagベースのHTTPキャッシングの概念を示す
    #
    # @return [Hash] HTTPキャッシングの概念説明
    def self.demonstrate_etag_concept
      # レスポンスボディのシミュレーション
      response_body = { users: [{ id: 1, name: '田中' }] }.to_json

      # ETagはレスポンスボディのハッシュ値
      etag = Digest::MD5.hexdigest(response_body)

      # クライアントが If-None-Match ヘッダーで前回のETagを送信
      client_etag = etag

      # サーバー側で現在のETagと比較
      not_modified = (etag == client_etag)

      {
        etag: etag,
        client_sent_etag: client_etag,
        not_modified: not_modified,
        http_status: not_modified ? 304 : 200,
        flow: {
          step1: '初回リクエスト → サーバーがETag付きで200レスポンス',
          step2: '2回目リクエスト → クライアントがIf-None-MatchでETagを送信',
          step3: 'サーバーがETagを比較 → 一致なら304 Not Modified（ボディなし）',
          step4: 'クライアントはローカルキャッシュを使用'
        },
        rails_usage: {
          controller: 'stale?(@user) で自動的にETag/Last-Modifiedチェック',
          fresh_when: 'fresh_when(@user) で304レスポンスを返す',
          etag_generation: 'Rails内部でMarshal.dump + MD5でETag生成'
        }
      }
    end

    # Last-Modified ベースのキャッシングの概念を示す
    #
    # @return [Hash] Last-Modifiedキャッシングの説明
    def self.demonstrate_last_modified_concept
      last_modified = Time.now - 3600 # 1時間前に更新

      # クライアントが If-Modified-Since ヘッダーで前回の更新日時を送信
      client_if_modified_since = last_modified

      # サーバー側で比較
      not_modified = (last_modified <= client_if_modified_since)

      {
        last_modified: last_modified.httpdate,
        client_if_modified_since: client_if_modified_since.httpdate,
        not_modified: not_modified,
        http_status: not_modified ? 304 : 200,
        rails_helpers: {
          stale: 'stale?(last_modified: @article.updated_at)',
          fresh_when: 'fresh_when(last_modified: @article.updated_at)',
          expires_in: 'expires_in(1.hour, public: true)'
        },
        cache_control_headers: {
          public: 'CDNやプロキシがキャッシュ可能',
          private: 'ブラウザのみキャッシュ可能（デフォルト）',
          no_cache: 'キャッシュするが毎回検証が必要',
          no_store: '一切キャッシュしない',
          max_age: 'キャッシュの有効期限（秒）'
        }
      }
    end

    # stale? メソッドの動作をシミュレートする
    #
    # stale? はコントローラで使用され、以下を行う:
    # 1. モデルのupdated_atとcache_keyからETagとLast-Modifiedを設定
    # 2. リクエストのIf-None-Match / If-Modified-Sinceと比較
    # 3. 変更がなければ304を返し、ブロック内の処理をスキップ
    #
    # @return [Hash] stale?シミュレーションの結果
    def self.simulate_stale_check
      model_updated_at = Time.now - 3600
      model_etag = Digest::MD5.hexdigest("user-1-#{model_updated_at.to_i}")

      # ケース1: 初回リクエスト（キャッシュなし）
      case1 = {
        client_etag: nil,
        server_etag: model_etag,
        is_stale: true,
        action: '200 OK + フルレスポンス'
      }

      # ケース2: 2回目リクエスト（ETag一致）
      case2 = {
        client_etag: model_etag,
        server_etag: model_etag,
        is_stale: false,
        action: '304 Not Modified（ボディなし）'
      }

      # ケース3: モデル更新後のリクエスト（ETag不一致）
      new_etag = Digest::MD5.hexdigest("user-1-#{Time.now.to_i}")
      case3 = {
        client_etag: model_etag,
        server_etag: new_etag,
        is_stale: true,
        action: '200 OK + 新しいレスポンス'
      }

      {
        case1_first_request: case1,
        case2_cache_hit: case2,
        case3_after_update: case3,
        controller_example: <<~RUBY
          def show
            @user = User.find(params[:id])
            if stale?(@user)
              # この中の処理は304の場合スキップされる
              render json: @user
            end
          end
        RUBY
      }
    end
  end

  # ==========================================================================
  # 8. マルチレベルキャッシング: メモリ + 分散キャッシュの組み合わせ
  # ==========================================================================
  #
  # 本番環境では、複数レベルのキャッシュを組み合わせることで
  # レイテンシとヒット率を最適化できる：
  #
  # L1: プロセス内メモリキャッシュ（MemoryStore）
  #     → 最速だがプロセス間で共有不可
  # L2: 分散キャッシュ（Redis/Memcached/SolidCache）
  #     → やや遅いが全プロセス/サーバーで共有可能
  #
  # リクエスト処理の流れ:
  # 1. L1（メモリ）をチェック → ヒットなら即座に返却（マイクロ秒）
  # 2. L1ミス → L2（Redis等）をチェック → ヒットならL1に書き戻して返却
  # 3. L2ミス → DBクエリ実行 → L2とL1の両方に書き込み
  module MultiLevelCaching
    # 2層キャッシュの簡易実装
    class TwoLevelCache
      attr_reader :l1_store, :l2_store, :stats

      def initialize(l1_size: 1.kilobyte, l2_size: 32.kilobytes)
        # L1: プロセス内メモリ（高速・小容量）
        @l1_store = ActiveSupport::Cache::MemoryStore.new(size: l1_size)
        # L2: 分散キャッシュのシミュレーション（やや低速・大容量）
        @l2_store = ActiveSupport::Cache::MemoryStore.new(size: l2_size)
        @stats = { l1_hit: 0, l2_hit: 0, miss: 0 }
      end

      # マルチレベルfetch
      #
      # @param key [String] キャッシュキー
      # @param options [Hash] expires_in等のオプション
      # @yield ブロック（キャッシュミス時に実行）
      # @return [Object] キャッシュされた値または計算結果
      def fetch(key, default = nil, **, &block)
        # L1チェック
        value = @l1_store.read(key)
        if value
          @stats[:l1_hit] += 1
          return value
        end

        # L2チェック
        value = @l2_store.read(key)
        if value
          @stats[:l2_hit] += 1
          # L1に書き戻し（write-back）
          @l1_store.write(key, value, **)
          return value
        end

        # 両方ミス → ブロックまたはデフォルト値を使用
        @stats[:miss] += 1
        value = block ? block.call : default
        # 両レベルに書き込み（write-through）
        @l2_store.write(key, value, **)
        @l1_store.write(key, value, **)
        value
      end

      # 削除は両レベルから行う
      def delete(key)
        @l1_store.delete(key)
        @l2_store.delete(key)
      end

      # L1のみクリア（デプロイ時のプロセス内キャッシュリセット）
      def clear_l1
        @l1_store.clear
      end

      def hit_rate
        total = @stats.values.sum
        return 0.0 if total.zero?

        ((@stats[:l1_hit] + @stats[:l2_hit]).to_f / total * 100).round(1)
      end
    end

    # マルチレベルキャッシングの動作を示す
    #
    # @return [Hash] マルチレベルキャッシュの動作結果
    def self.demonstrate_multi_level
      cache = TwoLevelCache.new

      computation_count = 0

      # 初回: 両レベルミス → ブロック実行
      result1 = cache.fetch('popular_data') do
        computation_count += 1
        '重い計算結果'
      end

      # 2回目: L1ヒット（最速）
      result2 = cache.fetch('popular_data') do
        computation_count += 1
        '再計算'
      end

      # L1をクリア（デプロイ時を模擬）
      cache.clear_l1

      # 3回目: L1ミス → L2ヒット → L1に書き戻し
      result3 = cache.fetch('popular_data') do
        computation_count += 1
        '再計算'
      end

      # 4回目: L1ヒット（L2から書き戻されたデータ）
      result4 = cache.fetch('popular_data') do
        computation_count += 1
        '再計算'
      end

      {
        results: [result1, result2, result3, result4],
        all_same_value: [result1, result2, result3, result4].uniq.size == 1,
        computation_count: computation_count,
        stats: cache.stats,
        hit_rate: cache.hit_rate,
        explanation: {
          fetch1: 'L1ミス → L2ミス → ブロック実行（miss: 1）',
          fetch2: 'L1ヒット（l1_hit: 1）',
          fetch3: 'L1ミス → L2ヒット → L1書き戻し（l2_hit: 1）',
          fetch4: 'L1ヒット（l1_hit: 2）'
        }
      }
    end

    # マルチレベルキャッシングのベストプラクティス
    #
    # @return [Hash] ベストプラクティスの解説
    def self.best_practices
      {
        l1_configuration: {
          size: 'プロセスあたり32-128MB',
          ttl: '短め（5-15分）。プロセスローカルなので古いデータに注意',
          use_case: '頻繁にアクセスされるホットデータ'
        },
        l2_configuration: {
          backend: 'Redis（高スループット）/ SolidCache（運用簡素化）',
          ttl: '長め（1-24時間）。共有キャッシュなので整合性が高い',
          use_case: '全サーバーで共有すべきデータ'
        },
        invalidation_strategy: {
          delete_through: '削除時は必ずL1とL2の両方から削除する',
          ttl_based: 'TTLを設定して自然に期限切れにする（推奨）',
          event_based: 'ActiveSupport::Notificationsでキャッシュ無効化イベントを配信'
        },
        pitfalls: [
          'L1とL2の不整合（L1に古いデータ、L2に新しいデータ）',
          'L1のメモリ消費量の監視不足',
          'キャッシュ無効化の漏れ（L1だけ削除してL2を忘れる）'
        ]
      }
    end
  end

  # ==========================================================================
  # 9. キャッシュ戦略の比較と選定ガイド
  # ==========================================================================
  module StrategyComparison
    # キャッシング戦略の一覧と使い分けガイド
    #
    # @return [Hash] 各戦略の比較
    def self.comparison_guide
      {
        page_caching: {
          description: 'ページ全体をHTMLファイルとしてキャッシュ',
          scope: 'ページ全体',
          invalidation: 'ファイル削除',
          use_case: '完全に静的なページ（about、terms等）',
          limitation: '認証やパーソナライゼーションのあるページには不向き',
          rails_support: "gem 'actionpack-page_caching' として外部化済み"
        },
        action_caching: {
          description: 'コントローラアクション全体の出力をキャッシュ',
          scope: 'アクション出力',
          invalidation: 'expire_action',
          use_case: 'before_actionを通したいが出力は同じページ',
          limitation: 'ページキャッシュより遅い（Railsスタック通過）',
          rails_support: "gem 'actionpack-action_caching' として外部化済み"
        },
        fragment_caching: {
          description: 'ビューの一部分（フラグメント）をキャッシュ',
          scope: 'ビュー部分',
          invalidation: 'cache_keyのバージョン変更',
          use_case: '動的ページ内の変更頻度が低い部分',
          limitation: 'キャッシュキーの設計が重要',
          rails_support: 'Rails組み込み（cache ヘルパー）'
        },
        russian_doll: {
          description: 'フラグメントキャッシュを入れ子にする',
          scope: 'ネストされたビュー部分',
          invalidation: 'touch: true によるカスケード',
          use_case: 'リスト表示で個別アイテムの更新が頻繁',
          limitation: 'touchの連鎖による意図しない大量無効化',
          rails_support: 'Rails組み込み（cache + touch）'
        },
        low_level_caching: {
          description: 'Rails.cache.fetch でモデル/サービス層でキャッシュ',
          scope: '任意のRubyオブジェクト',
          invalidation: '明示的なdelete / expires_in',
          use_case: 'DBクエリ結果、外部API応答、重い計算結果',
          limitation: 'キャッシュ無効化の管理が必要',
          rails_support: 'Rails組み込み（ActiveSupport::Cache）'
        },
        http_caching: {
          description: 'HTTP ETag / Last-Modified による条件付きGET',
          scope: 'HTTPレスポンス全体',
          invalidation: 'ETag / Last-Modifiedの変更',
          use_case: 'API応答、静的に近いページ',
          limitation: 'サーバー側で毎回ETag計算が必要',
          rails_support: 'Rails組み込み（stale? / fresh_when）'
        }
      }
    end
  end
end
