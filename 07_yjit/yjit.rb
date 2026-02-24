# frozen_string_literal: true

# ============================================================================
# YJIT (Yet Another JIT) 最適化モジュール
# ============================================================================
#
# YJITはRuby 3.1で実験的に導入され、Ruby 3.2で正式リリースされた
# JIT（Just-In-Time）コンパイラです。CRubyのインタプリタ内に組み込まれ、
# Lazy Basic Block Versioning (LBBV) というアルゴリズムを採用しています。
#
# ============================================================================
# YJITのコマンドラインオプション
# ============================================================================
#
# --yjit                  : YJITを有効化
# --yjit-exec-mem-size=N  : 実行可能メモリサイズ（MB単位、デフォルト: 48MB）
# --yjit-call-threshold=N : メソッドをコンパイルするまでの呼び出し回数（デフォルト: 30）
# --yjit-stats            : YJIT統計情報を有効化（パフォーマンス計測用）
# --yjit-log              : YJITのログ出力を有効化（Ruby 3.4+）
#
# 本番環境での推奨設定例:
#   RUBY_YJIT_ENABLE=1 （環境変数による有効化、Ruby 3.3+）
#   ruby --yjit --yjit-exec-mem-size=128 app.rb
#
# ============================================================================
# Lazy Basic Block Versioning (LBBV) の仕組み
# ============================================================================
#
# LBBVはYJITの中核アルゴリズムで、以下の特徴を持ちます：
#
# 1. 遅延コンパイル（Lazy Compilation）
#    - メソッド全体を一度にコンパイルするのではなく、実行されるBasic Blockを
#      必要に応じてコンパイルする（到達したパスのみ）
#    - 実行されないコードパスはコンパイルしないため、メモリ効率が良い
#
# 2. Basic Blockバージョニング（Block Versioning）
#    - 同じBasic Blockでも、異なる型コンテキストに対して異なるバージョンの
#      ネイティブコードを生成する
#    - 例: 引数がIntegerの場合とStringの場合で別のコンパイル済みコードを持つ
#
# 3. 型特化（Type Specialization）
#    - 実行時の型情報に基づいてコードを最適化する
#    - モノモーフィック（単一型）な呼び出しサイトは高速な直接呼び出しに変換される
#    - ポリモーフィック（複数型）な呼び出しサイトは最適化が限定的になる
#
# 4. サイドイグジット（Side Exit）
#    - コンパイル済みコードの前提（型ガード）が破られた場合、
#      インタプリタにフォールバックする仕組み
#    - 頻繁なサイドイグジットは再コンパイルのトリガーになる
#
# ============================================================================

