# frozen_string_literal: true

require_relative 'database_locking'

RSpec.describe DatabaseLocking do
  # テストごとにデータをリセット
  before do
    Account.delete_all
    TransferLog.delete_all
  end

  describe DatabaseLocking::OptimisticLocking do
    describe '.demonstrate_basic_optimistic_lock' do
      let(:result) { described_class.demonstrate_basic_optimistic_lock }

      it '初期バージョンが0であることを確認する' do
        expect(result[:initial_version]).to eq 0
      end

      it '更新後にlock_versionがインクリメントされることを確認する' do
        expect(result[:version_after_a_update]).to eq 1
        expect(result[:version_incremented]).to be true
      end

      it '競合する更新でStaleObjectErrorが発生することを確認する' do
        expect(result[:stale_error_occurred]).to be true
        expect(result[:stale_error_class]).to eq 'ActiveRecord::StaleObjectError'
      end

      it '最初の更新のみが反映されていることを確認する' do
        # インスタンスAの更新（900）が反映され、インスタンスBの更新（800）は拒否される
        expect(result[:final_balance]).to eq 900
        expect(result[:final_version]).to eq 1
      end
    end

    describe '.demonstrate_version_increment' do
      let(:result) { described_class.demonstrate_version_increment }

      it 'lock_versionが単調増加することを確認する' do
        expect(result[:version_history]).to eq [0, 1, 2, 3]
        expect(result[:monotonically_increasing]).to be true
      end
    end
  end

  describe DatabaseLocking::PessimisticLocking do
    describe '.demonstrate_lock_concept' do
      let(:result) { described_class.demonstrate_lock_concept }

      it '悲観的ロック内で残高が正しく更新されることを確認する' do
        expect(result[:balance]).to eq 1500
        expect(result[:transaction_result][:balance_after_withdrawal]).to eq 1500
      end
    end

    describe '.demonstrate_with_lock' do
      let(:result) { described_class.demonstrate_with_lock }

      it 'with_lockで安全に残高が更新されることを確認する' do
        expect(result[:balance]).to eq 2000
        expect(result[:balance_correct]).to be true
      end
    end

    describe '.demonstrate_sql_concepts' do
      let(:result) { described_class.demonstrate_sql_concepts }

      it '悲観的ロックのSQL概念が正しく説明されていることを確認する' do
        expect(result[:select_for_update]).to include('FOR UPDATE')
        expect(result[:select_for_update_nowait]).to include('NOWAIT')
        expect(result[:select_skip_locked]).to include('SKIP LOCKED')
      end

      it 'ActiveRecordでの使用方法が説明されていることを確認する' do
        usage = result[:activerecord_usage]
        expect(usage[:basic]).to include('lock')
        expect(usage[:with_lock]).to include('with_lock')
      end
    end
  end

  describe DatabaseLocking::AdvisoryLocks do
    describe '.demonstrate_advisory_lock_concepts' do
      let(:result) { described_class.demonstrate_advisory_lock_concepts }

      it 'アドバイザリーロックの特徴が説明されていることを確認する' do
        characteristics = result[:characteristics]
        expect(characteristics).to have_key(:application_level)
        expect(characteristics).to have_key(:key_based)
      end

      it 'PostgreSQLでの使用例が説明されていることを確認する' do
        examples = result[:postgresql_examples]
        expect(examples[:session_lock]).to include('pg_advisory_lock')
        expect(examples[:try_lock]).to include('pg_try_advisory_lock')
      end

      it 'ミューテックスシミュレーションで排他制御が動作することを確認する' do
        mutex_result = result[:mutex_simulation]
        # 最初の取得者だけがロックを獲得できる
        expect(mutex_result[:exactly_one_acquired]).to be true
        expect(mutex_result[:first_acquired]).to be true
        expect(mutex_result[:second_blocked]).to be true
      end
    end
  end

  describe DatabaseLocking::DeadlockPrevention do
    describe '.demonstrate_lock_ordering' do
      let(:result) { described_class.demonstrate_lock_ordering }

      it 'ロック順序付き送金が成功することを確認する' do
        expect(result[:transfer_success]).to be true
      end

      it '送金後の総残高が保存されていることを確認する' do
        expect(result[:balance_preserved]).to be true
        expect(result[:total_balance]).to eq 2000
      end

      it '残高が正しく移動していることを確認する' do
        expect(result[:account_a_balance]).to eq 700
        expect(result[:account_b_balance]).to eq 1300
      end

      it 'IDの昇順でロックが取得されていることを確認する' do
        lock_order = result[:lock_order]
        expect(lock_order).to eq lock_order.sort
      end
    end

    describe '.demonstrate_deadlock_scenario' do
      let(:result) { described_class.demonstrate_deadlock_scenario }

      it 'デッドロック発生パターンが説明されていることを確認する' do
        expect(result[:dangerous_pattern][:result]).to include('デッドロック')
      end

      it '安全なパターン（ロック順序固定）が説明されていることを確認する' do
        expect(result[:safe_pattern][:rule]).to include('昇順')
        expect(result[:safe_pattern][:result]).to include('デッドロックなし')
      end

      it 'タイムアウト設定が各DBMSで説明されていることを確認する' do
        expect(result[:timeout_config]).to have_key(:mysql)
        expect(result[:timeout_config]).to have_key(:postgresql)
        expect(result[:timeout_config]).to have_key(:rails)
      end
    end
  end

  describe DatabaseLocking::RaceConditionExamples do
    describe '.demonstrate_lost_update' do
      let(:result) { described_class.demonstrate_lost_update }

      it 'lost updateが発生し期待値と異なることを確認する' do
        expect(result[:lost_update_occurred]).to be true
        expect(result[:final_balance]).not_to eq result[:expected_balance]
      end

      it '消失した金額が正しく計算されていることを確認する' do
        # Aの100円の引き出しが消失している
        expect(result[:lost_amount]).to eq 100
      end
    end

    describe '.demonstrate_atomic_update' do
      let(:result) { described_class.demonstrate_atomic_update }

      it 'アトミックSQLで正確な残高が計算されることを確認する' do
        expect(result[:final_balance]).to eq 0
        expect(result[:balance_correct]).to be true
      end
    end

    describe '.demonstrate_safe_update_with_optimistic_lock' do
      let(:result) { described_class.demonstrate_safe_update_with_optimistic_lock }

      it '楽観的ロックにより全試行が成功またはStaleObjectErrorとなることを確認する' do
        expect(result[:total_attempts]).to eq 10
        expect(result[:success_count] + result[:stale_error_count]).to eq 10
      end

      it '成功した更新と競合エラーの合計が正しいことを確認する' do
        # 5ラウンド x 2インスタンス = 10試行
        # 各ラウンドで1成功・1失敗
        expect(result[:success_count]).to eq 5
        expect(result[:stale_error_count]).to eq 5
      end
    end
  end

  describe DatabaseLocking::RetryPatterns do
    describe '.demonstrate_basic_retry' do
      let(:result) { described_class.demonstrate_basic_retry }

      it 'リトライパターンで更新が成功することを確認する' do
        expect(result[:result][:success]).to be true
      end

      it '更新後の残高が正しいことを確認する' do
        expect(result[:final_balance]).to eq 900
      end
    end

    describe '.demonstrate_exponential_backoff_retry' do
      let(:result) { described_class.demonstrate_exponential_backoff_retry }

      it '指数バックオフリトライで更新が成功することを確認する' do
        expect(result[:result][:success]).to be true
      end
    end

    describe '.demonstrate_production_pattern' do
      let(:result) { described_class.demonstrate_production_pattern }

      it '実務パターンで出金が成功することを確認する' do
        expect(result[:result][:success]).to be true
      end

      it '出金後の残高が正しいことを確認する' do
        expect(result[:final_balance]).to eq 4500
      end

      it 'パターンの説明が含まれていることを確認する' do
        desc = result[:pattern_description]
        expect(desc[:step1]).to include('楽観的ロック')
        expect(desc[:step2]).to include('バックオフ')
        expect(desc[:step4]).to include('悲観的ロック')
      end
    end

    describe '.with_optimistic_retry' do
      it 'StaleObjectErrorなしでブロックが成功することを確認する' do
        Account.create!(name: 'Helper-Test', balance: 1000)
        result = described_class.with_optimistic_retry(max_retries: 3) do
          acc = Account.last
          acc.balance -= 100
          acc.save!
          acc.balance
        end

        expect(result[:success]).to be true
        expect(result[:retries]).to eq 0
        expect(result[:value]).to eq 900
      end
    end
  end

  describe DatabaseLocking::LockStrategyDecision do
    describe '.demonstrate_decision_framework' do
      let(:result) { described_class.demonstrate_decision_framework }

      it '楽観的ロックの判断基準が含まれていることを確認する' do
        optimistic = result[:optimistic_locking]
        expect(optimistic[:when_to_use]).to be_an(Array)
        expect(optimistic[:advantages]).to be_an(Array)
        expect(optimistic[:disadvantages]).to be_an(Array)
      end

      it '悲観的ロックの判断基準が含まれていることを確認する' do
        pessimistic = result[:pessimistic_locking]
        expect(pessimistic[:when_to_use]).to be_an(Array)
        expect(pessimistic[:implementation]).to include('with_lock')
      end

      it 'アトミックSQLの判断基準が含まれていることを確認する' do
        atomic = result[:atomic_sql]
        expect(atomic[:when_to_use]).to include(a_string_matching(/カウンター|残高/))
      end

      it 'アドバイザリーロックの判断基準が含まれていることを確認する' do
        advisory = result[:advisory_locks]
        expect(advisory[:when_to_use]).to include(a_string_matching(/バッチ|二重実行/))
      end
    end

    describe '.demonstrate_practical_scenarios' do
      let(:result) { described_class.demonstrate_practical_scenarios }

      it 'ECサイト在庫管理のシナリオが説明されていることを確認する' do
        expect(result[:ecommerce_stock][:recommendation]).to include('悲観的ロック')
      end

      it 'ユーザープロフィール編集のシナリオが説明されていることを確認する' do
        expect(result[:user_profile_edit][:recommendation]).to include('楽観的ロック')
      end

      it '銀行口座送金のシナリオが説明されていることを確認する' do
        expect(result[:bank_transfer][:recommendation]).to include('悲観的ロック')
        expect(result[:bank_transfer][:recommendation]).to include('ロック順序')
      end
    end
  end
end
