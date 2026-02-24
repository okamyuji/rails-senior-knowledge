# frozen_string_literal: true

require_relative 'solid_cache'

RSpec.describe SolidCacheInternals do
  before do
    SolidCacheInternals::DatabaseSetup.setup!
  end

  describe SolidCacheInternals::CacheEntry do
    describe '.normalize_key' do
      it 'キーをSHA256ハッシュに正規化し、プレフィックスを付与する' do
        normalized = described_class.normalize_key('user:1')
        expect(normalized).to start_with('s3c-')
        # SHA256 Base64は44文字、プレフィックス4文字で固定長
        expect(normalized.length).to eq(48)
      end

      it '同じキーに対して常に同じハッシュを返す（決定的）' do
        hash1 = described_class.normalize_key('session:abc123')
        hash2 = described_class.normalize_key('session:abc123')
        expect(hash1).to eq(hash2)
      end

      it '異なるキーに対して異なるハッシュを返す' do
        hash1 = described_class.normalize_key('key_a')
        hash2 = described_class.normalize_key('key_b')
        expect(hash1).not_to eq(hash2)
      end
    end
  end

  describe SolidCacheInternals::FifoCacheStore do
    let(:store) { described_class.new(max_size: 2048, max_age: 3600) }

    describe '#write と #read' do
      it 'キャッシュに値を書き込み、読み取ることができる' do
        store.write('greeting', 'こんにちは')
        expect(store.read('greeting')).to eq('こんにちは')
      end

      it '存在しないキーの読み取りでnilを返す' do
        expect(store.read('nonexistent')).to be_nil
      end

      it '同じキーに書き込むと値が上書きされる' do
        store.write('counter', 1)
        store.write('counter', 2)
        expect(store.read('counter')).to eq(2)
        # 上書き後もエントリは1つだけ
        expect(SolidCacheInternals::CacheEntry.count).to eq(1)
      end

      it '複雑なオブジェクト（Hash、Array）をキャッシュできる' do
        data = { users: [{ id: 1, name: '田中' }, { id: 2, name: '佐藤' }], total: 2 }
        store.write('complex', data)
        expect(store.read('complex')).to eq(data)
      end
    end

    describe '#read_multi' do
      it '複数キーを一括で読み取ることができる' do
        store.write('a', 1)
        store.write('b', 2)
        store.write('c', 3)

        result = store.read_multi('a', 'b', 'c', 'missing')
        expect(result).to eq({ 'a' => 1, 'b' => 2, 'c' => 3 })
        expect(result).not_to have_key('missing')
      end
    end

    describe '#write_multi' do
      it '複数エントリを一括で書き込むことができる' do
        store.write_multi('x' => 10, 'y' => 20, 'z' => 30)

        expect(store.read('x')).to eq(10)
        expect(store.read('y')).to eq(20)
        expect(store.read('z')).to eq(30)
      end
    end

    describe '#delete' do
      it '指定したキーのエントリを削除する' do
        store.write('to_delete', 'value')
        expect(store.read('to_delete')).to eq('value')

        store.delete('to_delete')
        expect(store.read('to_delete')).to be_nil
      end
    end

    describe 'FIFOエビクション' do
      it 'max_sizeを超えると最も古いエントリから順に削除される' do
        # 小さいmax_sizeでストアを作成
        small_store = described_class.new(max_size: 400, max_age: 3600)

        # 順番に書き込み（各エントリはキー+値で数十バイト）
        written_keys = []
        20.times do |i|
          key = "evict_test_#{i}"
          small_store.write(key, "data_#{i}" * 3)
          written_keys << key
        end

        # 最も古いエントリ（前半）が追い出され、新しいエントリ（後半）が残る
        surviving = written_keys.select { |k| small_store.read(k) }
        evicted = written_keys.reject { |k| small_store.read(k) }

        expect(evicted).not_to be_empty
        expect(surviving).not_to be_empty

        # FIFO: 追い出されたキーは書き込み順の前半にあるはず
        evicted_indices = evicted.map { |k| k.split('_').last.to_i }
        surviving_indices = surviving.map { |k| k.split('_').last.to_i }
        expect(evicted_indices.max).to be < surviving_indices.max
      end

      it 'エビクション後のサイズがmax_sizeの75%以下になる' do
        small_store = described_class.new(max_size: 500, max_age: 3600)

        15.times do |i|
          small_store.write("size_test_#{i}", 'x' * 30)
        end

        total_size = SolidCacheInternals::CacheEntry.sum(:byte_size)
        expect(total_size).to be <= (500 * 0.75).to_i
      end
    end

    describe 'TTL期限切れ' do
      it 'max_ageを超えたエントリは読み取り時にnilを返す' do
        # max_age を 0秒に設定して即期限切れにする
        expiring_store = described_class.new(max_size: 2048, max_age: 0)

        expiring_store.write('expire_test', 'old_value')

        # created_atを過去に設定して期限切れを再現
        entry = SolidCacheInternals::CacheEntry.last
        entry.update_column(:created_at, Time.now - 1)

        expect(expiring_store.read('expire_test')).to be_nil
      end

      it 'expire_old_entriesで期限切れエントリを一括削除する' do
        short_store = described_class.new(max_size: 4096, max_age: 60)

        3.times { |i| short_store.write("old_#{i}", "value_#{i}") }
        2.times { |i| short_store.write("new_#{i}", "value_#{i}") }

        # 古いエントリのcreated_atを期限切れの時刻に更新
        # キーはSHA256ハッシュ化されているため、正規化キーで検索する
        old_keys = 3.times.map { |i| SolidCacheInternals::CacheEntry.normalize_key("old_#{i}") }
        SolidCacheInternals::CacheEntry
          .where(key: old_keys)
          .each { |e| e.update_column(:created_at, Time.now - 120) }

        expect(SolidCacheInternals::CacheEntry.count).to eq(5)

        short_store.expire_old_entries

        expect(SolidCacheInternals::CacheEntry.count).to eq(2)
      end
    end

    describe 'バッファリング書き込み' do
      it 'flush_bufferを呼ぶまでDBに書き込まれない' do
        store.buffered_write('buf_1', 'value_1')
        store.buffered_write('buf_2', 'value_2')

        # まだDBには反映されていない
        expect(SolidCacheInternals::CacheEntry.count).to eq(0)
        expect(store.stats[:buffer_entries]).to eq(2)

        store.flush_buffer

        # フラッシュ後にDBに反映される
        expect(SolidCacheInternals::CacheEntry.count).to eq(2)
        expect(store.stats[:buffer_entries]).to eq(0)
        expect(store.read('buf_1')).to eq('value_1')
      end
    end

    describe '#stats' do
      it 'キャッシュの統計情報を返す' do
        store.write('stat_1', 'value' * 10)
        store.write('stat_2', 'value' * 20)

        stats = store.stats
        expect(stats[:entry_count]).to eq(2)
        expect(stats[:total_bytes]).to be_positive
        expect(stats[:max_size]).to eq(2048)
        expect(stats[:usage_percent]).to be_a(Float)
        expect(stats[:oldest_entry]).to be_a(Time)
        expect(stats[:newest_entry]).to be_a(Time)
      end
    end
  end

  describe SolidCacheInternals::ShardingSimulator do
    describe '.demonstrate_sharding' do
      it 'キーが複数シャードに分散されることを確認する' do
        result = described_class.demonstrate_sharding
        distribution = result[:distribution]

        # 4シャードすべてにエントリが存在する
        expect(distribution.size).to eq(4)
        expect(distribution.all? { |d| d[:entries].positive? }).to be true

        # 合計100件が書き込まれている
        total = distribution.sum { |d| d[:entries] }
        expect(total).to eq(100)

        # 同じキーは常に同じシャードに振り分けられる（一貫性）
        expect(result[:consistent]).to be true
      end
    end

    describe SolidCacheInternals::ShardingSimulator::ShardRouter do
      it '同じキーに対して常に同じシャードを返す' do
        router = described_class.new(shard_count: 8)
        shard1 = router.shard_for('persistent_key')
        shard2 = router.shard_for('persistent_key')
        expect(shard1).to eq(shard2)
      end
    end
  end

  describe SolidCacheInternals::ComparisonWithRedis do
    describe '.comparison_table' do
      it '3つのキャッシュバックエンドの比較情報を返す' do
        table = described_class.comparison_table
        expect(table.keys).to contain_exactly(:solid_cache, :redis, :memcached)

        # 各バックエンドに必要な属性が含まれている
        %i[storage eviction max_capacity persistence use_case].each do |attr|
          expect(table[:solid_cache]).to have_key(attr)
          expect(table[:redis]).to have_key(attr)
          expect(table[:memcached]).to have_key(attr)
        end
      end
    end

    describe '.selection_guide' do
      it '各バックエンドの選定ガイドラインを返す' do
        guide = described_class.selection_guide
        expect(guide.keys).to contain_exactly(:choose_solid_cache, :choose_redis, :choose_memcached)
        expect(guide.values).to all(be_an(Array))
        expect(guide.values).to all(be_present)
      end
    end
  end

  describe SolidCacheInternals::Demonstration do
    describe '.run_basic_operations' do
      it '基本的なキャッシュ操作が正常に動作する' do
        result = described_class.run_basic_operations
        expect(result[:user1]).to eq({ name: '田中太郎', role: 'admin' })
        expect(result[:user2]).to eq({ name: '佐藤花子', role: 'member' })
        expect(result[:missing]).to be_nil
        expect(result[:stats][:entry_count]).to eq(2)
      end
    end

    describe '.run_fifo_eviction' do
      it 'FIFOエビクションで古いエントリが削除される' do
        result = described_class.run_fifo_eviction
        expect(result[:total_written]).to eq(10)
        expect(result[:evicted_count]).to be_positive
        expect(result[:surviving_count]).to be_positive
        expect(result[:surviving_count] + result[:evicted_count]).to eq(10)
      end
    end

    describe '.run_buffered_write' do
      it 'バッファリング書き込みの前後でDB状態が変化する' do
        result = described_class.run_buffered_write
        expect(result[:before_flush][:db_count]).to eq(0)
        expect(result[:before_flush][:buffer_entries]).to eq(3)
        expect(result[:after_flush][:db_count]).to eq(3)
        expect(result[:after_flush][:buffer_entries]).to eq(0)
      end
    end
  end
end
