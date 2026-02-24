# frozen_string_literal: true

require_relative 'batch_processing'

RSpec.describe BatchProcessing do
  # ==========================================================================
  # 1. find_each のテスト
  # ==========================================================================
  describe BatchProcessing::FindEach do
    describe '.demonstrate_basic_find_each' do
      let(:result) { described_class.demonstrate_basic_find_each }

      it 'find_eachで全レコードが1件ずつ処理されることを確認する' do
        expect(result[:total_records]).to eq 20
        expect(result[:collected_count]).to eq 20
        expect(result[:all_processed]).to be true
      end

      it 'find_eachがIDの昇順で処理することを確認する' do
        expect(result[:first_item]).to eq 'record_0'
        expect(result[:last_item]).to eq 'record_19'
      end
    end

    describe '.demonstrate_start_finish' do
      let(:result) { described_class.demonstrate_start_finish }

      it 'start/finishオプションでID範囲を制限して処理できることを確認する' do
        expect(result[:complete_coverage]).to be true
        expect(result[:first_half_count] + result[:second_half_count]).to eq result[:total_records]
      end
    end
  end

  # ==========================================================================
  # 2. find_in_batches のテスト
  # ==========================================================================
  describe BatchProcessing::FindInBatches do
    describe '.demonstrate_batch_processing' do
      let(:result) { described_class.demonstrate_batch_processing }

      it 'find_in_batchesが指定サイズのバッチで処理することを確認する' do
        expect(result[:total_records]).to eq 25
        expect(result[:batch_count]).to eq 3
        expect(result[:batch_sizes]).to eq [10, 10, 5]
        expect(result[:last_batch_partial]).to be true
      end
    end

    describe '.demonstrate_batch_aggregation' do
      let(:result) { described_class.demonstrate_batch_aggregation }

      it 'バッチ処理内で集約が正しく行われることを確認する' do
        expect(result[:total_counted]).to eq 30
        expect(result[:category_counts].values.sum).to eq 30
      end
    end
  end

  # ==========================================================================
  # 3. in_batches のテスト
  # ==========================================================================
  describe BatchProcessing::InBatches do
    describe '.demonstrate_batch_update' do
      let(:result) { described_class.demonstrate_batch_update }

      it 'in_batchesでバッチ単位のupdate_allが正しく動作することを確認する' do
        expect(result[:all_processed]).to be true
        expect(result[:processed_count]).to eq result[:total_records]
        expect(result[:batch_update_count]).to be_positive
      end
    end

    describe '.demonstrate_batch_delete' do
      let(:result) { described_class.demonstrate_batch_delete }

      it 'in_batchesでバッチ単位の削除が正しく動作することを確認する' do
        expect(result[:before_count]).to eq 30
        expect(result[:deleted_count]).to eq 15
        expect(result[:after_count]).to eq 15
        expect(result[:remaining_all_keep]).to be true
      end
    end

    describe '.demonstrate_relation_methods' do
      let(:result) { described_class.demonstrate_relation_methods }

      it 'in_batchesのRelationメソッド（pluck等）が使えることを確認する' do
        expect(result[:all_ids_count]).to eq 15
        expect(result[:ids_complete]).to be true
      end
    end
  end

  # ==========================================================================
  # 4. insert_all / upsert_all のテスト
  # ==========================================================================
  describe BatchProcessing::BulkInsert do
    describe '.demonstrate_insert_all' do
      let(:result) { described_class.demonstrate_insert_all }

      it 'insert_allで一括挿入が正しく行われることを確認する' do
        expect(result[:inserted_count]).to eq 100
        expect(result[:skips_callbacks]).to be true
        expect(result[:skips_validations]).to be true
      end
    end

    describe '.demonstrate_upsert_all' do
      let(:result) { described_class.demonstrate_upsert_all }

      it 'upsert_allで既存レコードの更新と新規レコードの挿入が行われることを確認する' do
        expect(result[:initial_count]).to eq 5
        expect(result[:updated_records]).to eq 5
        expect(result[:new_records]).to eq 1
        expect(result[:final_count]).to eq 6
      end
    end
  end

  # ==========================================================================
  # 5. update_all のテスト
  # ==========================================================================
  describe BatchProcessing::MassUpdate do
    describe '.demonstrate_update_all' do
      let(:result) { described_class.demonstrate_update_all }

      it 'update_allで一括更新が正しく行われることを確認する' do
        expect(result[:affected_rows]).to eq 20
        expect(result[:all_updated]).to be true
        expect(result[:after_state][:processed]).to eq 20
        expect(result[:after_state][:completed]).to eq 20
      end
    end

    describe '.demonstrate_conditional_update' do
      let(:result) { described_class.demonstrate_conditional_update }

      it '条件付きupdate_allが対象レコードのみを更新することを確認する' do
        expect(result[:category_a_updated]).to eq 10
        expect(result[:a_all_processed]).to be true
        expect(result[:b_data_modified]).to be true
        expect(result[:c_unchanged]).to be true
      end
    end
  end

  # ==========================================================================
  # 6. delete_all vs destroy_all のテスト
  # ==========================================================================
  describe BatchProcessing::DeleteVsDestroy do
    describe '.demonstrate_delete_all' do
      let(:result) { described_class.demonstrate_delete_all }

      it 'delete_allが全対象レコードを削除し行数を返すことを確認する' do
        expect(result[:deleted_count]).to eq 50
        expect(result[:after_count]).to eq 0
        expect(result[:returns_count]).to be true
      end
    end

    describe '.demonstrate_destroy_all' do
      let(:result) { described_class.demonstrate_destroy_all }

      it 'destroy_allが削除されたオブジェクトの配列を返すことを確認する' do
        expect(result[:destroyed_count]).to eq 10
        expect(result[:after_count]).to eq 0
        expect(result[:returns_objects]).to be true
        expect(result[:all_frozen]).to be true
      end
    end

    describe '.demonstrate_performance_comparison' do
      let(:result) { described_class.demonstrate_performance_comparison }

      it 'delete_allがdestroy_allより高速であることを確認する' do
        expect(result[:delete_faster]).to be true
      end
    end
  end

  # ==========================================================================
  # 7. メモリ監視のテスト
  # ==========================================================================
  describe BatchProcessing::MemoryMonitoring do
    describe '.demonstrate_memory_efficiency' do
      let(:result) { described_class.demonstrate_memory_efficiency }

      it 'find_eachがメモリ効率よく全レコードを処理することを確認する' do
        expect(result[:find_each_processed]).to eq result[:record_count]
        expect(result[:memory_efficient]).to be true
      end
    end

    describe '.demonstrate_gc_tracking' do
      let(:result) { described_class.demonstrate_gc_tracking }

      it 'バッチ処理中のGC統計が追跡できることを確認する' do
        expect(result[:batch_count]).to eq 4
        expect(result[:gc_stats].size).to eq 4
        expect(result[:gc_stats].first).to have_key(:heap_live_slots)
      end
    end
  end

  # ==========================================================================
  # 8. バッチ処理パターンのテスト
  # ==========================================================================
  describe BatchProcessing::BatchPatterns do
    describe '.demonstrate_progress_tracking' do
      let(:result) { described_class.demonstrate_progress_tracking }

      it 'プログレス追跡で全レコードが処理されることを確認する' do
        expect(result[:processed]).to eq result[:total]
        expect(result[:all_processed]).to be true
        expect(result[:progress_log]).not_to be_empty
        expect(result[:progress_log].last[:percent]).to eq 100.0
      end
    end

    describe '.demonstrate_error_handling' do
      let(:result) { described_class.demonstrate_error_handling }

      it 'エラーが発生しても残りのレコードが処理されることを確認する' do
        expect(result[:partial_success]).to be true
        expect(result[:failures_count]).to eq 3
        expect(result[:successes]).to eq result[:total] - result[:failures_count]
      end
    end

    describe '.demonstrate_resumable_processing' do
      let(:result) { described_class.demonstrate_resumable_processing }

      it '中断後に未処理レコードから再開できることを確認する' do
        expect(result[:first_run_processed]).to eq 10
        expect(result[:second_run_processed]).to eq 20
        expect(result[:all_processed]).to be true
        expect(result[:resumed_successfully]).to be true
      end
    end

    describe '.api_comparison' do
      let(:result) { described_class.api_comparison }

      it 'バッチ処理APIの比較情報が網羅的に提供されることを確認する' do
        expect(result.keys).to contain_exactly(
          :find_each, :find_in_batches, :in_batches,
          :insert_all, :update_all, :delete_all, :destroy_all
        )
        result.each_value do |info|
          expect(info).to have_key(:returns)
          expect(info).to have_key(:use_case)
          expect(info).to have_key(:memory)
          expect(info).to have_key(:callbacks)
        end
      end
    end
  end
end
