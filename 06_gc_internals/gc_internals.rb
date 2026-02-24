# frozen_string_literal: true

require 'weakref'

# RubyのGC（ガベージコレクション）内部構造を学ぶモジュール
#
# Rubyは世代別GC（Generational GC）を採用しており、
# オブジェクトを「新世代（Young Generation）」と「旧世代（Old Generation）」に分類する。
# 新世代のオブジェクトはマイナーGCで回収され、生き残ったオブジェクトは旧世代に昇格する。
# 旧世代のオブジェクトはメジャーGCでのみ回収される。
#
# このモジュールでは以下のトピックを扱う:
# - 世代別GC（マイナーGC / メジャーGC）
# - GC.stat による統計情報の読み取り
# - GC.compact によるヒープコンパクション（Ruby 3.x）
# - GCチューニング用環境変数
# - 弱参照（WeakRef / ObjectSpace::WeakMap）
# - オブジェクト割り当て追跡
# - メモリ効率の良いパターン
module GcInternals
  module_function

  # === 世代別GC（Generational GC）の基本 ===
  #
  # Rubyの世代別GCでは:
  # - 新しく生成されたオブジェクトは「新世代（Young）」に配置される
  # - マイナーGCは新世代のオブジェクトのみをスキャンする（高速）
  # - マイナーGCを生き残ったオブジェクトは「旧世代（Old）」に昇格する
  # - メジャーGCは全オブジェクトをスキャンする（低速だが完全）
  #
  # マイナーGCの回数はメジャーGCよりも多くなるのが正常な動作である。
  # これにより、短命なオブジェクト（一時変数など）を効率的に回収できる。
  #
  # @return [Hash] マイナーGCとメジャーGCの回数を含む統計情報
  def demonstrate_generational_gc
    # 現在のGC統計を取得
    stat_before = GC.stat

    # 短命なオブジェクトを大量に生成してマイナーGCを誘発する
    # これらのオブジェクトはすぐにスコープを抜けるため、次のGCで回収される
    10_000.times { "temporary_string_#{it}" }

    # GCを明示的に実行（マイナーGCが走る可能性が高い）
    GC.start(full_mark: false) # full_mark: false はマイナーGCを要求

    stat_after_minor = GC.stat

    # メジャーGCを明示的に実行
    GC.start(full_mark: true) # full_mark: true はメジャーGCを要求

    stat_after_major = GC.stat

    {
      minor_gc_before: stat_before[:minor_gc_count],
      minor_gc_after: stat_after_minor[:minor_gc_count],
      major_gc_before: stat_before[:major_gc_count],
      major_gc_after: stat_after_major[:major_gc_count],
      # マイナーGCはメジャーGCより頻繁に発生するのが正常
      minor_more_frequent: stat_after_major[:minor_gc_count] >= stat_after_major[:major_gc_count]
    }
  end

  # === GC.stat の読み方 ===
  #
  # GC.stat はGCの統計情報をハッシュで返す。主要なキー:
  #
  # - heap_live_slots:     現在使用中のヒープスロット数（生存オブジェクト数に近い）
  # - heap_free_slots:     空きヒープスロット数
  # - total_allocated_objects: プロセス起動から割り当てられた全オブジェクト数（累積）
  # - total_freed_objects:     プロセス起動から解放された全オブジェクト数（累積）
  # - minor_gc_count:      マイナーGCの実行回数
  # - major_gc_count:      メジャーGCの実行回数
  # - heap_allocated_pages: 割り当てられたヒープページ数
  # - malloc_increase_bytes: malloc割り当ての増加バイト数
  #
  # @return [Hash] GC統計情報の主要な項目を抜粋したハッシュ
  def read_gc_stats
    stat = GC.stat

    # 主要な統計項目を抜粋して返す
    {
      # ヒープの状態
      heap_live_slots: stat[:heap_live_slots],
      heap_free_slots: stat[:heap_free_slots],
      heap_allocated_pages: stat[:heap_allocated_pages],

      # オブジェクト割り当て統計（累積値）
      total_allocated_objects: stat[:total_allocated_objects],
      total_freed_objects: stat[:total_freed_objects],

      # GC実行回数
      minor_gc_count: stat[:minor_gc_count],
      major_gc_count: stat[:major_gc_count],
      gc_count: stat[:count],

      # 全キーの一覧（デバッグ用）
      available_keys: stat.keys
    }
  end

  # === GC.compact（ヒープコンパクション） ===
  #
  # Ruby 3.x で導入されたGC.compactは、ヒープ内のオブジェクトを
  # 再配置してメモリの断片化を軽減する。
  #
  # メモリ断片化とは:
  # - オブジェクトの割り当てと解放を繰り返すと、ヒープ内に空き領域が散在する
  # - 連続した空き領域が減り、新しいオブジェクトの割り当て効率が低下する
  # - コンパクションにより、生存オブジェクトを詰めて連続した空き領域を確保する
  #
  # 本番環境では、Unicorn/Pumaのワーカー起動時にGC.compactを実行し、
  # CoW（Copy-on-Write）の効率を高める手法が広く使われている。
  #
  # @return [Hash] コンパクション前後のヒープ統計
  def demonstrate_compaction
    # コンパクション前の状態を記録
    GC.stat

    # オブジェクトを大量に生成して一部を解放し、断片化を模倣する
    objects = Array.new(5_000) { "fragmentation_object_#{it}" }
    # 偶数インデックスのオブジェクトを解放（歯抜け状態を作る）
    objects.each_with_index { |_, i| objects[i] = nil if i.even? }

    GC.start

    stat_before_compact = GC.stat

    # ヒープコンパクションを実行
    # GC.compact はRuby 2.7以降で利用可能
    compact_result = if GC.respond_to?(:compact)
                       GC.compact
                     else
                       { note: 'GC.compact はこのRubyバージョンでは利用不可' }
                     end

    stat_after_compact = GC.stat

    {
      compact_available: GC.respond_to?(:compact),
      compact_result: compact_result,
      heap_live_before: stat_before_compact[:heap_live_slots],
      heap_live_after: stat_after_compact[:heap_live_slots],
      heap_pages_before: stat_before_compact[:heap_allocated_pages],
      heap_pages_after: stat_after_compact[:heap_allocated_pages]
    }
  end

  # === GCチューニング用環境変数 ===
  #
  # RubyのGC動作は環境変数で細かく制御できる。
  # 本番環境ではアプリケーションの特性に合わせてチューニングすることが重要。
  #
  # 主要な環境変数:
  #
  # RUBY_GC_HEAP_INIT_SLOTS
  #   - 初期ヒープスロット数（デフォルト: 10000程度）
  #   - Railsアプリでは起動時に大量のオブジェクトが必要なため、
  #     大きめに設定すると起動時のGC回数を削減できる
  #   - 推奨: 600000〜800000（Railsアプリの場合）
  #
  # RUBY_GC_HEAP_GROWTH_FACTOR
  #   - ヒープ拡張時の成長率（デフォルト: 1.8）
  #   - 小さい値にすると、メモリ使用量の増加が緩やかになる
  #   - 推奨: 1.1〜1.25（メモリ制約のある環境）
  #
  # RUBY_GC_MALLOC_LIMIT
  #   - malloc割り当てのGCトリガー閾値（バイト単位）
  #   - この値を超えるとGCが発動する
  #   - 推奨: 64000000〜128000000（64MB〜128MB）
  #
  # RUBY_GC_MALLOC_LIMIT_MAX
  #   - malloc割り当てのGCトリガー上限値
  #
  # RUBY_GC_OLDMALLOC_LIMIT
  #   - 旧世代オブジェクトのmalloc割り当て閾値
  #
  # RUBY_GC_HEAP_OLDOBJECT_LIMIT_FACTOR
  #   - 旧世代オブジェクト数に基づくメジャーGCトリガー係数
  #
  # @return [Hash] 現在のGC関連環境変数の値と推奨設定
  def gc_tuning_env_vars
    env_vars = {
      'RUBY_GC_HEAP_INIT_SLOTS' => {
        current: ENV.fetch('RUBY_GC_HEAP_INIT_SLOTS', nil),
        description: '初期ヒープスロット数',
        recommended_for_rails: '600000'
      },
      'RUBY_GC_HEAP_GROWTH_FACTOR' => {
        current: ENV.fetch('RUBY_GC_HEAP_GROWTH_FACTOR', nil),
        description: 'ヒープ拡張時の成長率',
        recommended_for_rails: '1.25'
      },
      'RUBY_GC_MALLOC_LIMIT' => {
        current: ENV.fetch('RUBY_GC_MALLOC_LIMIT', nil),
        description: 'malloc割り当てのGCトリガー閾値（バイト）',
        recommended_for_rails: '128000000'
      },
      'RUBY_GC_MALLOC_LIMIT_MAX' => {
        current: ENV.fetch('RUBY_GC_MALLOC_LIMIT_MAX', nil),
        description: 'malloc割り当てのGCトリガー上限値（バイト）',
        recommended_for_rails: '256000000'
      },
      'RUBY_GC_OLDMALLOC_LIMIT' => {
        current: ENV.fetch('RUBY_GC_OLDMALLOC_LIMIT', nil),
        description: '旧世代malloc割り当て閾値（バイト）',
        recommended_for_rails: '128000000'
      },
      'RUBY_GC_HEAP_OLDOBJECT_LIMIT_FACTOR' => {
        current: ENV.fetch('RUBY_GC_HEAP_OLDOBJECT_LIMIT_FACTOR', nil),
        description: '旧世代オブジェクト数に基づくメジャーGCトリガー係数',
        recommended_for_rails: '1.3'
      }
    }

    {
      env_vars: env_vars,
      ruby_version: RUBY_VERSION,
      # 現在のGC設定の一部を取得
      current_gc_params: extract_gc_params
    }
  end

  # GC関連パラメータを安全に取得する
  #
  # @return [Hash] 取得可能なGCパラメータ
  def extract_gc_params
    stat = GC.stat
    {
      heap_allocated_pages: stat[:heap_allocated_pages],
      heap_live_slots: stat[:heap_live_slots],
      total_allocated_objects: stat[:total_allocated_objects]
    }
  end

  # === 弱参照（WeakRef / ObjectSpace::WeakMap） ===
  #
  # 弱参照は、オブジェクトへの参照を保持しつつ、GCによる回収を妨げない仕組み。
  # キャッシュの実装で特に有用:
  # - 通常の参照: オブジェクトがGCされない（メモリリークの原因になる）
  # - 弱参照: GCが必要と判断すれば回収される（メモリに優しい）
  #
  # WeakRef:
  #   単一オブジェクトへの弱参照。参照先がGCされると WeakRef::RefError が発生する。
  #
  # ObjectSpace::WeakMap:
  #   キーまたは値が弱参照のマップ。GCされたエントリは自動的に消える。
  #   キャッシュの実装に最適。
  #
  # @return [Hash] 弱参照のデモ結果
  def demonstrate_weak_references
    results = {}

    # --- WeakRef のデモ ---
    # 文字列オブジェクトを生成して弱参照を作る
    original = +'This is a mutable string for WeakRef demo'
    weak = WeakRef.new(original)

    # 弱参照が有効な間はオブジェクトにアクセスできる
    results[:weakref_alive] = weak.weakref_alive?
    results[:weakref_value] = weak.to_s

    # --- ObjectSpace::WeakMap のデモ ---
    weak_map = ObjectSpace::WeakMap.new
    live_keys = []

    # WeakMapにエントリを追加
    5.times do |i|
      key = "cache_key_#{i}"
      value = "cached_value_#{i}"
      weak_map[key] = value
      # 偶数のキーだけ強参照を保持する
      live_keys << key if i.even?
    end

    results[:weak_map_type] = weak_map.class.name
    results[:weak_map_supports_each] = weak_map.respond_to?(:each)

    # 強参照を保持しているオブジェクトへのアクセスは可能
    results[:live_key_accessible] = begin
      weak_map[live_keys.first]
      true
    rescue StandardError
      false
    end

    # WeakMapはGCフレンドリーなキャッシュとして機能する
    results[:original_still_alive] = weak.weakref_alive?

    results
  end

  # === オブジェクト割り当て追跡 ===
  #
  # GC.statを使ってコードブロック実行前後のオブジェクト割り当て数を比較することで、
  # どの処理がどれだけのオブジェクトを生成しているかを把握できる。
  #
  # 本番環境でのパフォーマンス調査では、この手法を使って
  # 過剰なオブジェクト生成を特定し、最適化の対象を見つける。
  #
  # @return [Hash] 各処理パターンのオブジェクト割り当て数の比較
  def track_object_allocations
    results = {}

    # パターン1: 文字列結合（+演算子）- 中間オブジェクトが多数生成される
    alloc_before = GC.stat[:total_allocated_objects]
    result = ''
    100.times { |i| result += "item_#{i} " }
    alloc_string_concat = GC.stat[:total_allocated_objects] - alloc_before
    results[:string_concat_allocations] = alloc_string_concat

    # パターン2: 文字列結合（<<演算子）- 既存オブジェクトを変更するため効率的
    alloc_before = GC.stat[:total_allocated_objects]
    result2 = +''
    100.times { |i| result2 << "item_#{i} " }
    alloc_string_append = GC.stat[:total_allocated_objects] - alloc_before
    results[:string_append_allocations] = alloc_string_append

    # パターン3: 配列のmap（新しい配列とオブジェクトを生成）
    source = (1..100).to_a
    alloc_before = GC.stat[:total_allocated_objects]
    _mapped = source.map { |n| n * 2 }
    alloc_map = GC.stat[:total_allocated_objects] - alloc_before
    results[:array_map_allocations] = alloc_map

    # パターン4: each_with_object（追加の配列生成を避ける）
    alloc_before = GC.stat[:total_allocated_objects]
    _collected = source.each_with_object([]) { |n, acc| acc << (n * 2) }
    alloc_each_with_object = GC.stat[:total_allocated_objects] - alloc_before
    results[:each_with_object_allocations] = alloc_each_with_object

    # 文字列結合の +演算子 は <<演算子 より多くのオブジェクトを生成するはず
    results[:concat_more_than_append] = alloc_string_concat > alloc_string_append

    results
  end

  # === メモリ効率の良いパターン ===
  #
  # Rubyでメモリ効率を高めるための主要なパターン:
  #
  # 1. frozen_string_literal プラグマ
  #    - ファイル先頭に `# frozen_string_literal: true` を記述
  #    - 文字列リテラルが自動的にfreezeされ、同じ内容の文字列は同一オブジェクトを共有
  #    - オブジェクト生成数の削減とGC負荷の軽減に寄与
  #
  # 2. Symbol vs String
  #    - Symbolは一度生成されるとGCされない（Ruby 2.2以降は動的Symbolは回収される）
  #    - ハッシュキーにはSymbolを使うべき（比較が高速でメモリ効率も良い）
  #    - ただし、ユーザー入力をSymbolに変換するとメモリリークの原因になり得る
  #
  # 3. String#freeze
  #    - 明示的にfreezeした文字列は、同一内容であれば同一オブジェクトが再利用される
  #    - ループ内で同じ文字列を繰り返し使う場合に特に効果的
  #
  # @return [Hash] メモリ効率パターンのデモ結果
  def memory_efficient_patterns
    results = {}

    # --- frozen_string_literal の効果 ---
    # このファイルは frozen_string_literal: true なので、
    # 文字列リテラルは自動的にfreezeされている
    str_literal = 'hello'
    results[:literal_frozen] = str_literal.frozen?

    # 明示的にfreezeした文字列は同一オブジェクトを共有する
    frozen1 = 'shared_string'
    frozen2 = 'shared_string'
    results[:frozen_same_object] = frozen1.equal?(frozen2)

    # --- Symbol vs String ---
    # Symbolは同じ名前なら常に同一オブジェクト
    sym1 = :my_key
    sym2 = :my_key
    results[:symbol_same_object] = sym1.equal?(sym2)

    # Symbolはfrozenである
    results[:symbol_frozen] = :example.frozen?

    # --- 効率的なハッシュ構築パターン ---
    # SymbolキーのハッシュはStringキーより効率的
    alloc_before = GC.stat[:total_allocated_objects]
    1000.times do |i|
      { name: "user_#{i}", age: i, active: true }
    end
    alloc_symbol_hash = GC.stat[:total_allocated_objects] - alloc_before

    alloc_before = GC.stat[:total_allocated_objects]
    1000.times do |i|
      { 'name' => "user_#{i}", 'age' => i, 'active' => true }
    end
    alloc_string_hash = GC.stat[:total_allocated_objects] - alloc_before

    results[:symbol_hash_allocations] = alloc_symbol_hash
    results[:string_hash_allocations] = alloc_string_hash
    # frozen_string_literal: true の環境では差が小さくなるが、
    # Symbol版のほうが一般的に効率的
    results[:symbol_hash_more_efficient] = alloc_symbol_hash <= alloc_string_hash

    # --- Array#freeze と再利用 ---
    # 定数として定義する配列はfreezeすべき
    frozen_array = [1, 2, 3].freeze
    results[:frozen_array] = frozen_array.frozen?

    results
  end

  # === オブジェクトの世代昇格（Promotion）のデモ ===
  #
  # GCを複数回実行すると、生き残ったオブジェクトは新世代から旧世代に昇格する。
  # 旧世代に昇格したオブジェクトはマイナーGCではスキャンされないため、
  # マイナーGCの効率が向上する。
  #
  # @return [Hash] オブジェクト昇格に関する統計情報
  def demonstrate_object_promotion
    # 長寿命オブジェクトを生成
    long_lived = Array.new(1_000) { |i| "long_lived_#{i}" }

    stat_before = GC.stat
    old_objects_before = stat_before[:old_objects] || stat_before[:old_object] || 0

    # 複数回GCを実行してオブジェクトを昇格させる
    3.times { GC.start }

    stat_after = GC.stat
    old_objects_after = stat_after[:old_objects] || stat_after[:old_object] || 0

    {
      old_objects_before: old_objects_before,
      old_objects_after: old_objects_after,
      objects_promoted: old_objects_after >= old_objects_before,
      long_lived_count: long_lived.size, # 参照を保持して回収を防ぐ
      total_gc_runs: stat_after[:count]
    }
  end

  # === GC無効化の危険性と制御 ===
  #
  # GC.disable でGCを無効化できるが、本番環境では絶対に避けるべき。
  # メモリ使用量が際限なく増加し、OOMキラーに殺される可能性がある。
  #
  # ベンチマークや一時的な計測目的でのみ使用する。
  # 必ず ensure ブロックで GC.enable を呼ぶこと。
  #
  # @return [Hash] GC制御のデモ結果
  def demonstrate_gc_control
    results = {}

    # GCの状態確認
    results[:gc_enabled_initially] = !GC.respond_to?(:enabled?) || GC.enabled?

    # GCを一時的に無効化して割り当てを計測する安全なパターン
    allocated_during_disabled = nil
    begin
      GC.disable
      alloc_before = GC.stat[:total_allocated_objects]
      1_000.times { "temp_#{it}" }
      alloc_after = GC.stat[:total_allocated_objects]
      allocated_during_disabled = alloc_after - alloc_before
    ensure
      # 必ずGCを再有効化する
      GC.enable
    end

    results[:allocations_during_gc_disabled] = allocated_during_disabled
    results[:gc_re_enabled] = !GC.respond_to?(:enabled?) || GC.enabled?

    # GC.start のオプション
    results[:gc_start_options] = {
      full_mark: 'true=メジャーGC, false=マイナーGC',
      immediate_sweep: 'true=即座にスイープ, false=遅延スイープ'
    }

    results
  end
end
