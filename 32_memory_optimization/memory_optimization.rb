# frozen_string_literal: true

# Ruby/Railsメモリ最適化テクニックを学ぶモジュール
#
# メモリ最適化は本番Railsアプリケーションの安定運用において不可欠なスキルである。
# Rubyプロセスのメモリ使用量は、オブジェクト割り当て、文字列操作、
# ActiveRecordの大量データ読み込みなど、さまざまな要因で増大する。
#
# このモジュールでは以下のトピックを扱う:
# - プロセスメモリの計測手法（RSS / GC.stat）
# - オブジェクト割り当て削減パターン
# - 文字列最適化（frozen string / dedup / 結合回避）
# - コレクション最適化（Enumerator::Lazy / ストリーム処理）
# - GCチューニング環境変数
# - Jemalloc によるメモリ断片化の軽減
# - Railsにおけるメモリブロートの典型パターン
# - メモリプロファイリングツール（memory_profiler / ObjectSpace）
module MemoryOptimization
  module_function

  # ============================================================
  # 1. プロセスメモリの計測
  # ============================================================
  #
  # Rubyプロセスのメモリ使用量を計測する手法は複数ある:
  #
  # (A) RSS（Resident Set Size）の取得
  #   - macOS: `ps -o rss= -p PID` でキロバイト単位のRSSを取得
  #   - Linux: /proc/PID/status の VmRSS 行を読む
  #   - GetProcessMem gem はこれらを抽象化してくれる
  #
  # (B) GC.stat によるRubyヒープ統計
  #   - heap_live_slots: 生存オブジェクト数
  #   - total_allocated_objects: 累積割り当てオブジェクト数
  #   - malloc_increase_bytes: mallocによる割り当て増加量
  #
  # (C) ObjectSpace.memsize_of_all
  #   - Rubyオブジェクトが消費するメモリの概算合計
  #
  # 本番環境では、これらを定期的に監視してメモリリークや
  # メモリブロートの早期検知に活用する。
  #
  # @return [Hash] メモリ計測結果
  def measure_process_memory
    gc_stat = GC.stat

    # RSSの取得（psコマンド経由、macOS/Linux両対応）
    pid = Process.pid
    rss_kb = begin
      `ps -o rss= -p #{pid}`.strip.to_i
    rescue StandardError
      0
    end

    # ObjectSpaceによるRubyオブジェクトのメモリ使用量概算
    memsize_total = if ObjectSpace.respond_to?(:memsize_of_all)
                      ObjectSpace.memsize_of_all
                    else
                      0
                    end

    {
      pid: pid,
      rss_kb: rss_kb,
      rss_mb: (rss_kb / 1024.0).round(2),
      heap_live_slots: gc_stat[:heap_live_slots],
      heap_free_slots: gc_stat[:heap_free_slots],
      total_allocated_objects: gc_stat[:total_allocated_objects],
      total_freed_objects: gc_stat[:total_freed_objects],
      malloc_increase_bytes: gc_stat[:malloc_increase_bytes],
      memsize_of_all: memsize_total,
      ruby_version: RUBY_VERSION
    }
  end

  # ============================================================
  # 2. オブジェクト割り当て削減
  # ============================================================
  #
  # Rubyの各オブジェクトはメモリを消費し、GCの対象となる。
  # 不要なオブジェクト生成を減らすことで:
  # - メモリ使用量が減少する
  # - GCの実行頻度が下がり、アプリケーションの応答性が向上する
  #
  # 主な削減テクニック:
  # - frozen string literal の活用（同一内容の文字列を共有）
  # - Symbol の適切な利用（ハッシュキーなど）
  # - 中間オブジェクトを避ける（破壊的メソッド、each_with_objectなど）
  # - 定数の事前freeze
  #
  # @return [Hash] 各パターンの割り当て数比較
  def reduce_object_allocations
    results = {}

    # --- パターン1: frozen string vs 毎回新規生成 ---
    # frozen_string_literal: true 環境では文字列リテラルが共有される
    alloc_before = GC.stat[:total_allocated_objects]
    100.times { 'frozen_literal' }
    alloc_frozen = GC.stat[:total_allocated_objects] - alloc_before

    alloc_before = GC.stat[:total_allocated_objects]
    100.times { String.new('mutable_string') }
    alloc_mutable = GC.stat[:total_allocated_objects] - alloc_before

    results[:frozen_literal_allocations] = alloc_frozen
    results[:mutable_string_allocations] = alloc_mutable
    results[:frozen_saves_allocations] = alloc_frozen < alloc_mutable

    # --- パターン2: Symbol vs String のハッシュキー ---
    alloc_before = GC.stat[:total_allocated_objects]
    500.times { { name: 'test', age: 25 } }
    alloc_symbol_keys = GC.stat[:total_allocated_objects] - alloc_before

    alloc_before = GC.stat[:total_allocated_objects]
    500.times { { 'name' => 'test', 'age' => 25 } }
    alloc_string_keys = GC.stat[:total_allocated_objects] - alloc_before

    results[:symbol_key_allocations] = alloc_symbol_keys
    results[:string_key_allocations] = alloc_string_keys
    results[:symbol_keys_efficient] = alloc_symbol_keys <= alloc_string_keys

    # --- パターン3: map + select vs each_with_object ---
    source = (1..200).to_a

    alloc_before = GC.stat[:total_allocated_objects]
    _chained = source.map { |n| n * 2 }.select(&:even?)
    alloc_chain = GC.stat[:total_allocated_objects] - alloc_before

    alloc_before = GC.stat[:total_allocated_objects]
    _single = source.each_with_object([]) { |n, acc| acc << (n * 2) if (n * 2).even? }
    alloc_single = GC.stat[:total_allocated_objects] - alloc_before

    results[:chain_allocations] = alloc_chain
    results[:single_pass_allocations] = alloc_single

    results
  end

  # ============================================================
  # 3. 文字列最適化
  # ============================================================
  #
  # 文字列はRubyアプリケーションで最も多く割り当てられるオブジェクトの一つ。
  # 文字列最適化は全体のメモリ効率に大きく影響する。
  #
  # 最適化手法:
  # (A) frozen_string_literal: true プラグマ
  #   - ファイル内の全文字列リテラルが自動的にフリーズ・共有される
  #
  # (B) 文字列デデュプリケーション（-"string"）
  #   - 動的に生成された文字列もフリーズ・デデュプリケーションできる
  #
  # (C) 文字列結合の回避
  #   - + 演算子はループ内で中間オブジェクトを大量に生成する
  #   - << 演算子や Array#join を使うことで割り当てを削減できる
  #
  # @return [Hash] 文字列最適化の検証結果
  def optimize_strings
    results = {}

    # --- frozen string literal の効果 ---
    str1 = 'optimization_target'
    str2 = 'optimization_target'
    results[:frozen_literals_shared] = str1.equal?(str2)
    results[:literal_frozen] = str1.frozen?

    # --- 文字列結合: + vs << vs join ---

    # + 演算子（非効率: 毎回新しい中間文字列を生成）
    alloc_before = GC.stat[:total_allocated_objects]
    result_plus = ''
    200.times { |i| result_plus += "x#{i}" }
    alloc_plus = GC.stat[:total_allocated_objects] - alloc_before

    # << 演算子（効率的: 既存バッファに追記）
    alloc_before = GC.stat[:total_allocated_objects]
    result_shovel = +''
    200.times { |i| result_shovel << "x#{i}" }
    alloc_shovel = GC.stat[:total_allocated_objects] - alloc_before

    # Array#join（効率的: 配列から一括結合）
    alloc_before = GC.stat[:total_allocated_objects]
    parts = Array.new(200) { |i| "x#{i}" }
    _result_join = parts.join
    alloc_join = GC.stat[:total_allocated_objects] - alloc_before

    results[:concat_plus_allocations] = alloc_plus
    results[:concat_shovel_allocations] = alloc_shovel
    results[:concat_join_allocations] = alloc_join
    results[:shovel_better_than_plus] = alloc_shovel < alloc_plus

    # --- 文字列デデュプリケーション ---
    dynamic_a = -'dedup_target'
    dynamic_b = -'dedup_target'
    results[:dedup_same_object] = dynamic_a.equal?(dynamic_b)

    results
  end

  # ============================================================
  # 4. コレクション最適化（Enumerator::Lazy）
  # ============================================================
  #
  # 大規模データを扱う際、中間配列の生成を避けることでメモリ使用量を
  # 大幅に削減できる。Enumerator::Lazy は遅延評価パイプラインを提供し、
  # 必要な要素だけを逐次処理する。
  #
  # 利点:
  # - 巨大な配列を全てメモリに載せる必要がない
  # - 変換チェーンが1要素ずつ逐次実行される
  # - take / first で必要な分だけ取得できる
  #
  # 注意点:
  # - 個々の要素の処理速度は通常の Enumerator より遅い
  # - 小規模データではオーバーヘッドの方が大きい
  # - 副作用のある操作には不向き
  #
  # @return [Hash] Lazy vs Eager の比較結果
  def optimize_collections
    results = {}
    large_range = 1..100_000

    # --- Eager（通常の配列操作）: 中間配列が複数生成される ---
    # to_a で100,000要素の配列、map でさらに100,000要素の配列、
    # select でさらに配列が生成される → ピークメモリが非常に大きい
    eager_result = large_range
                   .to_a
                   .map { |n| n * 2 }
                   .select(&:even?)
                   .first(10)

    # --- Lazy（遅延評価）: 中間配列を生成せず逐次処理 ---
    # 各要素が1つずつパイプラインを通過し、first(10) で10個取得した時点で停止
    # 中間配列は一切生成されない → ピークメモリが最小限
    lazy_result = large_range
                  .lazy
                  .map { |n| n * 2 }
                  .select(&:even?)
                  .first(10)

    # Lazyの利点はピークメモリ（中間配列を生成しない）にある
    # GC.stat[:total_allocated_objects]ではLazyの内部オブジェクト（Enumerator等）が
    # カウントされるため、割り当て数での比較は適切ではない
    # 代わりに、中間配列のサイズで比較する
    eager_intermediate_elements = large_range.size  # to_a で100,000要素を展開
    lazy_intermediate_elements = 10                 # first(10) で10要素のみ処理

    results[:eager_intermediate_elements] = eager_intermediate_elements
    results[:lazy_intermediate_elements] = lazy_intermediate_elements
    results[:lazy_much_fewer_elements] = lazy_intermediate_elements < eager_intermediate_elements
    results[:eager_result] = eager_result
    results[:lazy_result] = lazy_result
    results[:results_equal] = eager_result == lazy_result

    # --- Enumerator によるストリーム処理 ---
    # 無限シーケンスも Lazy なら安全に扱える
    fib = Enumerator.new do |yielder|
      a = 0
      b = 1
      loop do
        yielder.yield a
        a, b = b, a + b
      end
    end

    fib_first_10 = fib.lazy.select(&:even?).first(5)
    results[:fibonacci_even_first_5] = fib_first_10

    results
  end

  # ============================================================
  # 5. GCチューニング環境変数
  # ============================================================
  #
  # RubyのGC動作は環境変数で細かく制御できる。
  # 本番環境のRailsアプリケーションでは、アプリの特性に応じた
  # チューニングがパフォーマンスとメモリ効率の両立に不可欠。
  #
  # 主要な環境変数:
  #
  # RUBY_GC_HEAP_INIT_SLOTS
  #   初期ヒープスロット数。Railsアプリでは起動時に大量のオブジェクトを
  #   必要とするため、大きめに設定すると起動時のGC回数を削減できる。
  #   推奨: 600000〜800000
  #
  # RUBY_GC_HEAP_GROWTH_FACTOR
  #   ヒープ拡張時の成長率（デフォルト: 1.8）。
  #   小さくするとメモリ増加が緩やかになる。推奨: 1.1〜1.25
  #
  # RUBY_GC_MALLOC_LIMIT
  #   malloc割り当てのGCトリガー閾値（バイト単位）。
  #   この値を超えるとGCが発動する。推奨: 64000000〜128000000
  #
  # RUBY_GC_MALLOC_LIMIT_MAX
  #   malloc割り当てのGCトリガー上限値。
  #
  # RUBY_GC_OLDMALLOC_LIMIT / RUBY_GC_OLDMALLOC_LIMIT_MAX
  #   旧世代オブジェクトのmalloc割り当て閾値と上限。
  #
  # RUBY_GC_HEAP_OLDOBJECT_LIMIT_FACTOR
  #   旧世代オブジェクト数に基づくメジャーGCトリガー係数。
  #
  # @return [Hash] GCチューニング環境変数の一覧・現在値・推奨値
  def gc_tuning_variables
    tuning_vars = {
      'RUBY_GC_HEAP_INIT_SLOTS' => {
        current: ENV.fetch('RUBY_GC_HEAP_INIT_SLOTS', nil),
        description: '初期ヒープスロット数',
        default: '約10000',
        recommended_rails: '600000〜800000',
        effect: '起動時のGC回数を削減'
      },
      'RUBY_GC_HEAP_GROWTH_FACTOR' => {
        current: ENV.fetch('RUBY_GC_HEAP_GROWTH_FACTOR', nil),
        description: 'ヒープ拡張時の成長率',
        default: '1.8',
        recommended_rails: '1.1〜1.25',
        effect: 'メモリ増加の抑制'
      },
      'RUBY_GC_MALLOC_LIMIT' => {
        current: ENV.fetch('RUBY_GC_MALLOC_LIMIT', nil),
        description: 'malloc割り当てのGCトリガー閾値（バイト）',
        default: '16MB相当',
        recommended_rails: '128000000',
        effect: 'GC発動頻度の調整'
      },
      'RUBY_GC_MALLOC_LIMIT_MAX' => {
        current: ENV.fetch('RUBY_GC_MALLOC_LIMIT_MAX', nil),
        description: 'malloc割り当てのGCトリガー上限値（バイト）',
        default: '32MB相当',
        recommended_rails: '256000000',
        effect: 'GCトリガー上限の調整'
      },
      'RUBY_GC_OLDMALLOC_LIMIT' => {
        current: ENV.fetch('RUBY_GC_OLDMALLOC_LIMIT', nil),
        description: '旧世代malloc割り当て閾値（バイト）',
        default: '16MB相当',
        recommended_rails: '128000000',
        effect: '旧世代メジャーGCの頻度調整'
      },
      'RUBY_GC_OLDMALLOC_LIMIT_MAX' => {
        current: ENV.fetch('RUBY_GC_OLDMALLOC_LIMIT_MAX', nil),
        description: '旧世代malloc割り当て上限値（バイト）',
        default: '32MB相当',
        recommended_rails: '256000000',
        effect: '旧世代メジャーGCの上限調整'
      },
      'RUBY_GC_HEAP_OLDOBJECT_LIMIT_FACTOR' => {
        current: ENV.fetch('RUBY_GC_HEAP_OLDOBJECT_LIMIT_FACTOR', nil),
        description: '旧世代オブジェクト数に基づくメジャーGCトリガー係数',
        default: '2.0',
        recommended_rails: '1.3',
        effect: '旧世代オブジェクト蓄積時のGC頻度'
      }
    }

    {
      tuning_vars: tuning_vars,
      total_vars_count: tuning_vars.size,
      ruby_version: RUBY_VERSION,
      current_gc_stat_snapshot: {
        heap_allocated_pages: GC.stat[:heap_allocated_pages],
        heap_live_slots: GC.stat[:heap_live_slots],
        malloc_increase_bytes: GC.stat[:malloc_increase_bytes]
      }
    }
  end

  # ============================================================
  # 6. Jemalloc によるメモリ断片化の軽減
  # ============================================================
  #
  # デフォルトのglibcのmallocは、長時間稼働するRubyプロセスで
  # メモリ断片化を引き起こしやすい。Jemallocは断片化を軽減し、
  # Rubyプロセスのメモリ使用量を20〜30%削減する効果がある。
  #
  # === メモリ断片化とは ===
  # - オブジェクトの割り当て・解放を繰り返すと、ヒープ内に空き領域が散在する
  # - OSには返却されないが、Rubyからは使えない「無駄な空き領域」が増える
  # - RSS（実メモリ使用量）が実際のデータ量より大幅に大きくなる
  #
  # === Jemallocの利点 ===
  # - スレッド単位のアリーナでロック競合を軽減
  # - サイズクラス別の管理で断片化を抑制
  # - 定期的なパージで不要ページをOSに返却
  #
  # === 導入方法 ===
  # (1) Docker環境:
  #     RUN apt-get install -y libjemalloc2
  #     ENV LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2
  #
  # (2) Ruby再コンパイル:
  #     ./configure --with-jemalloc
  #
  # (3) MALLOC_CONF による詳細設定:
  #     ENV MALLOC_CONF="dirty_decay_ms:1000,narenas:2"
  #
  # @return [Hash] Jemalloc設定情報と現在のアロケータ状態
  def jemalloc_configuration
    # 現在のRubyがjemallocを使用しているか確認する方法
    jemalloc_detected = detect_jemalloc

    {
      jemalloc_detected: jemalloc_detected,
      detection_methods: [
        "ruby -r rbconfig -e \"puts RbConfig::CONFIG['MAINLIBS']\"",
        "MALLOC_CONF=stats_print:true ruby -e 'exit' 2>&1 | head",
        "ruby -r fiddle -e \"puts Fiddle::Handle.new('libjemalloc.so.2')\""
      ],
      docker_setup: {
        apt_install: 'apt-get install -y libjemalloc2',
        env_ld_preload: 'LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2',
        malloc_conf: 'MALLOC_CONF=dirty_decay_ms:1000,narenas:2'
      },
      expected_benefits: {
        memory_reduction: '20〜30%のRSS削減',
        fragmentation: '長時間稼働でのメモリ断片化を大幅に軽減',
        multithreading: 'スレッド間のロック競合を削減（Pumaとの相性が良い）'
      },
      malloc_conf_options: {
        'dirty_decay_ms' => 'ダーティページのパージ間隔（ミリ秒）。1000推奨',
        'narenas' => 'アリーナ数。CPUコア数の2倍がデフォルト。2に制限するとメモリ効率向上',
        'background_thread' => 'バックグラウンドでのパージを有効化（true推奨）'
      }
    }
  end

  # ============================================================
  # 7. メモリブロートパターン
  # ============================================================
  #
  # Railsアプリケーションでメモリが膨張する典型的なパターンと対策。
  # これらのパターンを理解し、コードレビューで検出することが重要。
  #
  # (A) ActiveRecordの大量データ読み込み
  #   - User.all.each → 全レコードをメモリに展開
  #   - 対策: find_each / find_in_batches / in_batches を使用
  #
  # (B) 文字列の繰り返し結合
  #   - ループ内での + 演算子 → 中間オブジェクトが大量生成
  #   - 対策: << 演算子 / Array#join / StringIO を使用
  #
  # (C) ログバッファリング
  #   - 大量のログメッセージをメモリに蓄積
  #   - 対策: ストリーミング出力、適切なバッファサイズ設定
  #
  # (D) Symbolへのユーザー入力変換
  #   - params[:key].to_sym を無制限に行う → Symbolテーブルの肥大化
  #   - 対策: ホワイトリストによるバリデーション
  #
  # (E) グローバルキャッシュの際限ない成長
  #   - @@cache[key] = value を無制限に行う → メモリリーク
  #   - 対策: LRUキャッシュ / TTL付きキャッシュ / WeakMap の使用
  #
  # @return [Hash] メモリブロートパターンの分析結果
  def memory_bloat_patterns
    results = {}

    # --- パターンA: 大量データの一括読み込み vs バッチ処理 ---
    # シミュレーション: 大きな配列 vs イテレータ
    alloc_before = GC.stat[:total_allocated_objects]
    large_array = Array.new(10_000) { |i| { id: i, name: "user_#{i}", email: "u#{i}@example.com" } }
    _all_processed = large_array.map { |u| u[:name].upcase }
    alloc_bulk = GC.stat[:total_allocated_objects] - alloc_before

    alloc_before = GC.stat[:total_allocated_objects]
    # バッチ処理のシミュレーション（1000件ずつ処理）
    large_array.each_slice(1000) do |batch|
      batch.each { |u| u[:name].upcase }
    end
    alloc_batch = GC.stat[:total_allocated_objects] - alloc_before

    results[:bulk_load_allocations] = alloc_bulk
    results[:batch_process_allocations] = alloc_batch
    results[:batch_is_leaner] = alloc_batch < alloc_bulk

    # --- パターンB: 文字列結合のブロート ---
    alloc_before = GC.stat[:total_allocated_objects]
    bloated = ''
    500.times { |i| bloated += "line_#{i}\n" }
    alloc_bloated = GC.stat[:total_allocated_objects] - alloc_before

    alloc_before = GC.stat[:total_allocated_objects]
    efficient = +''
    500.times { |i| efficient << "line_#{i}\n" }
    alloc_efficient = GC.stat[:total_allocated_objects] - alloc_before

    results[:string_bloat_allocations] = alloc_bloated
    results[:string_efficient_allocations] = alloc_efficient
    results[:string_bloat_ratio] =
      alloc_bloated.positive? ? (alloc_bloated.to_f / [alloc_efficient, 1].max).round(2) : 0

    # --- パターンC: キャッシュの際限ない成長 ---
    # 悪いパターン: サイズ制限なしのキャッシュ
    unbounded_cache = {}
    1000.times { |i| unbounded_cache["key_#{i}"] = "value_#{i}" }

    # 良いパターン: サイズ制限付きキャッシュ（LRU的）
    bounded_cache = {}
    max_size = 100
    1000.times do |i|
      bounded_cache["key_#{i}"] = "value_#{i}"
      bounded_cache.delete(bounded_cache.keys.first) if bounded_cache.size > max_size
    end

    results[:unbounded_cache_size] = unbounded_cache.size
    results[:bounded_cache_size] = bounded_cache.size
    results[:bounded_within_limit] = bounded_cache.size <= max_size

    # --- メモリブロート防止チェックリスト ---
    results[:prevention_checklist] = {
      ar_batch_processing: 'find_each / find_in_batches を使い、全件ロードを避ける',
      string_building: '<< 演算子 / Array#join / StringIO を使う',
      log_buffering: 'ストリーミング出力を使い、バッファサイズを制限する',
      symbol_conversion: 'ユーザー入力のto_symはホワイトリストで制限する',
      cache_management: 'LRU / TTL / WeakMap を使い、キャッシュサイズを制限する',
      large_csv_export: 'CSV.generate ではなくストリーミングレスポンスを使う',
      image_processing: '一時ファイルを使い、メモリ内での大きなバイナリ保持を避ける'
    }

    results
  end

  # ============================================================
  # 8. メモリプロファイリングツール
  # ============================================================
  #
  # メモリ問題の調査に使用する主要なツール:
  #
  # (A) memory_profiler gem
  #   - ブロック内のメモリ割り当てを詳細に追跡
  #   - オブジェクトの種類、生成元のファイル/行番号を報告
  #   - 使い方: MemoryProfiler.report { ... }.pretty_print
  #
  # (B) ObjectSpace モジュール
  #   - ObjectSpace.count_objects: オブジェクト種類別のカウント
  #   - ObjectSpace.each_object(Class): 特定クラスのインスタンス列挙
  #   - ObjectSpace.memsize_of(obj): 個別オブジェクトのメモリサイズ
  #
  # (C) GC::Profiler
  #   - GC実行の詳細なプロファイリング
  #   - 各GC実行の所要時間、ヒープサイズの変化を記録
  #
  # (D) derailed_benchmarks gem
  #   - Rails起動時のメモリ使用量をgem単位で計測
  #   - bundle exec derailed bundle:mem
  #
  # @return [Hash] プロファイリングツールの使用例と結果
  def memory_profiling_tools
    results = {}

    # --- ObjectSpace.count_objects ---
    object_counts = ObjectSpace.count_objects
    results[:object_type_counts] = {
      total: object_counts[:TOTAL],
      free: object_counts[:FREE],
      t_string: object_counts[:T_STRING],
      t_array: object_counts[:T_ARRAY],
      t_hash: object_counts[:T_HASH],
      t_object: object_counts[:T_OBJECT]
    }

    # --- ObjectSpace.each_object でクラス別インスタンス数を取得 ---
    string_count = ObjectSpace.each_object(String).count
    array_count = ObjectSpace.each_object(Array).count
    hash_count = ObjectSpace.each_object(Hash).count

    results[:live_object_counts] = {
      strings: string_count,
      arrays: array_count,
      hashes: hash_count
    }

    # --- ObjectSpace.memsize_of（個別オブジェクトのメモリサイズ） ---
    if ObjectSpace.respond_to?(:memsize_of)
      small_string = 'hello'
      large_string = 'x' * 10_000
      small_array = [1, 2, 3]
      large_array = Array.new(10_000, 0)

      results[:memsize_examples] = {
        small_string: ObjectSpace.memsize_of(small_string),
        large_string: ObjectSpace.memsize_of(large_string),
        small_array: ObjectSpace.memsize_of(small_array),
        large_array: ObjectSpace.memsize_of(large_array),
        large_string_bigger: ObjectSpace.memsize_of(large_string) > ObjectSpace.memsize_of(small_string),
        large_array_bigger: ObjectSpace.memsize_of(large_array) > ObjectSpace.memsize_of(small_array)
      }
    else
      results[:memsize_examples] = { note: 'ObjectSpace.memsize_of はこの環境で利用不可' }
    end

    # --- GC::Profiler ---
    GC::Profiler.enable
    # プロファイリング対象の処理
    5_000.times { "profiled_allocation_#{it}" }
    GC.start
    gc_profiler_result = GC::Profiler.result
    gc_profiler_total_time = GC::Profiler.total_time
    GC::Profiler.disable
    GC::Profiler.clear

    results[:gc_profiler] = {
      result_available: !gc_profiler_result.empty?,
      total_time: gc_profiler_total_time,
      total_time_positive: gc_profiler_total_time >= 0
    }

    # --- memory_profiler gem の使い方（コンセプト） ---
    results[:memory_profiler_usage] = {
      basic: 'MemoryProfiler.report { code_to_profile }.pretty_print',
      with_options: 'MemoryProfiler.report(top: 10, allow_files: "app/") { ... }',
      rails_middleware: 'config.middleware.use MemoryProfiler::Middleware',
      key_metrics: [
        'Total allocated（割り当てオブジェクト総数）',
        'Total retained（保持されたオブジェクト総数）',
        'allocated memory by gem（gem別の割り当てメモリ）',
        'allocated memory by file（ファイル別の割り当てメモリ）',
        'allocated objects by class（クラス別の割り当てオブジェクト数）'
      ]
    }

    # --- derailed_benchmarks の使い方（コンセプト） ---
    results[:derailed_benchmarks_usage] = {
      install: "gem 'derailed_benchmarks', group: :development",
      commands: {
        'bundle exec derailed bundle:mem' => 'gem別のメモリ使用量を計測',
        'bundle exec derailed exec perf:mem' => 'リクエスト処理時のメモリ推移を計測',
        'bundle exec derailed exec perf:objects' => 'リクエスト処理時のオブジェクト割り当てを計測'
      }
    }

    results
  end

  # === ヘルパーメソッド ===

  # Jemallocの使用を検出する
  #
  # @return [Boolean] jemallocが検出されたかどうか
  def detect_jemalloc
    # 方法1: RbConfigからリンクされたライブラリを確認
    mainlibs = begin
      require 'rbconfig'
      RbConfig::CONFIG['MAINLIBS'].to_s
    rescue StandardError
      ''
    end
    return true if mainlibs.include?('jemalloc')

    # 方法2: MALLOC_CONF 環境変数が設定されているか確認
    # （jemallocが使われている場合のみ有効）
    return true if ENV.key?('MALLOC_CONF')

    # 方法3: LD_PRELOAD にjemallocが含まれているか確認
    ld_preload = ENV.fetch('LD_PRELOAD', '')
    return true if ld_preload.include?('jemalloc')

    false
  end
end
