# frozen_string_literal: true

# Ractor: Rubyの並列実行モデル
#
# Ruby 3.0で導入され、Ruby 4.0でAPIが整理されたRactorは、GVL（Global VM Lock）の制約を超えて
# 真の並列実行を実現するためのアクターモデルベースの並行・並列処理機構。
#
# 主な特徴:
# - 各Ractorは独立したメモリ空間を持つ
# - オブジェクトの共有は厳密に制限される（安全性の保証）
# - メッセージパッシングによる通信
#   Ruby 4.0では Ractor::Port と Ractor#value が結果の受け渡しを担う
#   （3.xの Ractor.yield / Ractor#take は削除された）
# - CPU-bound処理の並列化に適している
module RactorParallel
  # ==========================================================================
  # 1. 基本的なRactor: push型とpull型の通信パターン
  # ==========================================================================

  # push型通信: Ractor#send でメッセージを送り、Ractor.receive で受け取る
  # 外部から Ractor にデータを「押し込む」パターン
  def self.push_style_communication(message)
    ractor = Ractor.new do
      # Ractor.receive で送られてきたメッセージを待ち受ける
      received = Ractor.receive
      "受信: #{received}"
    end

    # send でメッセージを送る
    ractor.send(message)
    # value でブロックの戻り値を取得する
    ractor.value
  end

  # pull型通信: Ractor::Port に結果を送り、呼び出し側が Port#receive で取り出す
  # Ractorが計算結果を Port へ「公開」し、外部から「引き出す」パターン
  # （3.xの Ractor.yield / Ractor#take の代わり）
  def self.pull_style_communication(value)
    port = Ractor::Port.new

    # Port は shareable なので引数として Ractor に渡せる
    worker = Ractor.new(port, value) do |out, val|
      # 引数として受け取った値を加工して Port へ送る
      out << (val * 2)
    end

    # 先に終了を待つ。ワーカーが例外で終わると Port には何も届かず、receive が戻らないため
    worker.value
    # Port#receive は Port を作った Ractor（ここでは呼び出し側）だけが呼べる
    port.receive
  end

  # 複数メッセージのやり取り（双方向通信）
  def self.bidirectional_communication(values)
    ractor = Ractor.new do
      results = []
      loop do
        msg = Ractor.receive
        break if msg == :done

        results << msg.upcase
      end
      results
    end

    values.each { |v| ractor.send(v) }
    ractor.send(:done)
    ractor.value
  end

  # ==========================================================================
  # 2. 共有可能オブジェクト（Shareable Objects）
  # ==========================================================================

  # Ractor間で共有できるオブジェクトの種類を確認する
  # 共有可能: frozen文字列、Symbol、数値、true/false/nil、Ractorオブジェクト自体
  def self.check_shareable_objects
    results = {}

    # 数値は常に共有可能（immutableなため）
    results[:integer] = Ractor.shareable?(42)
    results[:float] = Ractor.shareable?(3.14)

    # Symbolは常に共有可能
    results[:symbol] = Ractor.shareable?(:hello)

    # frozen文字列は共有可能
    results[:frozen_string] = Ractor.shareable?('hello')

    # 通常の文字列は共有不可（mutableなため）
    # frozen_string_literal: true のファイルでは文字列リテラルはfrozen
    results[:mutable_string] = Ractor.shareable?(String.new('hello'))

    # true, false, nil は共有可能
    results[true] = Ractor.shareable?(true)
    results[false] = Ractor.shareable?(false)
    results[:nil] = Ractor.shareable?(nil)

    # Rangeも要素がshareable ならshareable
    results[:frozen_range] = Ractor.shareable?(1..10)

    results
  end

  # Ractor.make_shareable でオブジェクトを共有可能にする
  # deep freezeを行い、オブジェクトとその内部要素をすべてfreezeする
  def self.make_object_shareable
    # 配列を共有可能にする（内部の要素もすべてfreezeされる）
    array = [1, 'hello', :world]
    Ractor.make_shareable(array)

    {
      shareable: Ractor.shareable?(array),
      frozen: array.frozen?,
      elements_frozen: array.all?(&:frozen?)
    }
  end

  # ==========================================================================
  # 3. 分離ルール（Isolation Rules）
  # ==========================================================================

  # コピーセマンティクス: sendはデフォルトでオブジェクトをディープコピーする
  # 元のオブジェクトとRactor内のオブジェクトは別物になる
  def self.demonstrate_copy_semantics
    original = [1, 2, 3]

    ractor = Ractor.new do
      received = Ractor.receive
      received << 4 # コピーされたオブジェクトを変更
      received
    end

    ractor.send(original)
    modified = ractor.value

    {
      original: original,        # [1, 2, 3] — 変更されない
      modified: modified,        # [1, 2, 3, 4] — コピーが変更された
      different_objects: !original.equal?(modified)
    }
  end

  # moveセマンティクス: send(obj, move: true) でオブジェクトの所有権を移転
  # 移転後、元のRactorからはアクセスできなくなる
  def self.demonstrate_move_semantics
    original = [1, 2, 3]

    ractor = Ractor.new do
      received = Ractor.receive
      received << 4
      received
    end

    # move: true で所有権を移転
    ractor.send(original, move: true)
    modified = ractor.value

    # originalは移動済みなのでアクセスするとエラーになる
    begin
      original.length
      moved_error = false
    rescue Ractor::MovedError
      moved_error = true
    end

    {
      modified: modified,
      original_moved: moved_error
    }
  end

  # ==========================================================================
  # 4. 並列計算: Fan-out/Fan-inパターン
  # ==========================================================================

  # 複数のRactorに作業を分散し、結果を集約するパターン
  # CPU-bound処理の並列化に最適
  def self.parallel_computation(numbers, worker_count: 4)
    # 作業を分割
    chunks = numbers.each_slice((numbers.size.to_f / worker_count).ceil).to_a

    # 素数判定のロジック（Ractor内ではモジュールメソッドを直接呼べないためlambdaで定義）
    # Ractor内のselfはRactorインスタンスであり、RactorParallelモジュールではない
    prime_check = Ractor.make_shareable(
      lambda do |n|
        return false if n < 2
        return true if n < 4

        (2..Math.sqrt(n).to_i).none? { |i| (n % i).zero? }
      end
    )

    # Fan-out: 各チャンクを処理するRactorを生成
    workers = chunks.map do |chunk|
      Ractor.new(chunk, prime_check) do |data, is_prime|
        # CPU-bound処理の例: 各要素の素数判定
        data.map do |n|
          { number: n, prime: is_prime.call(n) }
        end
      end
    end

    # Fan-in: 全ワーカーの結果を集約
    workers.flat_map(&:value)
  end

  # 素数判定（CPU-bound処理の例）
  def self.prime?(n)
    return false if n < 2
    return true if n < 4

    (2..Math.sqrt(n).to_i).none? { |i| (n % i).zero? }
  end

  # ==========================================================================
  # 5. Ractor.select: 複数Ractorの同時待機
  # ==========================================================================

  # Ractor.select は Ractor を渡すと、そのRactorが終了した時点で
  # [Ractor, 戻り値] を返す（Ruby 4.0では Ractor と Port だけを受け付ける）
  # 複数のRactorが並列に動作し、完了した順に結果を回収できる
  def self.select_from_multiple_ractors(tasks)
    # 各タスクを処理するRactorを生成
    ractors = tasks.map do |task|
      Ractor.new(task) do |t|
        # シミュレーション: タスクごとに異なる処理時間
        t[:value] * t[:multiplier]
      end
    end

    # Ractor.select で完了した順に結果を収集
    results = []
    remaining = ractors.dup

    remaining.size.times do
      completed_ractor, value = Ractor.select(*remaining)
      results << value
      remaining.delete(completed_ractor)
    end

    results
  end

  # ==========================================================================
  # 6. Thread vs Ractor の比較
  # ==========================================================================

  # Thread: I/O-bound処理に適している
  # GVLがあるため、CPU-bound処理では真の並列化は不可能
  # ただしI/O待ちの間はGVLが解放されるため、I/O多重化には有効
  def self.thread_io_bound_example(urls_count)
    results = []
    mutex = Mutex.new

    threads = urls_count.times.map do |i|
      Thread.new(i) do |index|
        # I/O待ちのシミュレーション
        sleep(0.01)
        result = "Thread #{index}: I/O完了"
        mutex.synchronize { results << result }
      end
    end

    threads.each(&:join)
    results.sort
  end

  # Ractor: CPU-bound処理に適している
  # 各RactorはGVLを持たず、真の並列実行が可能
  def self.ractor_cpu_bound_example(numbers)
    # Ractor内ではモジュールメソッドを直接呼べないため、lambdaとして渡す
    fib_calc = Ractor.make_shareable(
      lambda do |n|
        fn = lambda do |x|
          return x if x <= 1

          fn.call(x - 1) + fn.call(x - 2)
        end
        fn.call(n)
      end
    )

    ractors = numbers.map do |n|
      Ractor.new(n, fib_calc) do |num, calc|
        # CPU-bound処理: フィボナッチ計算
        calc.call(num)
      end
    end

    ractors.map(&:value)
  end

  # フィボナッチ計算（CPU-bound処理の例）
  def self.fib(n)
    return n if n <= 1

    fib(n - 1) + fib(n - 2)
  end

  # ==========================================================================
  # 7. 制限事項と注意点
  # ==========================================================================

  # 定数アクセスの制限
  # Ractor内から外部の定数にアクセスするには、定数がshareable である必要がある
  SHAREABLE_CONSTANT = 'この定数はfrozenなので共有可能'
  SHAREABLE_ARRAY = Ractor.make_shareable([1, 2, 3])

  def self.constant_access_in_ractor
    ractor = Ractor.new do
      # frozen_string_literal: true のおかげで文字列定数はshareable
      RactorParallel::SHAREABLE_CONSTANT
    end
    ractor.value
  end

  # Ractor内ではクラス変数・グローバル変数へのアクセスが制限される
  # これは複数のRactorからの同時アクセスによるデータ競合を防ぐため
  #
  # 制限の例:
  #   - Ractor内からの非shareableなグローバル変数への書き込みはエラー
  #   - Ractor内からのクラス変数へのアクセスは制限される
  #   - Ractor内からの他Ractorが所有するオブジェクトへのアクセスは不可
  #
  # これらの制限はRactorの安全性を保証するために不可欠であり、
  # 共有状態によるデータ競合を設計レベルで排除している。
  def self.demonstrate_isolation_error
    # Ractor間でオブジェクトを共有しようとした際の分離エラーを示す例
    #
    # send(obj, move: false) はコピーを試みるが、コピー不可能なオブジェクト
    # （例: Mutex, IO, Proc等）はエラーになる。
    # また、Ractor.make_shareable も mutable なオブジェクトを含む場合にエラーを起こす。

    # Mutexはコピーもmake_shareableも不可能なオブジェクト
    mutex = Mutex.new
    Ractor.make_shareable(mutex)
  rescue TypeError, Ractor::Error, FrozenError => e
    { error_class: e.class.name, message: e.message }
  end

  # ==========================================================================
  # パイプラインパターン: Ractorを直列に接続して処理パイプラインを構築
  # ==========================================================================

  # ステージ1 → ステージ2 のパイプライン
  # ステージ間は Ractor#send で直接つなぎ、最終結果は Port で呼び出し側へ返す
  def self.pipeline_pattern(input_values)
    count = input_values.size
    results_port = Ractor::Port.new

    # ステージ2: ステージ1の結果に10を加算して結果 Port へ送る
    stage2 = Ractor.new(results_port, count) do |out, n|
      n.times { out << (Ractor.receive + 10) }
    end

    # ステージ1: 値を2倍にしてステージ2へ送る
    stage1 = Ractor.new(stage2, count) do |next_stage, n|
      n.times { next_stage.send(Ractor.receive * 2) }
    end

    # 入力値をステージ1に送る
    input_values.each { |v| stage1.send(v) }

    # 先に両ステージの終了を待ち、途中の例外を呼び出し側へ伝える（Port は送られた値をためておく）
    stage1.value
    stage2.value

    # 結果を収集
    Array.new(count) { results_port.receive }
  end
end