module YjitOptimization
  # --------------------------------------------------------------------------
  # YJIT利用可能性チェック
  # --------------------------------------------------------------------------

  # YJITが現在のRuby環境で利用可能かつ有効かを判定する
  #
  # @return [Hash] YJITの状態情報
  def self.check_yjit_availability
    result = {
      ruby_version: RUBY_VERSION,
      ruby_platform: RUBY_PLATFORM,
      yjit_defined: defined?(RubyVM::YJIT) ? true : false,
      yjit_enabled: false,
      yjit_version: nil
    }

    if defined?(RubyVM::YJIT)
      result[:yjit_enabled] = RubyVM::YJIT.enabled?
      # Ruby 3.3+ではYJITバージョン情報が取得可能
      if RubyVM::YJIT.respond_to?(:runtime_stats)
        stats = RubyVM::YJIT.runtime_stats
        result[:yjit_version] = stats[:yjit_version] if stats.is_a?(Hash)
      end
    end

    result
  end

  # --------------------------------------------------------------------------
  # YJIT実行時統計情報
  # --------------------------------------------------------------------------

  # YJITの実行時統計情報を取得する
  # --yjit-stats オプション付きで起動した場合に詳細な統計が得られる
  #
  # @return [Hash] YJIT統計情報（無効時はステータスのみ）
  def self.fetch_runtime_stats
    return { status: :yjit_disabled, message: 'YJITが有効ではありません' } unless defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?

    stats = RubyVM::YJIT.runtime_stats

    # 主要な統計情報を抽出して返す
    {
      status: :yjit_enabled,
      # コンパイル済みISEQ（命令シーケンス）数
      compiled_iseq_count: stats[:compiled_iseq_count],
      # コンパイル済みブロック数
      compiled_block_count: stats[:compiled_block_count],
      # インライン化されたコードのサイズ（バイト）
      inline_code_size: stats[:inline_code_size],
      # アウトラインコードのサイズ（バイト）
      outlined_code_size: stats[:outlined_code_size],
      # サイドイグジットの回数（型ガード失敗）
      exit_count: stats[:side_exit_count],
      # 無効化されたブロック数（メソッド再定義等で発生）
      invalidation_count: stats[:invalidation_count],
      # 全統計情報（詳細分析用）
      raw_stats: stats
    }
  end

  # --------------------------------------------------------------------------
  # 型特化のデモンストレーション
  # --------------------------------------------------------------------------

  # === モノモーフィックな呼び出し（YJITに最適）===
  #
  # 同じ型の引数で繰り返し呼ばれるメソッドは、YJITが型ガードを挿入し
  # 特化したネイティブコードを生成できるため、高速に実行される。
  #
  # LBBVでは、このメソッドに対してInteger専用のBasic Blockバージョンが
  # 生成され、型チェックのオーバーヘッドが最小化される。

  # 整数の合計を計算する（モノモーフィック：常にIntegerを受け取る想定）
  #
  # @param numbers [Array<Integer>] 整数の配列
  # @return [Integer] 合計値
  def self.monomorphic_sum(numbers)
    total = 0
    numbers.each do |n|
      total += n
    end
    total
  end

  # === ポリモーフィックな呼び出し（YJITの最適化が制限される）===
  #
  # 異なる型の引数が混在して渡される場合、YJITは複数のBasic Blockバージョンを
  # 生成するか、最適化を諦めてインタプリタにフォールバックする。
  # これはメガモーフィック（型が多すぎる）状態と呼ばれ、性能低下の原因となる。

  # 多様な型のオブジェクトを文字列化する（ポリモーフィック）
  #
  # @param items [Array<Object>] 様々な型のオブジェクトの配列
  # @return [String] 連結された文字列
  def self.polymorphic_stringify(items)
    result = +''
    items.each do |item|
      result << item.to_s
    end
    result
  end

  # --------------------------------------------------------------------------
  # YJITに適したコードパターン
  # --------------------------------------------------------------------------

  # 型が安定したコードパターンの例
  # YJITは以下のようなコードを効率的にコンパイルできる：
  #
  # 1. 一貫した型の使用
  # 2. frozen_string_literalの活用
  # 3. 単純なメソッドチェーン
  # 4. 局所変数の活用（インスタンス変数よりも高速）
  #
  # @param data [Array<Hash>] ハッシュの配列（全要素が同じキー構造を持つ想定）
  # @return [Array<String>] フォーマットされた文字列の配列
  def self.yjit_friendly_pattern(data)
    results = []

    data.each do |item|
      # 局所変数に代入することでYJITの型推論を助ける
      name = item[:name]
      score = item[:score]

      # frozen stringリテラルは再アロケーションを避ける
      formatted = "#{name}: #{score}点"
      results << formatted
    end

    results
  end

  # --------------------------------------------------------------------------
  # YJITに不利なコードパターン
  # --------------------------------------------------------------------------

  # YJITの最適化を妨げるパターンの説明を返す
  #
  # 以下のパターンはYJITのコンパイルを無効化またはサイドイグジットを頻発させる：
  #
  # 1. 文字列の動的評価（コンパイル不可能）
  # 2. 過度なメタプログラミング（method_missing, define_method動的呼び出し）
  # 3. 定数の再定義（コンパイル済みコードの無効化を引き起こす）
  # 4. ObjectSpace.each_object などのリフレクション
  #
  # @return [Hash] 各パターンの説明と影響
  def self.yjit_unfriendly_patterns
    {
      dynamic_code_evaluation: {
        description: '文字列の動的評価はYJITでコンパイルできないため、インタプリタ実行になる',
        impact: :high,
        note: 'Kernel#evalやBinding#evalが該当'
      },
      excessive_metaprogramming: {
        description: 'method_missingの多用は呼び出しサイトの型を不安定にする',
        impact: :high,
        note: '動的なmethod_missingチェーンはBasic Blockの特化を妨げる'
      },
      constant_redefinition: {
        description: '定数の再定義はYJITのコンパイル済みコードを無効化（invalidation）する',
        impact: :medium,
        note: '起動後の定数変更はinvalidationが発生する'
      },
      dynamic_dispatch: {
        description: 'sendやpublic_sendによる動的ディスパッチは型特化を制限する',
        impact: :medium,
        note: 'メソッド名が実行時に決まる呼び出しは最適化困難'
      }
    }
  end

  # --------------------------------------------------------------------------
  # ベンチマーク手法
  # --------------------------------------------------------------------------

  # YJITの効果を正しく計測するためのマイクロベンチマークパターン
  #
  # 重要なポイント：
  # - ウォームアップフェーズを設ける（YJITのコンパイル閾値を超えるため）
  # - 複数回計測して中央値を取る
  # - GCの影響を最小化する
  # - --yjitあり/なしの両方で計測して比較する
  #
  # @param warmup_iterations [Integer] ウォームアップの反復回数
  # @param measure_iterations [Integer] 計測の反復回数
  # @param measurement_rounds [Integer] 計測ラウンド数（中央値算出用）
  # @yield 計測対象のブロック
  # @return [Hash] 計測結果
  def self.benchmark_with_warmup(warmup_iterations: 1000, measure_iterations: 10_000, measurement_rounds: 5, &block)
    raise ArgumentError, 'ブロックが必要です' unless block_given?

    # ウォームアップフェーズ
    # YJITのcall_threshold（デフォルト30回）を超えてコンパイルを完了させる
    warmup_iterations.times { block.call }

    # GCを実行してから無効化して計測のばらつきを抑える
    GC.start
    GC.disable

    # 複数ラウンドの計測
    elapsed_times = []
    measurement_rounds.times do
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      measure_iterations.times { block.call }
      end_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      elapsed_times << (end_time - start_time)
    end

    # GCを再度有効化する
    GC.enable

    sorted_times = elapsed_times.sort
    median_time = sorted_times[sorted_times.length / 2]

    {
      warmup_iterations: warmup_iterations,
      measure_iterations: measure_iterations,
      measurement_rounds: measurement_rounds,
      elapsed_times: elapsed_times.map { |t| t.round(6) },
      median_time: median_time.round(6),
      min_time: sorted_times.first.round(6),
      max_time: sorted_times.last.round(6),
      iterations_per_second: (measure_iterations / median_time).round(2),
      yjit_enabled: defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
    }
  end

  # --------------------------------------------------------------------------
  # 型安定性のデモンストレーション
  # --------------------------------------------------------------------------

  # 型が安定したフィボナッチ計算（YJITが効果的に最適化可能）
  #
  # Integer同士の演算のみで構成されるため、YJITは全てのBasic Blockを
  # Integer専用にコンパイルでき、型ガードのオーバーヘッドが最小になる。
  #
  # @param n [Integer] フィボナッチ数列のインデックス
  # @return [Integer] n番目のフィボナッチ数
  def self.type_stable_fibonacci(n)
    return n if n <= 1

    a = 0
    b = 1
    (n - 1).times do
      temp = b
      b = a + b
      a = temp
    end
    b
  end

  # 型が不安定な変換パターン（YJITの最適化が制限される）
  #
  # 条件によって返す型が変わるメソッドは、呼び出し元の型推論を困難にし、
  # Basic Blockのバージョンが増加する原因となる。
  #
  # @param value [Numeric] 入力値
  # @return [Integer, Float, String] 変換結果（型が不安定）
  def self.type_unstable_conversion(value)
    case value
    when Integer
      value * 2
    when Float
      value.round(2)
    else
      value.to_s
    end
  end

  # --------------------------------------------------------------------------
  # インライン定数キャッシュのデモンストレーション
  # --------------------------------------------------------------------------

  # YJITでは定数参照もインライン化される
  # 定数を再定義するとinvalidation（無効化）が発生し、
  # その定数を参照するコンパイル済みコードが全て再コンパイルされる
  #
  # 本番環境では起動後に定数を再定義しないことが重要
  YJIT_DEMO_CONSTANT = 42

  # 定数を参照する計算（YJITがインライン化する）
  #
  # @param multiplier [Integer] 乗数
  # @return [Integer] 定数 x 乗数
  def self.constant_reference_demo(multiplier)
    YJIT_DEMO_CONSTANT * multiplier
  end

  # --------------------------------------------------------------------------
  # Rails環境でのYJIT活用パターン
  # --------------------------------------------------------------------------

  # Railsアプリケーションにおける典型的なシリアライゼーションパターン
  # 同じ構造のHashを繰り返し処理する場合、YJITが効果を発揮する
  #
  # @param records [Array<Hash>] レコードの配列
  # @param fields [Array<Symbol>] 出力するフィールド名
  # @return [Array<Hash>] シリアライズされた結果
  def self.serialize_records(records, fields)
    records.map do |record|
      serialized = {}
      fields.each do |field|
        serialized[field] = record[field]
      end
      serialized
    end
  end

  # --------------------------------------------------------------------------
  # YJIT状態のサマリー出力
  # --------------------------------------------------------------------------

  # 現在のYJIT状態を人間可読な形式でまとめる
  #
  # @return [String] YJIT状態のサマリー文字列
  def self.status_summary
    availability = check_yjit_availability

    lines = []
    lines << '=== YJIT状態サマリー ==='
    lines << "Ruby バージョン: #{availability[:ruby_version]}"
    lines << "プラットフォーム: #{availability[:ruby_platform]}"
    lines << "YJIT定義済み: #{availability[:yjit_defined] ? 'はい' : 'いいえ'}"
    lines << "YJIT有効: #{availability[:yjit_enabled] ? 'はい' : 'いいえ'}"

    if availability[:yjit_enabled]
      stats = fetch_runtime_stats
      lines << "コンパイル済みISEQ数: #{stats[:compiled_iseq_count]}"
      lines << "コンパイル済みブロック数: #{stats[:compiled_block_count]}"
      lines << "インラインコードサイズ: #{stats[:inline_code_size]} bytes"
      lines << "無効化回数: #{stats[:invalidation_count]}" if stats[:invalidation_count]
    end

    lines.join("\n")
  end
end
