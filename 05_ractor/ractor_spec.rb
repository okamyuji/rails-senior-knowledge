# frozen_string_literal: true

require_relative '../spec/spec_helper'
require_relative 'ractor'

# Ractorはまだexperimentalな機能であるため、環境によっては利用できない。
# テストの安定性を確保するため、Ractorが利用可能かどうかを事前にチェックする。
RACTOR_AVAILABLE = defined?(Ractor) && begin
  r = Ractor.new { 1 }
  r.take == 1
rescue StandardError
  false
end

RSpec.describe RactorParallel do
  before do
    skip 'Ractorが利用できない環境です' unless RACTOR_AVAILABLE
  end

  # ---------------------------------------------------------------------------
  # 1. push型通信のテスト
  # ---------------------------------------------------------------------------
  describe '.push_style_communication' do
    it 'sendで送ったメッセージをRactor内で受信し結果を返す' do
      result = described_class.push_style_communication('こんにちは')
      expect(result).to eq('受信: こんにちは')
    end

    it '数値メッセージも正しく処理する' do
      result = described_class.push_style_communication(42)
      expect(result).to eq('受信: 42')
    end
  end

  # ---------------------------------------------------------------------------
  # 2. pull型通信のテスト
  # ---------------------------------------------------------------------------
  describe '.pull_style_communication' do
    it '引数で渡した値を2倍にして返す' do
      result = described_class.pull_style_communication(21)
      expect(result).to eq(42)
    end
  end

  # ---------------------------------------------------------------------------
  # 3. 双方向通信のテスト
  # ---------------------------------------------------------------------------
  describe '.bidirectional_communication' do
    it '複数の文字列をすべて大文字に変換して返す' do
      result = described_class.bidirectional_communication(%w[hello world ruby])
      expect(result).to eq(%w[HELLO WORLD RUBY])
    end
  end

  # ---------------------------------------------------------------------------
  # 4. 共有可能オブジェクトの確認テスト
  # ---------------------------------------------------------------------------
  describe '.check_shareable_objects' do
    it '各オブジェクトの共有可能性を正しく判定する' do
      results = described_class.check_shareable_objects

      # 数値、Symbol、frozen文字列は共有可能
      expect(results[:integer]).to be true
      expect(results[:float]).to be true
      expect(results[:symbol]).to be true
      expect(results[:frozen_string]).to be true

      # mutableな文字列は共有不可
      expect(results[:mutable_string]).to be false

      # true, false, nil は共有可能
      expect(results[true]).to be true
      expect(results[false]).to be true
      expect(results[:nil]).to be true
    end
  end

  # ---------------------------------------------------------------------------
  # 5. make_shareableのテスト
  # ---------------------------------------------------------------------------
  describe '.make_object_shareable' do
    it '配列とその要素をすべてfreezeして共有可能にする' do
      result = described_class.make_object_shareable

      expect(result[:shareable]).to be true
      expect(result[:frozen]).to be true
      expect(result[:elements_frozen]).to be true
    end
  end

  # ---------------------------------------------------------------------------
  # 6. コピーセマンティクスのテスト
  # ---------------------------------------------------------------------------
  describe '.demonstrate_copy_semantics' do
    it 'sendでコピーされるため元のオブジェクトは変更されない' do
      result = described_class.demonstrate_copy_semantics

      expect(result[:original]).to eq([1, 2, 3])
      expect(result[:modified]).to eq([1, 2, 3, 4])
      expect(result[:different_objects]).to be true
    end
  end

  # ---------------------------------------------------------------------------
  # 7. moveセマンティクスのテスト
  # ---------------------------------------------------------------------------
  describe '.demonstrate_move_semantics' do
    it 'move後に元のオブジェクトにアクセスするとMovedErrorが発生する' do
      result = described_class.demonstrate_move_semantics

      expect(result[:modified]).to eq([1, 2, 3, 4])
      expect(result[:original_moved]).to be true
    end
  end

  # ---------------------------------------------------------------------------
  # 8. 並列計算（Fan-out/Fan-in）のテスト
  # ---------------------------------------------------------------------------
  describe '.parallel_computation' do
    it '複数のRactorで素数判定を並列に実行する' do
      numbers = [2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
      results = described_class.parallel_computation(numbers, worker_count: 2)

      # 結果を数値でソートして検証
      sorted = results.sort_by { |r| r[:number] }

      expect(sorted.select { |r| r[:prime] }.map { |r| r[:number] })
        .to eq([2, 3, 5, 7, 11])
      expect(sorted.reject { |r| r[:prime] }.map { |r| r[:number] })
        .to eq([4, 6, 8, 9, 10])
    end
  end

  # ---------------------------------------------------------------------------
  # 9. Ractor.selectのテスト
  # ---------------------------------------------------------------------------
  describe '.select_from_multiple_ractors' do
    it '複数のRactorの結果を収集する' do
      tasks = [
        { value: 2, multiplier: 3 },
        { value: 5, multiplier: 4 },
        { value: 10, multiplier: 2 }
      ]

      results = described_class.select_from_multiple_ractors(tasks)

      # 順序は不定だが、すべての結果が含まれること
      expect(results.sort).to eq([6, 20, 20])
    end
  end

  # ---------------------------------------------------------------------------
  # 10. Thread（I/O-bound）のテスト
  # ---------------------------------------------------------------------------
  describe '.thread_io_bound_example' do
    it '複数スレッドで並行にI/O処理を実行する' do
      results = described_class.thread_io_bound_example(3)

      expect(results.size).to eq(3)
      expect(results).to all(match(%r{Thread \d+: I/O完了}))
    end
  end

  # ---------------------------------------------------------------------------
  # 11. 定数アクセスのテスト
  # ---------------------------------------------------------------------------
  describe '.constant_access_in_ractor' do
    it 'shareableな定数にRactor内からアクセスできる' do
      result = described_class.constant_access_in_ractor
      expect(result).to eq('この定数はfrozenなので共有可能')
    end
  end

  # ---------------------------------------------------------------------------
  # 12. パイプラインパターンのテスト
  # ---------------------------------------------------------------------------
  describe '.pipeline_pattern' do
    it '値を2倍にしてから10を加算するパイプラインを実行する' do
      results = described_class.pipeline_pattern([1, 2, 3])

      # ステージ1: *2 → [2, 4, 6]
      # ステージ2: +10 → [12, 14, 16]
      expect(results).to eq([12, 14, 16])
    end
  end

  # ---------------------------------------------------------------------------
  # 13. 分離エラーのテスト
  # ---------------------------------------------------------------------------
  describe '.demonstrate_isolation_error' do
    it '非shareableなオブジェクトを渡すとエラー情報を返す' do
      result = described_class.demonstrate_isolation_error

      # Rubyのバージョンによってエラークラスが異なる可能性がある
      expect(result).to have_key(:error_class)
      expect(result).to have_key(:message)
    end
  end
end
