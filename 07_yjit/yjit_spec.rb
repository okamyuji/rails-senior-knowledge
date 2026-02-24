# frozen_string_literal: true

require_relative '../spec/spec_helper'
require_relative 'yjit'

RSpec.describe YjitOptimization do
  # --------------------------------------------------------------------------
  # YJIT利用可能性チェック
  # --------------------------------------------------------------------------

  describe '.check_yjit_availability' do
    it 'Ruby環境の基本情報を含むHashを返す' do
      result = described_class.check_yjit_availability

      expect(result).to be_a(Hash)
      expect(result[:ruby_version]).to eq(RUBY_VERSION)
      expect(result[:ruby_platform]).to eq(RUBY_PLATFORM)
      expect(result).to have_key(:yjit_defined)
      expect(result).to have_key(:yjit_enabled)
      expect(result).to have_key(:yjit_version)
    end

    it 'yjit_definedがBoolean値を返す' do
      result = described_class.check_yjit_availability

      expect([true, false]).to include(result[:yjit_defined])
    end
  end

  # --------------------------------------------------------------------------
  # YJIT統計情報
  # --------------------------------------------------------------------------

  describe '.fetch_runtime_stats' do
    context 'YJITが無効の場合' do
      before do
        skip 'YJITが有効な環境ではスキップ' if defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
      end

      it '無効状態のステータスを返す' do
        result = described_class.fetch_runtime_stats

        expect(result[:status]).to eq(:yjit_disabled)
        expect(result[:message]).to be_a(String)
      end
    end

    context 'YJITが有効の場合' do
      before do
        skip 'YJIT not enabled' unless defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
      end

      it 'コンパイル済みコードの統計情報を返す' do
        result = described_class.fetch_runtime_stats

        expect(result[:status]).to eq(:yjit_enabled)
        expect(result).to have_key(:compiled_iseq_count)
        expect(result).to have_key(:compiled_block_count)
        expect(result).to have_key(:inline_code_size)
        expect(result).to have_key(:raw_stats)
      end
    end
  end

  # --------------------------------------------------------------------------
  # モノモーフィックな演算
  # --------------------------------------------------------------------------

  describe '.monomorphic_sum' do
    it '整数配列の合計値を正しく計算する' do
      expect(described_class.monomorphic_sum([1, 2, 3, 4, 5])).to eq(15)
    end

    it '空配列に対して0を返す' do
      expect(described_class.monomorphic_sum([])).to eq(0)
    end

    it '負の数を含む配列も正しく計算する' do
      expect(described_class.monomorphic_sum([-1, 0, 1])).to eq(0)
    end
  end

  # --------------------------------------------------------------------------
  # ポリモーフィックな文字列化
  # --------------------------------------------------------------------------

  describe '.polymorphic_stringify' do
    it '異なる型のオブジェクトを文字列として連結する' do
      items = [1, 'hello', 3.14, :symbol]
      result = described_class.polymorphic_stringify(items)

      expect(result).to eq('1hello3.14symbol')
    end

    it '空配列に対して空文字列を返す' do
      expect(described_class.polymorphic_stringify([])).to eq('')
    end
  end

  # --------------------------------------------------------------------------
  # YJIT最適パターン
  # --------------------------------------------------------------------------

  describe '.yjit_friendly_pattern' do
    it 'データ配列をフォーマットされた文字列配列に変換する' do
      data = [
        { name: 'Alice', score: 95 },
        { name: 'Bob', score: 87 }
      ]
      result = described_class.yjit_friendly_pattern(data)

      expect(result).to eq(['Alice: 95点', 'Bob: 87点'])
    end

    it '空配列に対して空配列を返す' do
      expect(described_class.yjit_friendly_pattern([])).to eq([])
    end
  end

  # --------------------------------------------------------------------------
  # YJIT不利パターンの説明
  # --------------------------------------------------------------------------

  describe '.yjit_unfriendly_patterns' do
    it '最適化を妨げるパターンの一覧をHashで返す' do
      patterns = described_class.yjit_unfriendly_patterns

      expect(patterns).to be_a(Hash)
      expect(patterns.keys).to include(
        :dynamic_code_evaluation,
        :excessive_metaprogramming,
        :constant_redefinition,
        :dynamic_dispatch
      )
    end

    it '各パターンにdescriptionとimpactが含まれる' do
      patterns = described_class.yjit_unfriendly_patterns

      patterns.each_value do |info|
        expect(info).to have_key(:description)
        expect(info).to have_key(:impact)
        expect(%i[high medium low]).to include(info[:impact])
      end
    end
  end

  # --------------------------------------------------------------------------
  # ベンチマーク手法
  # --------------------------------------------------------------------------

  describe '.benchmark_with_warmup' do
    it 'ブロックなしで呼び出すとArgumentErrorを発生させる' do
      expect do
        described_class.benchmark_with_warmup
      end.to raise_error(ArgumentError, 'ブロックが必要です')
    end

    it '計測結果のHashを返す' do # rubocop:disable RSpec/MultipleExpectations
      result = described_class.benchmark_with_warmup(
        warmup_iterations: 10,
        measure_iterations: 100,
        measurement_rounds: 3
      ) { 1 + 1 }

      expect(result).to be_a(Hash)
      expect(result[:warmup_iterations]).to eq(10)
      expect(result[:measure_iterations]).to eq(100)
      expect(result[:measurement_rounds]).to eq(3)
      expect(result[:elapsed_times]).to be_an(Array)
      expect(result[:elapsed_times].length).to eq(3)
      expect(result[:median_time]).to be_a(Float)
      expect(result[:min_time]).to be_a(Float)
      expect(result[:max_time]).to be_a(Float)
      expect(result[:iterations_per_second]).to be_a(Float)
      expect(result[:min_time]).to be <= result[:median_time]
      expect(result[:median_time]).to be <= result[:max_time]
    end
  end

  # --------------------------------------------------------------------------
  # 型安定性
  # --------------------------------------------------------------------------

  describe '.type_stable_fibonacci' do
    it 'フィボナッチ数列を正しく計算する' do
      # fib(0)=0, fib(1)=1, fib(2)=1, fib(3)=2, fib(4)=3, fib(5)=5, ...
      expect(described_class.type_stable_fibonacci(0)).to eq(0)
      expect(described_class.type_stable_fibonacci(1)).to eq(1)
      expect(described_class.type_stable_fibonacci(2)).to eq(1)
      expect(described_class.type_stable_fibonacci(10)).to eq(55)
      expect(described_class.type_stable_fibonacci(20)).to eq(6765)
    end
  end

  describe '.type_unstable_conversion' do
    it 'Integer入力に対して2倍のIntegerを返す' do
      expect(described_class.type_unstable_conversion(5)).to eq(10)
    end

    it 'Float入力に対して小数点2桁に丸めたFloatを返す' do
      expect(described_class.type_unstable_conversion(3.14159)).to eq(3.14)
    end

    it 'その他の型に対して文字列を返す' do
      expect(described_class.type_unstable_conversion('hello')).to eq('hello')
    end
  end

  # --------------------------------------------------------------------------
  # 定数参照
  # --------------------------------------------------------------------------

  describe '.constant_reference_demo' do
    it '定数と乗数の積を返す' do
      expect(described_class.constant_reference_demo(3)).to eq(126) # 42 * 3
      expect(described_class.constant_reference_demo(0)).to eq(0)
      expect(described_class.constant_reference_demo(-1)).to eq(-42)
    end
  end

  # --------------------------------------------------------------------------
  # レコードシリアライゼーション
  # --------------------------------------------------------------------------

  describe '.serialize_records' do
    it '指定フィールドのみを抽出したHashの配列を返す' do
      records = [
        { id: 1, name: 'Alice', email: 'alice@example.com', age: 30 },
        { id: 2, name: 'Bob', email: 'bob@example.com', age: 25 }
      ]
      fields = %i[name email]

      result = described_class.serialize_records(records, fields)

      expect(result).to eq([
                             { name: 'Alice', email: 'alice@example.com' },
                             { name: 'Bob', email: 'bob@example.com' }
                           ])
    end

    it '空のレコード配列に対して空配列を返す' do
      expect(described_class.serialize_records([], [:name])).to eq([])
    end
  end

  # --------------------------------------------------------------------------
  # ステータスサマリー
  # --------------------------------------------------------------------------

  describe '.status_summary' do
    it 'YJIT状態のサマリー文字列を返す' do
      summary = described_class.status_summary

      expect(summary).to be_a(String)
      expect(summary).to include('YJIT状態サマリー')
      expect(summary).to include('Ruby バージョン:')
      expect(summary).to include(RUBY_VERSION)
    end
  end
end
