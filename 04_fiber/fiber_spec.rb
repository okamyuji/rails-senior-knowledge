# frozen_string_literal: true

require_relative 'fiber'

RSpec.describe FiberInternals do
  describe FiberInternals::BasicFiber do
    describe '.demonstrate_resume_yield' do
      it 'resume/yieldで値を双方向にやり取りできる' do
        results = described_class.demonstrate_resume_yield

        expect(results).to eq([
                                '受信: こんにちは',
                                '応答: 最初の応答',
                                '受信: 次のデータ',
                                '応答: 最終結果'
                              ])
      end
    end

    describe '.demonstrate_accumulator' do
      it 'resumeのたびに渡された値を蓄積して返す' do
        expect(described_class.demonstrate_accumulator).to eq([10, 15, 18])
      end
    end
  end

  describe FiberInternals::FiberStates do
    describe '.demonstrate_lifecycle' do
      it 'Fiberの4つのフェーズをalive?で追跡する' do
        states = described_class.demonstrate_lifecycle

        expect(states[0]).to eq({ phase: :created, alive: true })
        expect(states[1]).to eq({ phase: :was_running, alive: true })
        expect(states[2]).to eq({ phase: :suspended, alive: true })
        expect(states[3]).to eq({ phase: :dead, alive: false })
      end
    end

    describe '.demonstrate_dead_fiber_error' do
      it '完了したFiberをresumeするとFiberErrorのメッセージを返す' do
        message = described_class.demonstrate_dead_fiber_error

        expect(message).to include('terminated fiber').or include('dead fiber')
      end
    end
  end

  describe FiberInternals::FiberCoroutine do
    describe '.demonstrate_producer_consumer' do
      it 'Producer-Consumerパターンで全アイテムを消費する' do
        consumed = described_class.demonstrate_producer_consumer

        expect(consumed).to eq([
                                 '消費: りんご',
                                 '消費: みかん',
                                 '消費: ぶどう'
                               ])
      end
    end

    describe '.demonstrate_pipeline' do
      it 'パイプラインで値を順番に変換する' do
        results = described_class.demonstrate_pipeline

        expect(results).to eq(['値: 2', '値: 4', '値: 6', '値: 8', '値: 10'])
      end
    end

    describe '.demonstrate_transfer' do
      it 'Fiber#transferで対称的に制御を移動する' do
        log = described_class.demonstrate_transfer

        expect(log).to eq(%w[A-1 B-1 A-2 B-2 A-3])
      end
    end
  end

  describe FiberInternals::FiberSchedulerInterface do
    describe '.scheduler_interface_methods' do
      it 'Fiber::Schedulerに必要なインターフェースメソッドを返す' do
        methods = described_class.scheduler_interface_methods

        expect(methods).to include(:io_wait, :kernel_sleep, :close, :fiber)
      end
    end

    describe '.demonstrate_minimal_scheduler' do
      it 'MinimalSchedulerのイベントログを正しく記録する' do
        log = described_class.demonstrate_minimal_scheduler

        expect(log).to eq([
                            'sleep要求: 0.1秒',
                            'io_wait要求: events=1, timeout=0.5',
                            'スケジューラー終了'
                          ])
      end
    end
  end

  describe FiberInternals::NonBlockingConcept do
    describe '.demonstrate_nonblocking_simulation' do
      it 'Fiberで疑似的なノンブロッキング並行処理を実現する' do
        result = described_class.demonstrate_nonblocking_simulation

        expect(result[:results]).to eq(%w[タスク1の結果 タスク2の結果])
        expect(result[:order]).to eq([
                                       'task1: 開始',
                                       'task2: 開始',
                                       'task1: 完了',
                                       'task2: 完了'
                                     ])
      end
    end

    describe '.demonstrate_blocking_attribute' do
      it 'blockingとnon-blockingのFiberを区別できる' do
        result = described_class.demonstrate_blocking_attribute

        expect(result[:blocking]).to be true
        expect(result[:non_blocking]).to be false
      end
    end
  end

  describe FiberInternals::FiberVsThreadStorage do
    describe '.demonstrate_storage_difference' do
      it 'Fiber[]はFiberローカル、Thread[]はスレッド共有であることを示す' do
        results = described_class.demonstrate_storage_difference

        child = results[:child_fiber]
        expect(child[:thread_visible]).to eq('スレッド値')
        expect(child[:own_value]).to eq('子Fiber独自値')
        expect(child[:modified_value]).to eq('変更後の値')
        expect(results[:main_fiber_value]).to be_nil
      end
    end

    describe '.demonstrate_fiber_storage_inheritance' do
      it 'Fiberストレージの継承と分離を正しく動作させる' do
        result = described_class.demonstrate_fiber_storage_inheritance

        expect(result[:inherited]).to eq('親の値')
        expect(result[:isolated]).to eq('未継承')
      end
    end
  end

  describe FiberInternals::EnumeratorAsFiber do
    describe '.demonstrate_enumerator_uses_fiber' do
      it 'Enumerator.newでFiberベースの遅延評価を行う' do
        results = described_class.demonstrate_enumerator_uses_fiber

        expect(results).to eq(%w[第一要素 第二要素 第三要素])
      end
    end

    describe '.demonstrate_lazy_enumerator' do
      it '遅延Enumeratorで無限列から必要な分だけ取得する' do
        result = described_class.demonstrate_lazy_enumerator

        expect(result).to eq([2, 2, 6, 10, 26])
      end
    end

    describe '.demonstrate_equivalence' do
      it 'FiberとEnumeratorが同等の動作をすることを示す' do
        result = described_class.demonstrate_equivalence

        expect(result[:fiber]).to eq([0, 1, 2, 3, 4])
        expect(result[:enumerator]).to eq([0, 1, 2, 3, 4])
        expect(result[:equivalent]).to be true
      end
    end
  end
end
