# frozen_string_literal: true

require_relative 'tracepoint_objectspace'

RSpec.describe TracePointObjectSpace do
  describe '.demonstrate_tracepoint_events' do
    let(:result) { described_class.demonstrate_tracepoint_events }

    it 'TracePoint が :call と :return イベントをペアで記録することを確認する' do
      expect(result[:call_count]).to be >= 1
      expect(result[:return_count]).to be >= 1
      expect(result[:call_count]).to eq result[:return_count]
    end

    it 'トレース終了後に TracePoint が無効化されていることを確認する' do
      expect(result[:trace_enabled]).to be false
    end

    it '記録されたイベントに必要な情報が含まれていることを確認する' do
      expect(result[:events]).not_to be_empty
      first_event = result[:events].first
      expect(first_event).to include(:event, :method_id, :lineno, :path)
    end
  end

  describe '.demonstrate_method_tracing' do
    let(:result) { described_class.demonstrate_method_tracing }

    it 'すべてのメソッドの実行時間が計測されていることを確認する' do
      expect(result[:all_methods_traced]).to be true
      expect(result[:timings_keys]).to include(:inner_method, :leaf_method, :outer_method)
    end

    it '外側のメソッドが内側のメソッドより長い実行時間を持つことを確認する' do
      expect(result[:outer_is_slowest]).to be true
    end

    it '実行結果が正しいことを確認する' do
      expect(result[:execution_result]).to eq 5050
    end
  end

  describe '.demonstrate_exception_tracking' do
    let(:result) { described_class.demonstrate_exception_tracking }

    it 'rescue された例外も TracePoint で捕捉できることを確認する' do
      expect(result[:total_exceptions]).to be >= 2
      expect(result[:has_argument_error]).to be true
      expect(result[:has_runtime_error]).to be true
    end

    it '例外メッセージが記録されていることを確認する' do
      expect(result[:messages]).to include('不正な引数', '実行時エラー')
    end
  end

  describe '.demonstrate_each_object' do
    let(:result) { described_class.demonstrate_each_object }

    it 'ObjectSpace.each_object で特定クラスのインスタンスを列挙できることを確認する' do
      expect(result[:count_at_least_5]).to be true
      expect(result[:all_labels_present]).to be true
    end

    it 'String や Array のインスタンス数がカウントできることを確認する' do
      expect(result[:string_count]).to be_positive
      expect(result[:array_count]).to be_positive
    end
  end

  describe '.demonstrate_count_objects' do
    let(:result) { described_class.demonstrate_count_objects }

    it '主要な型のカウントが取得できることを確認する' do
      expect(result[:has_total]).to be true
      expect(result[:has_free]).to be true
      expect(result[:has_t_string]).to be true
      expect(result[:has_t_array]).to be true
      expect(result[:has_t_hash]).to be true
      expect(result[:has_t_object]).to be true
      expect(result[:has_t_class]).to be true
    end

    it 'TOTAL が正の値であり、使用中オブジェクト数が算出できることを確認する' do
      expect(result[:total_is_positive]).to be true
      expect(result[:free_is_non_negative]).to be true
      expect(result[:live_objects]).to be_positive
    end
  end

  describe '.demonstrate_allocation_tracking' do
    let(:result) { described_class.demonstrate_allocation_tracking }

    it 'オブジェクトの割り当て元ファイルと行番号が追跡できることを確認する' do
      expect(result[:all_have_source_file]).to be true
      expect(result[:all_have_source_line]).to be true
      expect(result[:source_file_match]).to be true
    end

    it 'String, Array, Hash の割り当てが追跡されていることを確認する' do
      expect(result[:tracked_types]).to contain_exactly('String', 'Array', 'Hash')
      expect(result[:tracked_count]).to eq 3
    end
  end

  describe '.demonstrate_memory_profiling' do
    let(:result) { described_class.demonstrate_memory_profiling }

    it 'メモリリークパターンを前後比較で検出できることを確認する' do
      expect(result[:instances_leaked]).to be true
      expect(result[:instance_increase]).to be >= 10
    end

    it 'GC 統計情報が取得できることを確認する' do
      expect(result[:gc_count]).to be_positive
      expect(result[:gc_stat_keys]).not_to be_empty
    end

    it 'プロファイリング手順が定義されていることを確認する' do
      expect(result[:profiling_steps]).to be_an(Array)
      expect(result[:profiling_steps].size).to eq 5
    end
  end

  describe '.demonstrate_production_safety' do
    let(:result) { described_class.demonstrate_production_safety }

    it 'ブロック形式の enable が終了後に自動で無効化されることを確認する' do
      expect(result[:auto_disabled_after_block]).to be true
      expect(result[:block_events_captured]).to be true
    end

    it 'サンプリング戦略によりトレース対象が削減されることを確認する' do
      expect(result[:sampled_requests]).to be < result[:total_requests]
      expect(result[:sampled_requests]).to be_positive
    end

    it '本番環境のベストプラクティスが定義されていることを確認する' do
      expect(result[:best_practices]).to be_an(Array)
      expect(result[:best_practices].size).to be >= 5
    end
  end
end
