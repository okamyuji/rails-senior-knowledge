# frozen_string_literal: true

require_relative 'memory_optimization'

RSpec.describe MemoryOptimization do
  describe '.measure_process_memory' do
    it 'プロセスメモリの計測結果を返し、主要な指標が含まれること' do # rubocop:disable RSpec/MultipleExpectations
      result = described_class.measure_process_memory

      expect(result[:pid]).to eq(Process.pid)
      expect(result[:rss_kb]).to be_a(Integer)
      expect(result[:rss_mb]).to be_a(Float)
      expect(result[:heap_live_slots]).to be_a(Integer)
      expect(result[:heap_live_slots]).to be_positive
      expect(result[:heap_free_slots]).to be_a(Integer)
      expect(result[:total_allocated_objects]).to be_a(Integer)
      expect(result[:total_allocated_objects]).to be_positive
      expect(result[:total_freed_objects]).to be_a(Integer)
      expect(result[:malloc_increase_bytes]).to be_a(Integer)
      expect(result[:ruby_version]).to eq(RUBY_VERSION)
    end
  end

  describe '.reduce_object_allocations' do
    it 'frozen literalがミュータブル文字列より割り当てが少ないこと' do
      result = described_class.reduce_object_allocations

      expect(result[:frozen_literal_allocations]).to be_a(Integer)
      expect(result[:mutable_string_allocations]).to be_a(Integer)
      expect(result[:frozen_saves_allocations]).to be true
    end

    it 'Symbolキーのハッシュが効率的であること' do
      result = described_class.reduce_object_allocations

      expect(result[:symbol_key_allocations]).to be_a(Integer)
      expect(result[:string_key_allocations]).to be_a(Integer)
      expect(result[:symbol_keys_efficient]).to be true
    end

    it 'メソッドチェーンとsingle passの割り当て数を追跡できること' do
      result = described_class.reduce_object_allocations

      expect(result[:chain_allocations]).to be_a(Integer)
      expect(result[:chain_allocations]).to be_positive
      expect(result[:single_pass_allocations]).to be_a(Integer)
      expect(result[:single_pass_allocations]).to be_positive
    end
  end

  describe '.optimize_strings' do
    it 'frozen string literalが同一オブジェクトを共有すること' do
      result = described_class.optimize_strings

      expect(result[:frozen_literals_shared]).to be true
      expect(result[:literal_frozen]).to be true
    end

    it '<< 演算子が + 演算子より効率的であること' do
      result = described_class.optimize_strings

      expect(result[:concat_plus_allocations]).to be_a(Integer)
      expect(result[:concat_shovel_allocations]).to be_a(Integer)
      expect(result[:shovel_better_than_plus]).to be true
    end

    it '文字列デデュプリケーションが同一オブジェクトを返すこと' do
      result = described_class.optimize_strings

      expect(result[:dedup_same_object]).to be true
    end
  end

  describe '.optimize_collections' do
    it 'Lazyが通常の配列操作よりピークメモリ効率が良いこと' do
      result = described_class.optimize_collections

      # Lazyは中間配列を生成しないため、処理する要素数が大幅に少ない
      expect(result[:eager_intermediate_elements]).to eq(100_000)
      expect(result[:lazy_intermediate_elements]).to eq(10)
      expect(result[:lazy_much_fewer_elements]).to be true
    end

    it 'EagerとLazyの結果が一致すること' do
      result = described_class.optimize_collections

      expect(result[:results_equal]).to be true
      expect(result[:eager_result]).to eq(result[:lazy_result])
      expect(result[:eager_result].size).to eq(10)
    end

    it '無限シーケンスからLazyで偶数フィボナッチ数を取得できること' do
      result = described_class.optimize_collections

      expect(result[:fibonacci_even_first_5]).to be_an(Array)
      expect(result[:fibonacci_even_first_5].size).to eq(5)
      expect(result[:fibonacci_even_first_5]).to all(be_even)
    end
  end

  describe '.gc_tuning_variables' do
    it '全GCチューニング環境変数の情報を返すこと' do
      result = described_class.gc_tuning_variables

      expect(result[:tuning_vars]).to be_a(Hash)
      expect(result[:total_vars_count]).to eq(7)
      expect(result[:ruby_version]).to eq(RUBY_VERSION)

      # 主要な環境変数が含まれていること
      expect(result[:tuning_vars]).to include(
        'RUBY_GC_HEAP_INIT_SLOTS',
        'RUBY_GC_HEAP_GROWTH_FACTOR',
        'RUBY_GC_MALLOC_LIMIT',
        'RUBY_GC_MALLOC_LIMIT_MAX',
        'RUBY_GC_OLDMALLOC_LIMIT',
        'RUBY_GC_OLDMALLOC_LIMIT_MAX',
        'RUBY_GC_HEAP_OLDOBJECT_LIMIT_FACTOR'
      )
    end

    it '各変数にdescriptionとrecommended_railsが含まれること' do
      result = described_class.gc_tuning_variables

      result[:tuning_vars].each_value do |info|
        expect(info).to include(:description, :recommended_rails, :effect)
      end
    end

    it '現在のGC統計スナップショットが含まれること' do
      result = described_class.gc_tuning_variables

      snapshot = result[:current_gc_stat_snapshot]
      expect(snapshot[:heap_allocated_pages]).to be_a(Integer)
      expect(snapshot[:heap_live_slots]).to be_positive
    end
  end

  describe '.jemalloc_configuration' do
    it 'Jemalloc設定情報と検出メソッドを返すこと' do
      result = described_class.jemalloc_configuration

      expect(result[:jemalloc_detected]).to be(true).or be(false)
      expect(result[:detection_methods]).to be_an(Array)
      expect(result[:detection_methods]).not_to be_empty
    end

    it 'Docker環境でのセットアップ手順が含まれること' do
      result = described_class.jemalloc_configuration

      expect(result[:docker_setup]).to include(:apt_install, :env_ld_preload, :malloc_conf)
    end

    it '期待される効果とMALLOC_CONFオプションが含まれること' do
      result = described_class.jemalloc_configuration

      expect(result[:expected_benefits]).to include(:memory_reduction, :fragmentation, :multithreading)
      expect(result[:malloc_conf_options]).to include('dirty_decay_ms', 'narenas', 'background_thread')
    end
  end

  describe '.memory_bloat_patterns' do
    it 'バッチ処理が一括処理よりメモリ効率が良いこと' do
      result = described_class.memory_bloat_patterns

      expect(result[:bulk_load_allocations]).to be_a(Integer)
      expect(result[:batch_process_allocations]).to be_a(Integer)
      expect(result[:batch_is_leaner]).to be true
    end

    it '文字列ブロートの比率を計算できること' do
      result = described_class.memory_bloat_patterns

      expect(result[:string_bloat_allocations]).to be_a(Integer)
      expect(result[:string_efficient_allocations]).to be_a(Integer)
      expect(result[:string_bloat_ratio]).to be > 1.0
    end

    it 'キャッシュサイズの制限が機能していること' do
      result = described_class.memory_bloat_patterns

      expect(result[:unbounded_cache_size]).to eq(1000)
      expect(result[:bounded_cache_size]).to be <= 100
      expect(result[:bounded_within_limit]).to be true
    end

    it 'メモリブロート防止チェックリストが含まれること' do
      result = described_class.memory_bloat_patterns

      checklist = result[:prevention_checklist]
      expect(checklist).to include(
        :ar_batch_processing,
        :string_building,
        :cache_management,
        :symbol_conversion
      )
    end
  end

  describe '.memory_profiling_tools' do
    it 'ObjectSpace.count_objectsによるオブジェクト種類別カウントを返すこと' do
      result = described_class.memory_profiling_tools

      counts = result[:object_type_counts]
      expect(counts[:total]).to be_a(Integer)
      expect(counts[:total]).to be_positive
      expect(counts[:t_string]).to be_a(Integer)
      expect(counts[:t_array]).to be_a(Integer)
      expect(counts[:t_hash]).to be_a(Integer)
    end

    it 'ObjectSpace.each_objectによるライブオブジェクト数を返すこと' do
      result = described_class.memory_profiling_tools

      live = result[:live_object_counts]
      expect(live[:strings]).to be_a(Integer)
      expect(live[:strings]).to be_positive
      expect(live[:arrays]).to be_a(Integer)
      expect(live[:hashes]).to be_a(Integer)
    end

    it 'ObjectSpace.memsize_ofによるサイズ比較が正しいこと' do
      result = described_class.memory_profiling_tools

      skip 'ObjectSpace.memsize_of がこの環境で利用不可' if result[:memsize_examples].key?(:note)

      expect(result[:memsize_examples][:large_string_bigger]).to be true
      expect(result[:memsize_examples][:large_array_bigger]).to be true
    end

    it 'GC::Profilerの結果が取得できること' do
      result = described_class.memory_profiling_tools

      expect(result[:gc_profiler][:result_available]).to be(true).or be(false)
      expect(result[:gc_profiler][:total_time_positive]).to be true
    end

    it 'memory_profilerとderailed_benchmarksの使い方が含まれること' do
      result = described_class.memory_profiling_tools

      expect(result[:memory_profiler_usage]).to include(:basic, :key_metrics)
      expect(result[:memory_profiler_usage][:key_metrics]).to be_an(Array)
      expect(result[:derailed_benchmarks_usage]).to include(:install, :commands)
      expect(result[:derailed_benchmarks_usage][:commands]).to be_a(Hash)
    end
  end
end
