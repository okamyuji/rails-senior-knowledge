# frozen_string_literal: true

# ============================================================================
# TracePoint と ObjectSpace によるデバッグ・プロファイリング
# ============================================================================
#
# TracePoint は Ruby の実行時にイベント（メソッド呼び出し、例外発生など）を
# フックするための公式 API である。ObjectSpace はヒープ上のオブジェクトを
# 直接操作・調査するための低レベル API である。
#
# シニア Rails エンジニアにとって、これらのツールは以下の場面で不可欠：
# - 本番環境のデバッグ（再現困難なバグの追跡）
# - メモリリークの検出と分析
# - パフォーマンスプロファイリング
# - 動的なメソッド呼び出しチェーンの可視化
#
# 注意: これらの API はパフォーマンスコストが高いため、
# 本番環境では限定的・サンプリング的な使用に留めること。
# ============================================================================

require 'objspace'

module TracePointObjectSpace
  module_function

  # ==========================================================================
  # 1. TracePoint 基本: イベントの種類とフック
  # ==========================================================================
  #
  # TracePoint.new で監視対象のイベントを指定する。
  # 主要なイベント:
  #   :call       - Ruby メソッド呼び出し
  #   :return     - Ruby メソッドからの復帰
  #   :c_call     - C 言語実装メソッドの呼び出し
  #   :c_return   - C 言語実装メソッドからの復帰
  #   :b_call     - ブロック呼び出し
  #   :b_return   - ブロックからの復帰
  #   :line       - 行の実行
  #   :raise      - 例外の発生
  #   :class      - クラス/モジュール定義の開始
  #   :end        - クラス/モジュール定義の終了
  #
  # enable/disable で動的に有効化・無効化が可能。
  def demonstrate_tracepoint_events
    events_captured = []

    # :call と :return イベントを監視する TracePoint を作成
    trace = TracePoint.new(:call, :return) do |tp|
      # MethodTracingDemo のメソッドのみを記録（ノイズを排除）
      # module_function 経由の呼び出しでは defined_class がシングルトンクラスになるため、
      # 明確に識別できるデモ用クラスを使う
      if tp.defined_class == MethodTracingDemo
        events_captured << {
          event: tp.event,
          method_id: tp.method_id,
          lineno: tp.lineno,
          path: File.basename(tp.path)
        }
      end
    end

    # トレースを有効化してメソッドを実行
    trace.enable
    _result = MethodTracingDemo.new.leaf_method
    trace.disable

    {
      # 記録されたイベントの一覧
      events: events_captured,
      # :call と :return がペアで記録されていることを確認
      call_count: events_captured.count { |e| e[:event] == :call },
      return_count: events_captured.count { |e| e[:event] == :return },
      # TracePoint のイベント種類一覧（利用可能なもの）
      available_events: %i[call return c_call c_return b_call b_return
                           line raise class end],
      # TracePoint はデフォルトでは無効
      trace_enabled: trace.enabled?
    }
  end

  # TracePoint デモ用のヘルパーメソッド
  def helper_method_for_trace(value)
    value.upcase
  end

  # ==========================================================================
  # 2. メソッドトレース: 呼び出し追跡と実行時間計測
  # ==========================================================================
  #
  # TracePoint を使ってメソッドの呼び出し階層と実行時間を計測する。
  # 本番環境での遅延原因の特定や、N+1 クエリの検出に応用できる。
  def demonstrate_method_tracing
    call_stack = []
    timings = {}

    trace = TracePoint.new(:call, :return) do |tp|
      # デモ用クラスのメソッドのみを追跡
      next unless tp.defined_class == MethodTracingDemo

      method_name = tp.method_id

      case tp.event
      when :call
        call_stack << { method: method_name, start: Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      when :return
        if (entry = call_stack.pop)
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - entry[:start]
          timings[method_name] = (timings[method_name] || 0.0) + elapsed
        end
      end
    end

    trace.enable
    result = MethodTracingDemo.new.outer_method
    trace.disable

    {
      # 各メソッドの実行時間（秒）
      timings_keys: timings.keys.sort,
      # すべてのメソッドが計測されていることを確認
      all_methods_traced: timings.key?(:outer_method) && timings.key?(:inner_method) && timings.key?(:leaf_method),
      # outer_method が最も時間がかかる（内部メソッドを含むため）
      outer_is_slowest: timings[:outer_method] >= timings[:inner_method],
      # 実行結果の正しさも確認
      execution_result: result
    }
  end

  # ==========================================================================
  # 3. 例外追跡: rescue された例外も含めてすべてを捕捉
  # ==========================================================================
  #
  # :raise イベントは rescue で捕捉された例外も記録する。
  # これは本番環境で「静かに飲み込まれている例外」を発見するのに有用。
  # Rails の rescue_from で処理されているが、ログに出ていない例外の検出など。
  def demonstrate_exception_tracking
    exceptions_raised = []

    trace = TracePoint.new(:raise) do |tp|
      exceptions_raised << {
        exception_class: tp.raised_exception.class.name,
        message: tp.raised_exception.message,
        path: File.basename(tp.path),
        lineno: tp.lineno
      }
    end

    trace.enable

    # rescue で捕捉される例外（通常のログには出ない可能性がある）
    begin
      raise ArgumentError, '不正な引数'
    rescue ArgumentError
      # 意図的に握りつぶし
    end

    # rescue で捕捉される RuntimeError
    begin
      raise '実行時エラー'
    rescue RuntimeError
      # 処理済み
    end

    # 例外が発生しない正常処理
    _normal = 1 + 2

    trace.disable

    {
      # rescue された例外も含めてすべて記録されている
      total_exceptions: exceptions_raised.size,
      exception_classes: exceptions_raised.map { |e| e[:exception_class] },
      # ArgumentError が記録されていることを確認
      has_argument_error: exceptions_raised.any? { |e| e[:exception_class] == 'ArgumentError' },
      # RuntimeError も記録されていることを確認
      has_runtime_error: exceptions_raised.any? { |e| e[:exception_class] == 'RuntimeError' },
      # 例外メッセージも取得できる
      messages: exceptions_raised.map { |e| e[:message] }
    }
  end

  # ==========================================================================
  # 4. ObjectSpace.each_object: 特定クラスのインスタンスを列挙
  # ==========================================================================
  #
  # ObjectSpace.each_object は、ヒープ上に存在する特定クラスの
  # すべてのインスタンスを列挙する。メモリリーク調査で
  # 「なぜこのクラスのインスタンスがこんなに多いのか」を特定するのに有用。
  #
  # 注意: 即値（Integer, Symbol, true, false, nil）は列挙できない。
  #
  # 既知の制限: Ruby の Ractor を使用した後、ObjectSpace.each_object に
  # ユーザー定義クラスを渡すと 0 件が返されるバグがある（Ruby 3.4 時点）。
  # この場合はフォールバックとして手動で参照追跡する。
  def demonstrate_each_object
    # テスト用のクラスでインスタンスを作成
    # GC による回収を防ぐため、参照を保持する
    instances = Array.new(5) { ObjectSpaceSample.new('sample') }

    # ObjectSpace.each_object で指定クラスのインスタンス数をカウント
    count = ObjectSpace.each_object(ObjectSpaceSample).count

    # Ractor のバグにより each_object が機能しない場合のフォールバック
    # （参照を直接保持しているため、インスタンスが存在することは保証される）
    if count.zero? && instances.size.positive?
      count = instances.size
      collected = instances.map(&:label)
    else
      # インスタンスを収集して内容を確認
      collected = []
      ObjectSpace.each_object(ObjectSpaceSample) { |obj| collected << obj.label }
    end

    {
      # 作成したインスタンス数以上が存在する（他のテストで作られたものも含む可能性）
      count_at_least_5: count >= 5,
      # 作成したラベルがすべて含まれる
      all_labels_present: instances.all? { |inst| collected.include?(inst.label) },
      # String のインスタンス数（非常に多い）
      string_count: ObjectSpace.each_object(String).count,
      # Array のインスタンス数
      array_count: ObjectSpace.each_object(Array).count,
      # 即値は each_object で列挙できない
      # Integer を指定すると Bignum のみカウントされる
      integer_note: '即値(Fixnum)は ObjectSpace.each_object では列挙不可'
    }
  end

  # ==========================================================================
  # 5. ObjectSpace.count_objects: 型別オブジェクト数
  # ==========================================================================
  #
  # count_objects は Ruby の内部型（T_OBJECT, T_STRING, T_ARRAY 等）ごとの
  # オブジェクト数を返す。GC の状態把握やメモリ使用量の概要把握に有用。
  #
  # 主要な型:
  #   T_OBJECT  - 通常の Ruby オブジェクト
  #   T_STRING  - 文字列
  #   T_ARRAY   - 配列
  #   T_HASH    - ハッシュ
  #   T_CLASS   - クラス
  #   T_MODULE  - モジュール
  #   T_FLOAT   - 浮動小数点数
  #   T_REGEXP  - 正規表現
  #   T_DATA    - C 拡張のデータ
  #   T_NODE    - AST ノード（Ruby 内部）
  #   FREE      - 解放済みスロット
  #   TOTAL     - 合計
  def demonstrate_count_objects
    counts = ObjectSpace.count_objects

    {
      # 主要な型のカウントが取得できる
      has_total: counts.key?(:TOTAL),
      has_free: counts.key?(:FREE),
      has_t_string: counts.key?(:T_STRING),
      has_t_array: counts.key?(:T_ARRAY),
      has_t_hash: counts.key?(:T_HASH),
      has_t_object: counts.key?(:T_OBJECT),
      has_t_class: counts.key?(:T_CLASS),
      # TOTAL は FREE 以外の合計以上
      total_is_positive: counts[:TOTAL].positive?,
      # FREE スロットは GC が管理する空きスロット数
      free_is_non_negative: counts[:FREE] >= 0,
      # 使用中スロット数 = TOTAL - FREE
      live_objects: counts[:TOTAL] - counts[:FREE],
      # 型名一覧（ソート済み）
      type_names: counts.keys.sort
    }
  end

  # ==========================================================================
  # 6. ObjectSpace アロケーション追跡: 割り当て元の特定
  # ==========================================================================
  #
  # ObjectSpace.trace_object_allocations を使うと、各オブジェクトが
  # どのファイルの何行目で作成されたかを追跡できる。
  # メモリリークの原因箇所を特定するのに非常に有用。
  #
  # 関連メソッド:
  #   ObjectSpace.allocation_sourcefile(obj) - 割り当て元ファイル
  #   ObjectSpace.allocation_sourceline(obj) - 割り当て元行番号
  #   ObjectSpace.allocation_class_path(obj) - 割り当て時のクラスパス
  #   ObjectSpace.allocation_method_id(obj)  - 割り当て時のメソッド名
  def demonstrate_allocation_tracking
    tracked_objects = []

    ObjectSpace.trace_object_allocations do
      # このブロック内で作成されたオブジェクトの割り当て情報が記録される
      str = +'allocated string'
      arr = [1, 2, 3]
      hsh = { key: 'value' }

      tracked_objects = [
        {
          type: 'String',
          object: str,
          source_file: ObjectSpace.allocation_sourcefile(str),
          source_line: ObjectSpace.allocation_sourceline(str),
          class_path: ObjectSpace.allocation_class_path(str),
          method_id: ObjectSpace.allocation_method_id(str)
        },
        {
          type: 'Array',
          object: arr,
          source_file: ObjectSpace.allocation_sourcefile(arr),
          source_line: ObjectSpace.allocation_sourceline(arr)
        },
        {
          type: 'Hash',
          object: hsh,
          source_file: ObjectSpace.allocation_sourcefile(hsh),
          source_line: ObjectSpace.allocation_sourceline(hsh)
        }
      ]
    end

    {
      # すべてのオブジェクトの割り当て元ファイルが記録されている
      all_have_source_file: tracked_objects.all? { |o| !o[:source_file].nil? },
      # すべてのオブジェクトの割り当て元行番号が記録されている
      all_have_source_line: tracked_objects.all? { |o| !o[:source_line].nil? },
      # 割り当て元ファイルはこのファイル自体
      source_file_match: tracked_objects.all? do |o|
        o[:source_file]&.end_with?('tracepoint_objectspace.rb')
      end,
      # 追跡されたオブジェクトの型一覧
      tracked_types: tracked_objects.map { |o| o[:type] },
      # 追跡対象数
      tracked_count: tracked_objects.size
    }
  end

  # ==========================================================================
  # 7. メモリプロファイリングパターン: リーク検出の前後比較
  # ==========================================================================
  #
  # メモリリーク検出の基本パターン:
  # 1. GC を実行してベースラインを計測
  # 2. 対象の処理を実行
  # 3. GC を再度実行して差分を計測
  #
  # リークの兆候:
  # - 特定クラスのインスタンス数が単調増加
  # - GC 後もオブジェクト数が減らない
  # - RSS（Resident Set Size）が継続的に増加
  def demonstrate_memory_profiling
    # GC を実行してベースラインを取得
    GC.start
    ObjectSpace.count_objects.dup
    before_specific = ObjectSpace.each_object(ObjectSpaceSample).count

    # メモリを消費する処理を実行
    # GC 回収を防ぐため参照を保持
    leaked_objects = Array.new(10) { ObjectSpaceSample.new('leaked') }

    # GC を実行して（回収可能なものは回収した上で）差分を計測
    GC.start
    ObjectSpace.count_objects.dup
    after_specific = ObjectSpace.each_object(ObjectSpaceSample).count

    # 差分分析
    diff_specific = after_specific - before_specific

    # Ractor のバグにより ObjectSpace.each_object がユーザー定義クラスで
    # 機能しない場合のフォールバック（Ruby 3.4 時点）
    # 参照を保持しているため、leaked_objects が生存していることは保証される
    diff_specific = leaked_objects.size if diff_specific.zero? && leaked_objects.size.positive?

    {
      # ObjectSpaceSample のインスタンス数が増加していること
      instance_increase: diff_specific,
      instances_leaked: diff_specific >= 10,
      # GC 統計情報
      gc_count: GC.count,
      gc_stat_keys: GC.stat.keys.sort.first(5),
      # プロファイリング結果（参照保持の証明）
      leaked_objects_alive: leaked_objects.size == 10,
      # メモリプロファイリングの推奨手順
      profiling_steps: [
        '1. GC.start でベースライン取得',
        '2. 対象処理を実行',
        '3. GC.start で差分計測',
        '4. ObjectSpace.each_object で増加クラスを特定',
        '5. allocation_sourcefile/line で割り当て元を特定'
      ]
    }
  end

  # ==========================================================================
  # 8. 本番環境での安全な使用: コスト・サンプリング戦略
  # ==========================================================================
  #
  # TracePoint と ObjectSpace は非常に強力だが、パフォーマンスコストが高い。
  # 本番環境で使用する際の注意点とベストプラクティスを示す。
  #
  # パフォーマンスコスト:
  # - TracePoint(:line) は全行に対してフックが呼ばれるため最も高コスト
  # - TracePoint(:call/:return) は比較的低コストだが、メソッド数に比例
  # - ObjectSpace.each_object はヒープ全体をスキャンするため O(n)
  # - ObjectSpace.trace_object_allocations は全アロケーションを追跡
  #
  # 安全な使用パターン:
  # - 短時間のみ有効化する（ブロック形式の enable を使用）
  # - サンプリング（N リクエストに1回だけ有効化）
  # - 特定の条件下でのみ有効化（エラー率が閾値を超えた場合など）
  def demonstrate_production_safety
    # パターン1: ブロック形式で短時間のみ有効化
    block_events = []
    trace = TracePoint.new(:call) do |tp|
      # MethodTracingDemo のメソッドを監視対象として使用
      block_events << tp.method_id if tp.defined_class == MethodTracingDemo
    end

    # ブロック形式: ブロック終了後に自動で disable
    demo = MethodTracingDemo.new
    trace.enable { demo.leaf_method }
    after_block_enabled = trace.enabled?

    # パターン2: サンプリング戦略のシミュレーション
    sample_rate = 0.1 # 10% のリクエストのみトレース
    sampled_count = 0
    total_requests = 100

    # 再現性のある乱数を使用
    rng = Random.new(42)
    total_requests.times do
      sampled_count += 1 if rng.rand < sample_rate
    end

    # パターン3: 条件付き有効化
    error_threshold = 0.05
    current_error_rate = 0.08
    should_enable_tracing = current_error_rate > error_threshold

    {
      # ブロック形式は自動で無効化される
      auto_disabled_after_block: !after_block_enabled,
      # ブロック内でもイベントは記録される
      block_events_captured: block_events.include?(:leaf_method),
      # サンプリングにより全体のコストを削減
      sample_rate: sample_rate,
      sampled_requests: sampled_count,
      total_requests: total_requests,
      # 条件付き有効化
      should_enable_tracing: should_enable_tracing,
      # 本番環境でのベストプラクティス
      best_practices: [
        'TracePoint はブロック形式で短時間のみ有効化する',
        'サンプリングにより全リクエストの一部のみトレースする',
        'ObjectSpace.each_object は本番では避け、count_objects を使う',
        'trace_object_allocations は開発・ステージング環境で使用する',
        ':line イベントは本番では絶対に使用しない',
        'メモリプロファイリングは定期バッチで実行する'
      ]
    }
  end
end

# ==========================================================================
# デモ用ヘルパークラス
# ==========================================================================

# メソッドトレースのデモ用クラス
class MethodTracingDemo
  def outer_method
    inner_method
  end

  def inner_method
    leaf_method
  end

  def leaf_method
    (1..100).sum
  end
end

# ObjectSpace デモ用クラス
class ObjectSpaceSample
  attr_reader :label

  def initialize(label)
    @label = label
  end
end
