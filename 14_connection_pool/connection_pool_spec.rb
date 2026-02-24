# frozen_string_literal: true

require_relative 'connection_pool'

RSpec.describe ConnectionPoolInternals do
  # ==========================================================================
  # 1. プールの基本構造
  # ==========================================================================
  describe 'PoolBasics' do
    describe '.demonstrate_pool_info' do
      let(:result) { ConnectionPoolInternals::PoolBasics.demonstrate_pool_info }

      it 'コネクションプールの基本情報を正しく取得できること' do
        expect(result[:pool_size]).to eq 5
        expect(result[:checkout_timeout]).to eq 5
        expect(result[:adapter]).to eq 'sqlite3'
        expect(result[:pool_responds_to_checkout]).to be true
        expect(result[:pool_responds_to_checkin]).to be true
      end
    end

    describe '.demonstrate_pool_stat' do
      let(:result) { ConnectionPoolInternals::PoolBasics.demonstrate_pool_stat }

      it 'プールの統計情報が正しい形式で返されること' do
        expect(result[:size]).to eq 5
        expect(result[:connections]).to be_a(Integer)
        expect(result[:busy]).to be_a(Integer)
        expect(result[:idle]).to be_a(Integer)
        expect(result[:waiting]).to eq 0
      end
    end
  end

  # ==========================================================================
  # 2. チェックアウト/チェックイン
  # ==========================================================================
  describe 'CheckoutCheckin' do
    describe '.demonstrate_checkout_checkin' do
      let(:result) { ConnectionPoolInternals::CheckoutCheckin.demonstrate_checkout_checkin }

      it 'チェックアウト中はbusy接続が増え、チェックイン後はidleに戻ること' do
        expect(result[:during_checkout_busy]).to be >= 1
        expect(result[:connection_active]).to be true
        expect(result[:connection_class]).to include('SQLite3')
      end
    end

    describe '.demonstrate_with_connection' do
      let(:result) { ConnectionPoolInternals::CheckoutCheckin.demonstrate_with_connection }

      it 'with_connectionブロック終了後に接続が自動返却されること' do
        expect(result[:inside_active]).to be true
        expect(result[:connection_auto_returned]).to be true
      end
    end
  end

  # ==========================================================================
  # 3. スレッドローカルバインディング
  # ==========================================================================
  describe 'ThreadLocalBinding' do
    describe '.demonstrate_thread_connection_binding' do
      let(:result) { ConnectionPoolInternals::ThreadLocalBinding.demonstrate_thread_connection_binding }

      it '各スレッドが異なる接続を取得すること' do
        expect(result[:thread_connection_ids].size).to eq 3
        expect(result[:main_connection_id]).to be_a(Integer)
      end
    end

    describe '.demonstrate_same_thread_same_connection' do
      let(:result) { ConnectionPoolInternals::ThreadLocalBinding.demonstrate_same_thread_same_connection }

      it '同一スレッド内では同じ接続が返されること' do
        expect(result[:same_connection]).to be true
        expect(result[:first_connection_id]).to eq result[:second_connection_id]
      end
    end
  end

  # ==========================================================================
  # 4. プールサイズ設定
  # ==========================================================================
  describe 'PoolConfiguration' do
    describe '.demonstrate_configuration' do
      let(:result) { ConnectionPoolInternals::PoolConfiguration.demonstrate_configuration }

      it 'プール設定と推奨値が正しく返されること' do
        expect(result[:pool_size]).to eq 5
        expect(result[:checkout_timeout]).to eq 5
        expect(result[:recommendation]).to be_a(Hash)
        expect(result[:recommendation][:formula]).to include('Puma')
      end
    end
  end

  # ==========================================================================
  # 5. 接続枯渇
  # ==========================================================================
  describe 'ConnectionExhaustion' do
    describe '.demonstrate_timeout_behavior' do
      let(:result) { ConnectionPoolInternals::ConnectionExhaustion.demonstrate_timeout_behavior }

      it 'プール枯渇時にタイムアウトエラーが発生すること' do
        expect(result[:timeout_occurred]).to be true
        expect(result[:error_class]).to eq 'ActiveRecord::ConnectionTimeoutError'
        expect(result[:approximate_timeout]).to be true
      end
    end

    describe '.demonstrate_pool_exhaustion_detection' do
      let(:result) { ConnectionPoolInternals::ConnectionExhaustion.demonstrate_pool_exhaustion_detection }

      it 'プール枯渇の検出メトリクスが返されること' do
        expect(result[:pool_size]).to be_a(Integer)
        expect(result[:utilization_percent]).to be_a(Float)
        expect(result[:remedies]).to be_an(Array)
        expect(result[:remedies].size).to eq 4
      end
    end
  end

  # ==========================================================================
  # 6. with_connectionパターン
  # ==========================================================================
  describe 'WithConnectionPattern' do
    describe '.demonstrate_proper_usage' do
      let(:result) { ConnectionPoolInternals::WithConnectionPattern.demonstrate_proper_usage }

      it 'with_connectionが接続を適切に管理すること' do
        expect(result[:query_result]).to be_a(Hash).or be_a(Array).or include('value')
      end
    end
  end

  # ==========================================================================
  # 7. リーパースレッド
  # ==========================================================================
  describe 'ReaperThread' do
    describe '.demonstrate_reaper_concept' do
      let(:result) { ConnectionPoolInternals::ReaperThread.demonstrate_reaper_concept }

      it 'リーパーの概念情報が正しく返されること' do
        expect(result[:purpose]).to include('回収')
        expect(result[:configuration]).to be_a(Hash)
      end
    end

    describe '.demonstrate_manual_reap' do
      let(:result) { ConnectionPoolInternals::ReaperThread.demonstrate_manual_reap }

      it '手動reapが正常に実行されること' do
        expect(result[:before_reap]).to be_a(Hash)
        expect(result[:after_reap]).to be_a(Hash)
      end
    end
  end

  # ==========================================================================
  # 8. マルチスレッド安全性
  # ==========================================================================
  describe 'MultiThreadSafety' do
    describe '.demonstrate_thread_safety' do
      let(:result) { ConnectionPoolInternals::MultiThreadSafety.demonstrate_thread_safety }

      it '複数スレッドからの同時アクセスがスレッドセーフに動作すること' do
        expect(result[:all_completed]).to be true
        expect(result[:result_count]).to eq 10
        expect(result[:thread_safe]).to be true
      end
    end

    describe '.demonstrate_concurrent_writes' do
      let(:result) { ConnectionPoolInternals::MultiThreadSafety.demonstrate_concurrent_writes }

      it '複数スレッドからの同時書き込みが正常に完了すること' do
        expect(result[:all_created]).to be true
        expect(result[:total_records]).to eq 5
        expect(result[:records].size).to eq 5
      end
    end
  end

  # ==========================================================================
  # 9. 簡易コネクションプール実装
  # ==========================================================================
  describe ConnectionPoolInternals::SimpleConnectionPool do
    let(:pool) do
      counter = 0
      described_class.new(size: 3, checkout_timeout: 2) do
        counter += 1
        { id: counter, active: true }
      end
    end

    describe '#checkout / #checkin' do
      it '接続の取得と返却が正しく動作すること' do
        conn = pool.checkout
        expect(conn).to be_a(Hash)
        expect(conn[:active]).to be true

        stat = pool.stat
        expect(stat[:connections]).to eq 1
        expect(stat[:busy]).to eq 1

        pool.checkin(conn)
        stat_after = pool.stat
        expect(stat_after[:available]).to eq 1
        expect(stat_after[:busy]).to eq 0
      end
    end

    describe '#with_connection' do
      it 'ブロック終了後に接続が自動返却されること' do
        pool.with_connection do |conn|
          expect(conn[:active]).to be true
          expect(pool.stat[:busy]).to eq 1
        end
        expect(pool.stat[:busy]).to eq 0
        expect(pool.stat[:available]).to eq 1
      end

      it '例外発生時も接続が返却されること' do
        expect do
          pool.with_connection do |_conn|
            raise StandardError, 'テストエラー'
          end
        end.to raise_error(StandardError, 'テストエラー')

        expect(pool.stat[:busy]).to eq 0
        expect(pool.stat[:available]).to eq 1
      end
    end

    describe 'タイムアウト動作' do
      it 'プール枯渇時にタイムアウトエラーが発生すること' do
        small_pool = described_class.new(size: 1, checkout_timeout: 1) do
          { id: 1, active: true }
        end

        # 唯一の接続を保持
        conn = small_pool.checkout

        # 別スレッドからのチェックアウトはタイムアウトする
        error = nil
        thread = Thread.new do
          small_pool.checkout
        rescue ConnectionPoolInternals::ConnectionTimeoutError => e
          error = e
        end
        thread.join

        expect(error).to be_a(ConnectionPoolInternals::ConnectionTimeoutError)
        expect(error.message).to include('プール枯渇')

        small_pool.checkin(conn)
      end
    end

    describe 'マルチスレッド安全性' do
      it '複数スレッドが同時にプールにアクセスしても安全に動作すること' do
        results = []
        result_mutex = Mutex.new

        threads = 6.times.map do |i|
          Thread.new do
            pool.with_connection do |conn|
              sleep(0.01)
              result_mutex.synchronize { results << { thread: i, conn_id: conn[:id] } }
            end
          end
        end

        threads.each(&:join)

        expect(results.size).to eq 6
        # 最大3接続しか作成されない
        expect(pool.stat[:connections]).to be <= 3
      end
    end

    describe '#reap' do
      it '死んだスレッドの接続を回収できること' do
        # スレッドで接続を取得し、checkin せずにスレッド終了
        thread = Thread.new { pool.checkout }
        thread.join

        stat_before = pool.stat
        expect(stat_before[:busy]).to eq 1

        # リーパーで回収
        reaped = pool.reap

        stat_after = pool.stat
        expect(reaped).to eq 1
        expect(stat_after[:available]).to eq 1
        expect(stat_after[:busy]).to eq 0
      end
    end

    describe '#disconnect!' do
      it '全接続を切断できること' do
        pool.with_connection { |_| nil }
        expect(pool.stat[:connections]).to be >= 1

        pool.disconnect!

        expect(pool.stat[:connections]).to eq 0
        expect(pool.stat[:available]).to eq 0
      end
    end
  end

  # ==========================================================================
  # SimplePoolDemo のテスト
  # ==========================================================================
  describe 'SimplePoolDemo' do
    describe '.demonstrate_basic_usage' do
      let(:result) { ConnectionPoolInternals::SimplePoolDemo.demonstrate_basic_usage }

      it '基本的な使い方が正常に動作すること' do
        expect(result[:first_connection]).to eq 1
        expect(result[:stat_during][:busy]).to eq 1
        expect(result[:stat_after][:busy]).to eq 0
      end
    end

    describe '.demonstrate_multithreaded' do
      let(:result) { ConnectionPoolInternals::SimplePoolDemo.demonstrate_multithreaded }

      it 'マルチスレッドで接続が再利用されること' do
        expect(result[:all_completed]).to be true
        expect(result[:total_threads]).to eq 6
        expect(result[:unique_connections]).to be <= 3
      end
    end

    describe '.demonstrate_timeout' do
      let(:result) { ConnectionPoolInternals::SimplePoolDemo.demonstrate_timeout }

      it 'タイムアウトが正しく動作すること' do
        expect(result[:timeout_occurred]).to be true
        expect(result[:error_class]).to eq 'ConnectionPoolInternals::ConnectionTimeoutError'
      end
    end
  end
end
