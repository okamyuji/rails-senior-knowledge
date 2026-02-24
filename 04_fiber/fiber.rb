# frozen_string_literal: true

# Fiberの内部構造とFiber::Schedulerの仕組み
#
# Fiberはユーザー空間の軽量な協調的コンテキストスイッチ機構。
# Ruby 3.0以降、Fiber::SchedulerインターフェースによりノンブロッキングI/Oが実現可能。
module FiberInternals
  # ==========================================================================
  # 1. 基本的なFiber: 生成、resume/yield、値の受け渡し
  # ==========================================================================
  module BasicFiber
    # Fiber.newで生成し、resumeで実行開始、Fiber.yieldで中断する
    # resume/yieldの間で値を双方向にやり取りできる
    def self.demonstrate_resume_yield
      results = []

      fiber = Fiber.new do |first_value|
        results << "受信: #{first_value}"
        second_value = Fiber.yield('最初の応答')
        results << "受信: #{second_value}"
        '最終結果'
      end

      # resumeで値をFiberに渡し、Fiber.yieldの返り値を受け取る
      response1 = fiber.resume('こんにちは')
      results << "応答: #{response1}"

      response2 = fiber.resume('次のデータ')
      results << "応答: #{response2}"

      results
      # => ["受信: こんにちは", "応答: 最初の応答", "受信: 次のデータ", "応答: 最終結果"]
    end

    # Fiberを使った値の累積パターン
    # resumeのたびに渡された値を蓄積して返す
    def self.demonstrate_accumulator
      fiber = Fiber.new do |initial|
        sum = initial
        loop do
          value = Fiber.yield(sum)
          sum += value
        end
      end

      r1 = fiber.resume(10)  # => 10 (初期値)
      r2 = fiber.resume(5)   # => 15
      r3 = fiber.resume(3)   # => 18
      [r1, r2, r3]
    end
  end

  # ==========================================================================
  # 2. Fiberの状態遷移: created → running → suspended → dead
  # ==========================================================================
  module FiberStates
    # Fiberのライフサイクルを順を追って確認する
    # alive?メソッドで生存状態を、実行フェーズの追跡で論理的な状態を確認する
    # - created:   Fiber.newで生成直後（alive? == true, まだresumeされていない）
    # - running:   resume中（Fiber内部から見た状態、alive? == true）
    # - suspended: Fiber.yieldで中断中（alive? == true, resumeで再開可能）
    # - dead:      ブロック実行完了後（alive? == false）
    def self.demonstrate_lifecycle
      states = []
      running_alive = nil

      fiber = Fiber.new do
        # running状態でのalive?を内部から確認
        running_alive = Fiber.current.alive?
        Fiber.yield
        '完了'
      end

      # created状態（生成済み・未開始）
      states << { phase: :created, alive: fiber.alive? }

      # resumeするとrunning → yieldでsuspendedになる
      fiber.resume
      states << { phase: :was_running, alive: running_alive }
      states << { phase: :suspended, alive: fiber.alive? }

      # 再度resumeすると実行完了 → dead
      fiber.resume
      states << { phase: :dead, alive: fiber.alive? }

      states
      # => [
      #   { phase: :created,     alive: true  },
      #   { phase: :was_running, alive: true  },
      #   { phase: :suspended,   alive: true  },
      #   { phase: :dead,        alive: false }
      # ]
    end

    # 完了したFiberをresumeするとFiberErrorが発生する
    def self.demonstrate_dead_fiber_error
      fiber = Fiber.new { 'done' }
      fiber.resume
      begin
        fiber.resume
      rescue FiberError => e
        e.message
      end
      # => "attempt to resume a terminated fiber"
    end
  end

  # ==========================================================================
  # 3. Fiberによるコルーチン: 協調的マルチタスクパターン
  # ==========================================================================
  module FiberCoroutine
    # Producer-Consumerパターン
    # ProducerがFiber.yieldでデータを提供し、Consumerがresumeで取得する
    def self.demonstrate_producer_consumer
      consumed = []

      # プロデューサー: 値を順番に生成する
      producer = Fiber.new do
        %w[りんご みかん ぶどう].each do |fruit|
          Fiber.yield(fruit)
        end
        nil # 生産終了のシグナル
      end

      # コンシューマー: プロデューサーから値を取得し処理する
      while (item = producer.resume)
        consumed << "消費: #{item}"
      end

      consumed
      # => ["消費: りんご", "消費: みかん", "消費: ぶどう"]
    end

    # パイプラインパターン: 複数のFiberをチェーンして変換処理を行う
    def self.demonstrate_pipeline
      # ステージ1: 数値を生成する
      generator = Fiber.new do
        (1..5).each { |n| Fiber.yield(n) }
        nil
      end

      # ステージ2: 数値を2倍にする
      doubler = Fiber.new do
        while (n = generator.resume)
          Fiber.yield(n * 2)
        end
        nil
      end

      # ステージ3: 文字列に変換する
      results = []
      while (n = doubler.resume)
        results << "値: #{n}"
      end

      results
      # => ["値: 2", "値: 4", "値: 6", "値: 8", "値: 10"]
    end

    # Fiber#transferによる対称的コルーチン
    # resumeは非対称（呼び出し側→Fiber）だが、transferは任意のFiber間で制御を移動できる
    def self.demonstrate_transfer
      log = []
      fiber_b = nil

      fiber_a = Fiber.new do
        log << 'A-1'
        fiber_b.transfer
        log << 'A-2'
        fiber_b.transfer
        log << 'A-3'
      end

      fiber_b = Fiber.new do
        log << 'B-1'
        fiber_a.transfer
        log << 'B-2'
        fiber_a.transfer
        log << 'B-3'
      end

      # transferで開始（resumeではなくtransferを使う）
      fiber_a.transfer

      log
      # => ["A-1", "B-1", "A-2", "B-2", "A-3"]
    end
  end

  # ==========================================================================
  # 4. Fiber::Schedulerインターフェース
  # ==========================================================================
  module FiberSchedulerInterface
    # Fiber::Schedulerに必要なメソッド一覧を返す
    # 実際のスケジューラーはこれらのメソッドを実装する必要がある
    def self.scheduler_interface_methods
      %i[
        io_wait
        io_read
        io_write
        io_select
        kernel_sleep
        address_resolve
        block
        unblock
        close
        process_wait
        fiber
      ]
    end

    # 最小限のFiber::Schedulerの実装
    # kernel_sleepとcloseのみ実装し、スケジューラーの基本概念を示す
    class MinimalScheduler
      attr_reader :event_log

      def initialize
        @event_log = []
        @waiting_fibers = []
        @ready_fibers = []
      end

      # kernel_sleep: sleepが呼ばれた時にスケジューラーが介入する
      # 実際にはブロックせず、待機リストに登録して他のFiberに制御を移す
      def kernel_sleep(duration = nil)
        @event_log << "sleep要求: #{duration}秒"
        fiber = Fiber.current
        @waiting_fibers << { fiber: fiber, wake_at: current_time + (duration || 0) }
        # 他のFiberに制御を移す（実際のスケジューラーではここでイベントループに戻る）
      end

      # block/unblock: 同期プリミティブ用のコールバック
      def block(_blocker, timeout = nil)
        @event_log << "block要求: timeout=#{timeout}"
      end

      def unblock(_blocker, fiber)
        @event_log << "unblock要求: #{fiber}"
        @ready_fibers << fiber
      end

      # io_wait: I/O待機時にスケジューラーが介入する
      def io_wait(_io, events, timeout = nil)
        @event_log << "io_wait要求: events=#{events}, timeout=#{timeout}"
      end

      # close: スケジューラー終了時に呼ばれる
      # 残っている待機Fiberをすべて処理する
      def close
        @event_log << 'スケジューラー終了'
      end

      # fiber: スケジューラー管理下でFiberを生成する
      def fiber(&)
        f = Fiber.new(blocking: false, &)
        f.resume
        f
      end

      private

      def current_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end

    # MinimalSchedulerの動作を検証する
    def self.demonstrate_minimal_scheduler
      scheduler = MinimalScheduler.new

      # スケジューラーのメソッドを直接呼び出して動作を確認
      scheduler.kernel_sleep(0.1)
      scheduler.io_wait(nil, 1, 0.5)
      scheduler.close

      scheduler.event_log
      # => ["sleep要求: 0.1秒", "io_wait要求: events=1, timeout=0.5", "スケジューラー終了"]
    end
  end

  # ==========================================================================
  # 5. ノンブロッキングI/Oの概念
  # ==========================================================================
  module NonBlockingConcept
    # Fiber::Schedulerによるノンブロッキングの仕組みを疑似的に再現
    # コールバックなしで並行処理を実現するパターン
    def self.demonstrate_nonblocking_simulation
      results = []
      execution_order = []

      # 疑似的なタスクをFiberで表現
      task1 = Fiber.new do
        execution_order << 'task1: 開始'
        Fiber.yield # I/O待機をシミュレート
        execution_order << 'task1: 完了'
        'タスク1の結果'
      end

      task2 = Fiber.new do
        execution_order << 'task2: 開始'
        Fiber.yield # I/O待機をシミュレート
        execution_order << 'task2: 完了'
        'タスク2の結果'
      end

      # スケジューラー的にFiberをラウンドロビンで実行
      task1.resume  # task1開始 → yield
      task2.resume  # task2開始 → yield
      results << task1.resume  # task1完了
      results << task2.resume  # task2完了

      { results: results, order: execution_order }
      # => {
      #   results: ["タスク1の結果", "タスク2の結果"],
      #   order: ["task1: 開始", "task2: 開始", "task1: 完了", "task2: 完了"]
      # }
    end

    # blocking vs non-blockingファイバーの違い
    def self.demonstrate_blocking_attribute
      blocking_fiber = Fiber.new(blocking: true) { Fiber.current.blocking? }
      non_blocking_fiber = Fiber.new(blocking: false) { Fiber.current.blocking? }

      {
        blocking: blocking_fiber.resume,
        non_blocking: non_blocking_fiber.resume
      }
      # => { blocking: true, non_blocking: false }
    end
  end

  # ==========================================================================
  # 6. Fiber-local vs Thread-localストレージ
  # ==========================================================================
  module FiberVsThreadStorage
    # Ruby 3.2+ のストレージの3層構造:
    #
    # 1. Fiber[:key] / Fiber[:key] = value
    #    - Fiberストレージ（Fiberごとに独立）
    #    - 子Fiberは親のストレージを継承（コピー）
    #    - storage: {} を指定すると空のストレージで開始
    #
    # 2. Thread.current[:key]
    #    - 実はFiberローカル（Ruby 3.x以降）
    #    - 他のFiberからは見えない
    #
    # 3. Thread.current.thread_variable_get(:key)
    #    - 真のスレッドローカル（Cレベル）
    #    - 全Fiberから参照可能
    def self.demonstrate_storage_difference
      results = {}

      # thread_variable_set: 真のスレッドローカル（全Fiberから参照可能）
      Thread.current.thread_variable_set(:shared_value, 'スレッド値')

      # storage: {} で独自のストレージを持つFiberを生成
      fiber_isolated = Fiber.new(storage: { fiber_value: '子Fiber独自値' }) do
        # thread_variable_getはスレッド全体で共有されるので見える
        thread_visible = Thread.current.thread_variable_get(:shared_value)

        # Fiber[]は独自のストレージから取得
        own_value = Fiber[:fiber_value]

        # 値を変更しても親には影響しない
        Fiber[:fiber_value] = '変更後の値'
        modified_value = Fiber[:fiber_value]

        Fiber.yield({
                      thread_visible: thread_visible,
                      own_value: own_value,
                      modified_value: modified_value
                    })
      end

      results[:child_fiber] = fiber_isolated.resume

      # メインFiberのFiber[:fiber_value]は設定していないのでnil
      results[:main_fiber_value] = Fiber[:fiber_value]

      # クリーンアップ
      Thread.current.thread_variable_set(:shared_value, nil)

      results
      # => {
      #   child_fiber: {
      #     thread_visible: "スレッド値",     # thread_variable_getは全Fiberで見える
      #     own_value: "子Fiber独自値",        # 独自に設定した値
      #     modified_value: "変更後の値"       # Fiber内で変更した値
      #   },
      #   main_fiber_value: nil               # メインFiberには影響なし
      # }
    end

    # Fiberストレージの継承と分離を示す
    def self.demonstrate_fiber_storage_inheritance
      # 親Fiberにストレージを設定（storage:で指定する必要がある）
      parent_fiber = Fiber.new(storage: { parent_key: '親の値' }) do
        # storageを指定しない子Fiberは親のストレージを継承する
        inheriting_child = Fiber.new do
          Fiber[:parent_key]
        end

        # storage: {} で空にすると親のストレージを継承しない
        isolated_child = Fiber.new(storage: {}) do
          Fiber[:parent_key].nil? ? '未継承' : Fiber[:parent_key]
        end

        {
          inherited: inheriting_child.resume,
          isolated: isolated_child.resume
        }
      end

      parent_fiber.resume
      # => { inherited: "親の値", isolated: "未継承" }
    end

    # Thread.current[] vs Thread#thread_variable_get の重要な違い
    def self.demonstrate_thread_variable_methods
      # Thread.current[]: 実はFiberローカル（他のFiberからは見えない！）
      # thread_variable_get/set: 真のスレッドローカル（Cレベル、全Fiberで共有）
      Thread.current.thread_variable_set(:true_thread_local, '真のスレッド値')
      Thread.current[:bracket_value] = 'bracket値'

      fiber = Fiber.new do
        {
          # thread_variable_getはスレッドレベルで共有（全Fiberで見える）
          thread_var: Thread.current.thread_variable_get(:true_thread_local),
          # Thread.current[]はFiberローカル（他のFiberでは見えない！）
          thread_bracket: Thread.current[:bracket_value]
        }
      end

      result = fiber.resume

      # クリーンアップ
      Thread.current.thread_variable_set(:true_thread_local, nil)
      Thread.current[:bracket_value] = nil

      result
      # => { thread_var: "真のスレッド値", thread_bracket: nil }
    end
  end

  # ==========================================================================
  # 7. EnumeratorとFiberの関係
  # ==========================================================================
  module EnumeratorAsFiber
    # EnumeratorはFiberを内部で使用して遅延評価を実現している
    def self.demonstrate_enumerator_uses_fiber
      # Enumerator.newはブロック内でyielderを使い、内部的にFiberで動作する
      enum = Enumerator.new do |yielder|
        yielder << '第一要素'
        yielder << '第二要素'
        yielder << '第三要素'
      end

      # nextで1つずつ取得（内部でFiber.resumeが呼ばれる）
      results = []
      results << enum.next
      results << enum.next
      results << enum.next

      results
      # => ["第一要素", "第二要素", "第三要素"]
    end

    # 遅延Enumerator (Lazy) がFiberベースであることを示す
    # 無限列でも必要な分だけ評価される
    def self.demonstrate_lazy_enumerator
      # 無限フィボナッチ数列をEnumeratorで定義
      fibonacci = Enumerator.new do |yielder|
        a = 0
        b = 1
        loop do
          yielder << a
          a, b = b, a + b
        end
      end

      # lazyで遅延評価チェーンを構築
      fibonacci.lazy
               .select(&:odd?)
               .map { |n| n * 2 }
               .first(5)

      # => [2, 2, 6, 10, 26] (奇数フィボナッチ数を2倍: 1*2, 1*2, 3*2, 5*2, 13*2)
    end

    # EnumeratorとFiberの等価性を示す
    # 同じ動作をEnumeratorとFiberの両方で実装する
    def self.demonstrate_equivalence
      # Fiber版: カウンター
      fiber_counter = Fiber.new do
        n = 0
        loop do
          Fiber.yield(n)
          n += 1
        end
      end

      # Enumerator版: 同じカウンター
      enum_counter = Enumerator.new do |y|
        n = 0
        loop do
          y << n
          n += 1
        end
      end

      fiber_results = 5.times.map { fiber_counter.resume }
      enum_results = 5.times.map { enum_counter.next }

      {
        fiber: fiber_results,
        enumerator: enum_results,
        equivalent: fiber_results == enum_results
      }
      # => { fiber: [0, 1, 2, 3, 4], enumerator: [0, 1, 2, 3, 4], equivalent: true }
    end
  end
end
