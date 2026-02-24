# frozen_string_literal: true

require_relative 'solid_queue'

RSpec.describe SolidQueueInternals do
  before do
    described_class.cleanup_all_tables
  end

  describe '.demonstrate_enqueue' do
    let(:result) { described_class.demonstrate_enqueue }

    it '即時ジョブと遅延ジョブが正しく分離して登録されることを確認する' do
      expect(result[:total_jobs]).to eq 2
      expect(result[:ready_count]).to eq 1
      expect(result[:scheduled_count]).to eq 1
    end

    it '即時ジョブが ready_executions に登録されることを確認する' do
      expect(result[:immediate_in_ready]).to be true
      expect(result[:immediate_job_class]).to eq 'WelcomeEmailJob'
    end

    it '遅延ジョブが scheduled_executions に登録されることを確認する' do
      expect(result[:scheduled_in_scheduled]).to be true
      expect(result[:scheduled_job_class]).to eq 'ReminderJob'
    end
  end

  describe '.demonstrate_skip_locked_concept' do
    let(:result) { described_class.demonstrate_skip_locked_concept }

    it '複数ワーカーが同一ジョブを取得しないことを確認する（SKIP LOCKED の効果）' do
      expect(result[:worker1_claimed]).not_to eq result[:worker2_claimed]
      expect(result[:claimed_count]).to eq 2
    end

    it '優先度順にジョブが取得されることを確認する' do
      # priority=1 が最初、priority=5 が次
      expect(result[:worker1_claimed]).to eq ['HighPriorityJob']
      expect(result[:worker2_claimed]).to eq ['MediumPriorityJob']
    end

    it '取得済みジョブが ready_executions から削除されることを確認する' do
      expect(result[:ready_remaining]).to eq 1
      expect(result[:remaining_ready]).to eq ['LowPriorityJob']
    end
  end

  describe '.demonstrate_job_lifecycle' do
    let(:result) { described_class.demonstrate_job_lifecycle }

    it 'Enqueue 後はジョブが ready 状態であることを確認する' do
      state = result[:after_enqueue]
      expect(state[:ready]).to be true
      expect(state[:claimed]).to be false
      expect(state[:failed]).to be false
      expect(state[:finished]).to be false
    end

    it 'Claim 後はジョブが claimed 状態に遷移することを確認する' do
      state = result[:after_claim]
      expect(state[:ready]).to be false
      expect(state[:claimed]).to be true
      expect(state[:failed]).to be false
      expect(state[:finished]).to be false
    end

    it '完了後はジョブが finished 状態になることを確認する' do
      state = result[:after_finish]
      expect(state[:ready]).to be false
      expect(state[:claimed]).to be false
      expect(state[:failed]).to be false
      expect(state[:finished]).to be true
    end
  end

  describe '.demonstrate_priority_ordering' do
    let(:result) { described_class.demonstrate_priority_ordering }

    it 'priority の値が小さい順にジョブが取得されることを確認する' do
      expect(result[:first_claimed_is_critical]).to be true
      # priority=0 が2つ、priority=5 が1つ、priority=10 が1つ、priority=20 が1つ
      expect(result[:claimed_order][0]).to eq 'CriticalJob'
      expect(result[:claimed_order][1]).to eq 'AnotherCriticalJob'
      expect(result[:claimed_order][2]).to eq 'NormalJob'
    end

    it '同じ優先度のジョブは FIFO 順で取得されることを確認する' do
      # CriticalJob と AnotherCriticalJob はどちらも priority=0
      # CriticalJob が先に投入されたので先に取得される
      critical_indices = result[:claimed_order].each_with_index
                                               .select { |name, _| name&.start_with?('Critical', 'AnotherCritical') }
                                               .map { |_, i| i }
      expect(critical_indices).to eq [0, 1]
    end
  end

  describe '.demonstrate_failure_handling' do
    let(:result) { described_class.demonstrate_failure_handling }

    it '失敗したジョブが failed_executions に記録されることを確認する' do
      expect(result[:failed_exists]).to be true
      expect(result[:error_class]).to eq 'PaymentGatewayError'
      expect(result[:error_message]).to include 'Connection timeout'
    end

    it '失敗後に claimed_execution が削除されることを確認する' do
      expect(result[:claimed_exists]).to be false
    end

    it '失敗したジョブの finished_at は nil のままであることを確認する' do
      expect(result[:job_finished]).to be false
      expect(result[:can_retry]).to be true
    end

    it 'バックトレースが保存されることを確認する' do
      expect(result[:has_backtrace]).to be true
    end
  end

  describe '.demonstrate_concurrency_control' do
    let(:result) { described_class.demonstrate_concurrency_control }

    it 'セマフォの上限まで同時実行を許可することを確認する' do
      expect(result[:max_concurrent]).to eq 2
      expect(result[:first_acquired]).to be true
      expect(result[:second_acquired]).to be true
      expect(result[:value_after_first]).to eq 1
      expect(result[:value_after_second]).to eq 0
    end

    it '上限到達後は新たなセマフォ取得が拒否されることを確認する' do
      expect(result[:third_acquired]).to be false
      expect(result[:value_after_third]).to eq 0
    end

    it 'セマフォ解放後に再取得が可能になることを確認する' do
      expect(result[:value_after_release]).to eq 1
      expect(result[:acquired_after_release]).to be true
    end
  end

  describe '.demonstrate_worker_process_management' do
    let(:result) { described_class.demonstrate_worker_process_management }

    it 'ハートビートによるプロセスの生死判定が正しく動作することを確認する' do
      expect(result[:total_processes]).to eq 3
      expect(result[:alive_count]).to eq 2
      expect(result[:dead_count]).to eq 1
    end

    it 'ハートビートが古いプロセスが dead と判定されることを確認する' do
      expect(result[:worker1_is_dead]).to be true
      expect(result[:worker2_is_alive]).to be true
      expect(result[:dispatcher_is_alive]).to be true
    end
  end

  describe '.demonstrate_comparison_with_sidekiq' do
    let(:result) { described_class.demonstrate_comparison_with_sidekiq }

    it 'Solid Queue と Sidekiq の主要な違いが網羅されていることを確認する' do
      sq = result[:solid_queue]
      sk = result[:sidekiq]

      expect(sq[:backend]).to include 'データベース'
      expect(sk[:backend]).to include 'Redis'

      expect(sq[:job_claiming]).to include 'FOR UPDATE SKIP LOCKED'
      expect(sk[:job_claiming]).to include 'BRPOPLPUSH'

      expect(sq[:rails_default]).to include 'Rails 8'

      expect(sq[:advantages]).to be_an(Array)
      expect(sk[:advantages]).to be_an(Array)
      expect(sq[:advantages].length).to be >= 3
      expect(sk[:advantages].length).to be >= 3
    end

    it '移行時の考慮事項が含まれていることを確認する' do
      considerations = result[:migration_considerations]
      expect(considerations).to be_an(Array)
      expect(considerations.length).to be >= 3
    end
  end
end
