# frozen_string_literal: true

require_relative 'gc_internals'

RSpec.describe GcInternals do
  describe '.demonstrate_generational_gc' do
    it '世代別GCの統計情報を返し、マイナーGCがメジャーGC以上の頻度で発生していること' do
      result = described_class.demonstrate_generational_gc

      expect(result).to include(
        :minor_gc_before, :minor_gc_after,
        :major_gc_before, :major_gc_after,
        :minor_more_frequent
      )

      # マイナーGCの回数が増加しているか、少なくとも同じであること
      expect(result[:minor_gc_after]).to be >= result[:minor_gc_before]
      # メジャーGCの回数が増加しているか、少なくとも同じであること
      expect(result[:major_gc_after]).to be >= result[:major_gc_before]
      # マイナーGCの累計はメジャーGC以上であること
      expect(result[:minor_more_frequent]).to be true
    end
  end

  describe '.read_gc_stats' do
    it 'GC統計情報の主要項目がすべて含まれること' do
      result = described_class.read_gc_stats

      expect(result[:heap_live_slots]).to be_a(Integer)
      expect(result[:heap_live_slots]).to be_positive
      expect(result[:heap_free_slots]).to be_a(Integer)
      expect(result[:total_allocated_objects]).to be_a(Integer)
      expect(result[:total_allocated_objects]).to be_positive
      expect(result[:total_freed_objects]).to be_a(Integer)
      expect(result[:minor_gc_count]).to be_a(Integer)
      expect(result[:major_gc_count]).to be_a(Integer)
      expect(result[:gc_count]).to be_a(Integer)
    end

    it '利用可能なキー一覧が配列で返されること' do
      result = described_class.read_gc_stats

      expect(result[:available_keys]).to be_an(Array)
      expect(result[:available_keys]).not_to be_empty
      expect(result[:available_keys]).to include(:heap_live_slots, :minor_gc_count, :major_gc_count)
    end
  end

  describe '.demonstrate_compaction' do
    it 'GC.compactの利用可否とヒープ統計を返すこと' do
      result = described_class.demonstrate_compaction

      expect(result).to include(:compact_available, :compact_result, :heap_live_before, :heap_live_after)
      expect(result[:compact_available]).to be(true).or be(false)
      expect(result[:heap_live_before]).to be_a(Integer)
      expect(result[:heap_live_after]).to be_a(Integer)
    end
  end

  describe '.gc_tuning_env_vars' do
    it 'GCチューニング用環境変数の一覧と推奨値を返すこと' do
      result = described_class.gc_tuning_env_vars

      expect(result[:env_vars]).to be_a(Hash)
      expect(result[:ruby_version]).to eq(RUBY_VERSION)

      # 主要な環境変数が含まれていること
      expect(result[:env_vars]).to include(
        'RUBY_GC_HEAP_INIT_SLOTS',
        'RUBY_GC_HEAP_GROWTH_FACTOR',
        'RUBY_GC_MALLOC_LIMIT'
      )

      # 各項目にdescriptionとrecommended_for_railsが含まれること
      result[:env_vars].each_value do |info|
        expect(info).to include(:description, :recommended_for_rails)
      end
    end

    it '現在のGCパラメータが含まれること' do
      result = described_class.gc_tuning_env_vars

      expect(result[:current_gc_params]).to include(:heap_allocated_pages, :heap_live_slots)
      expect(result[:current_gc_params][:heap_live_slots]).to be_positive
    end
  end

  describe '.demonstrate_weak_references' do
    it 'WeakRefとWeakMapの基本動作を検証できること' do
      result = described_class.demonstrate_weak_references

      # WeakRefが有効な間はアクセス可能であること
      expect(result[:weakref_alive]).to be true
      expect(result[:weakref_value]).to be_a(String)

      # WeakMapのクラス名が正しいこと
      expect(result[:weak_map_type]).to eq('ObjectSpace::WeakMap')

      # 強参照を保持しているキーにアクセスできること
      expect(result[:live_key_accessible]).to be true
    end
  end

  describe '.track_object_allocations' do
    it '文字列結合の+演算子が<<演算子より多くのオブジェクトを割り当てること' do
      result = described_class.track_object_allocations

      expect(result[:string_concat_allocations]).to be_a(Integer)
      expect(result[:string_append_allocations]).to be_a(Integer)
      # + 演算子は中間オブジェクトを生成するため、<< より多くの割り当てが発生する
      expect(result[:concat_more_than_append]).to be true
      expect(result[:string_concat_allocations]).to be > result[:string_append_allocations]
    end

    it 'map と each_with_object のオブジェクト割り当て数を追跡できること' do
      result = described_class.track_object_allocations

      expect(result[:array_map_allocations]).to be_a(Integer)
      expect(result[:each_with_object_allocations]).to be_a(Integer)
      # 両方とも何かしらのオブジェクトを割り当てていること
      expect(result[:array_map_allocations]).to be_positive
      expect(result[:each_with_object_allocations]).to be_positive
    end
  end

  describe '.memory_efficient_patterns' do
    it 'frozen_string_literalの効果でリテラル文字列がfreezeされていること' do
      result = described_class.memory_efficient_patterns

      expect(result[:literal_frozen]).to be true
    end

    it 'freezeした同一内容の文字列が同一オブジェクトであること' do
      result = described_class.memory_efficient_patterns

      expect(result[:frozen_same_object]).to be true
    end

    it 'Symbolが同一名で同一オブジェクトであり、freezeされていること' do
      result = described_class.memory_efficient_patterns

      expect(result[:symbol_same_object]).to be true
      expect(result[:symbol_frozen]).to be true
    end

    it 'Symbolキーのハッシュが効率的であること' do
      result = described_class.memory_efficient_patterns

      expect(result[:symbol_hash_allocations]).to be_a(Integer)
      expect(result[:string_hash_allocations]).to be_a(Integer)
      expect(result[:symbol_hash_more_efficient]).to be true
    end
  end

  describe '.demonstrate_object_promotion' do
    it 'GCを複数回実行するとオブジェクトが旧世代に昇格すること' do
      result = described_class.demonstrate_object_promotion

      expect(result[:old_objects_before]).to be_a(Integer)
      expect(result[:old_objects_after]).to be_a(Integer)
      expect(result[:objects_promoted]).to be true
      expect(result[:long_lived_count]).to eq(1_000)
    end
  end

  describe '.demonstrate_gc_control' do
    it 'GCの有効化・無効化を安全に制御できること' do
      result = described_class.demonstrate_gc_control

      # GCが最終的に再有効化されていること
      expect(result[:gc_re_enabled]).to be true

      # GC無効化中にもオブジェクトが割り当てられていること
      expect(result[:allocations_during_gc_disabled]).to be_positive

      # GC.startのオプション説明が含まれること
      expect(result[:gc_start_options]).to include(:full_mark, :immediate_sweep)
    end
  end
end
