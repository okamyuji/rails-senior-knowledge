# frozen_string_literal: true

require_relative 'block_proc_lambda'

RSpec.describe BlockProcLambda do
  describe 'ブロック基礎' do
    it 'yield で暗黙的ブロックを呼び出せること' do
      result = described_class.implicit_block_with_yield { |n| n * 10 }

      expect(result).to eq [10, 20, 30]
    end

    it 'block_given? でブロックの有無を判定できること' do
      with_block = described_class.safe_block_check { |n| n + 8 }
      without_block = described_class.safe_block_check

      expect(with_block).to eq 50
      expect(without_block).to eq :no_block_given
    end

    it '&block で明示的にブロックを Proc として受け取れること' do
      result = described_class.explicit_block_capture { |n| n * 5 }

      expect(result[:class_name]).to eq 'Proc'
      expect(result[:is_lambda]).to be false
      expect(result[:call_result]).to eq 50
    end

    it '暗黙的ブロックと明示的ブロックの両方が正しく動作すること' do
      result = described_class.implicit_vs_explicit_demo

      expect(result[:implicit]).to eq [10, 20, 30]
      expect(result[:explicit][:call_result]).to eq 100
    end
  end

  describe 'Proc vs Lambda の生成' do
    it 'Proc.new, lambda, スタビーラムダの違いを正しく識別できること' do
      result = described_class.proc_vs_lambda_creation

      # 全て Proc クラスだが lambda? の返り値が異なる
      expect(result[:proc_class]).to eq 'Proc'
      expect(result[:lambda_class]).to eq 'Proc'
      expect(result[:stabby_class]).to eq 'Proc'

      # Proc.new は lambda ではない
      expect(result[:proc_is_lambda]).to be false

      # lambda と -> は lambda である
      expect(result[:lambda_is_lambda]).to be true
      expect(result[:stabby_is_lambda]).to be true

      # 全て正しく呼び出せる
      expect(result[:proc_result]).to eq 'hello'
      expect(result[:lambda_result]).to eq 'world'
      expect(result[:stabby_result]).to eq 'ruby'
    end
  end

  describe '引数チェック（アリティ）' do
    it 'Proc は引数の過不足を許容し、Lambda は厳密にチェックすること' do
      result = described_class.arity_checking_demo

      # Proc: 余分な引数は無視される
      expect(result[:proc_extra_args]).to eq [1, 2]

      # Proc: 不足分は nil で埋められる
      expect(result[:proc_missing_args]).to eq [1, nil]

      # Lambda: 正しい引数では正常動作
      expect(result[:lambda_correct_args]).to eq [1, 2]

      # Lambda: 引数が合わないと ArgumentError
      expect(result[:lambda_extra_args_error]).to include('wrong number of arguments')
      expect(result[:lambda_missing_args_error]).to include('wrong number of arguments')

      # アリティ値
      expect(result[:proc_arity]).to eq 2
      expect(result[:lambda_arity]).to eq 2
    end
  end

  describe 'return の挙動' do
    it 'Proc の return はメソッドを抜け、Lambda の return は Lambda 内で完結すること' do
      result = described_class.return_behavior_comparison

      # Proc の return はメソッド自体から :from_proc を返す
      expect(result[:proc_return]).to eq :from_proc

      # Lambda の return 後もメソッドの続きが実行される
      expect(result[:lambda_return]).to eq :after_lambda
    end
  end

  describe 'クロージャとしての性質' do
    it 'Lambda が外側のスコープの変数を共有・変更できること' do
      result = described_class.closure_demo

      # incrementer が3回呼ばれたので counter は 3
      expect(result[:counter_value]).to eq 3
      expect(result[:same_binding]).to be true
    end

    it 'Proc が定義時のローカル変数への束縛を保持すること' do
      result = described_class.binding_capture_demo

      expect(result[:from_proc]).to eq 'captured'
      expect(result[:from_binding]).to eq 'captured'
      expect(result[:binding_class]).to eq 'Binding'
    end
  end

  describe 'Method オブジェクト' do
    it 'method(:name) で Method オブジェクトを取得し & で Proc 変換できること' do
      result = described_class.method_object_demo

      expect(result[:method_class]).to eq 'Method'
      expect(result[:method_call]).to eq 'HELLO'
      # String#upcase は可変長引数を受け付けるためアリティは -1
      expect(result[:method_arity]).to eq(-1)
      expect(result[:map_with_method]).to eq %w[HELLO WORLD RUBY]
      expect(result[:to_proc_class]).to eq 'Proc'
    end

    it 'UnboundMethod を bind_call で特定インスタンスに束縛して呼び出せること' do
      result = described_class.unbound_method_demo

      expect(result[:unbound_class]).to eq 'UnboundMethod'
      expect(result[:bound_result]).to eq 5
      expect(result[:owner]).to eq 'String'
    end
  end

  describe 'カリー化' do
    it 'Proc#curry で段階的な部分適用ができること' do
      result = described_class.currying_demo

      # 2 * 3 + 4 = 10
      expect(result[:step_by_step]).to eq 10
      expect(result[:direct]).to eq 10

      # 税率10%の部分適用
      expect(result[:tax_100]).to eq 110.0
      expect(result[:tax_250]).to eq 275.0
      expect(result[:is_curried]).to eq 'Proc'
    end
  end

  describe 'メモリに関する考慮事項' do
    it 'クロージャが外側のスコープへの参照を保持することを確認できること' do
      result = described_class.memory_leak_pattern_demo

      # 両方とも同じ結果を返す
      expect(result[:leaky_result]).to eq 1000
      expect(result[:safe_result]).to eq 1000

      # leaky_proc は large_data への参照を保持している
      expect(result[:leaky_captures_large_data]).to be true

      # safe_proc は長さの値だけを保持している
      expect(result[:safe_captures_only_length]).to eq 1000
    end

    it 'コールバックの登録・実行・解除のライフサイクルが正しく機能すること' do
      result = described_class.callback_lifecycle_demo

      expect(result[:callback_results]).to eq [
        ['on_save', :saved],
        ['on_load', :loaded]
      ]
      expect(result[:callbacks_cleared]).to be true
    end
  end
end
