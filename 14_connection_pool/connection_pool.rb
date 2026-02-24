# frozen_string_literal: true

# ActiveRecordコネクションプールの内部構造を解説するモジュール
#
# Railsアプリケーションにおいて、DB接続はコストの高いリソースであり、
# コネクションプールを通じて効率的に管理される。
# このモジュールでは、シニアエンジニアが知るべきコネクションプールの
# 内部動作を実例を通じて学ぶ。
#
# ActiveRecord::ConnectionAdapters::ConnectionPool は以下を管理する:
# - 接続の取得（checkout）と返却（checkin）
# - スレッドごとの接続バインディング
# - 接続の再利用とタイムアウト
# - 死んだ接続のリーパー（回収）処理

require 'active_record'
require 'logger'

# テスト用のインメモリSQLiteデータベースをセットアップ
# file::memory:?cache=shared により複数コネクションで同じインメモリDBを共有する
# これによりマルチスレッドテストでもスキーマが一貫して見える
unless ActiveRecord::Base.connected?
  ActiveRecord::Base.establish_connection(
    adapter: 'sqlite3',
    database: 'file::memory:?cache=shared',
    pool: 5,
    checkout_timeout: 5
  )
end

# テスト用テーブルの作成
ActiveRecord::Schema.define do
  create_table :pool_test_records, force: true do |t|
    t.string :name
    t.timestamps null: false
  end
end

# テスト用モデル
class PoolTestRecord < ActiveRecord::Base; end

module ConnectionPoolInternals
  # ==========================================================================
  # 1. プールの基本構造: サイズ、設定、内部状態
  # ==========================================================================
  module PoolBasics
    # ActiveRecordのコネクションプールの基本情報を取得する
    #
    # ConnectionPoolは以下の主要コンポーネントで構成される:
    # - @connections: 全コネクションの配列
    # - @available: 利用可能なコネクションのキュー（ConnectionLeasingQueue）
    # - @thread_cached_conns: スレッドごとにキャッシュされた接続のマップ
    # - @size: プールの最大サイズ
    # - @checkout_timeout: 接続取得時のタイムアウト（秒）
    def self.demonstrate_pool_info
      pool = ActiveRecord::Base.connection_pool

      {
        # プールの最大サイズ（database.ymlのpool設定値）
        pool_size: pool.size,
        # チェックアウトタイムアウト（秒）
        checkout_timeout: pool.checkout_timeout,
        # 現在の接続数（プール内の全接続）
        total_connections: pool.connections.size,
        # プールのクラス名
        pool_class: pool.class.name,
        # 接続仕様（アダプタ情報）
        adapter: pool.db_config.adapter,
        # プールはスレッドセーフに設計されている
        pool_responds_to_checkout: pool.respond_to?(:checkout),
        pool_responds_to_checkin: pool.respond_to?(:checkin)
      }
    end

    # プールの統計情報を取得する
    # stat メソッドは Rails 6.1+ で利用可能
    def self.demonstrate_pool_stat
      pool = ActiveRecord::Base.connection_pool
      # 接続を1つ取得して統計に反映させる
      ActiveRecord::Base.connection

      stat = pool.stat

      {
        # プールの最大サイズ
        size: stat[:size],
        # 現在プールが保持している接続数
        connections: stat[:connections],
        # 使用中（チェックアウト中）の接続数
        busy: stat[:busy],
        # 待機中（利用可能）の接続数
        idle: stat[:idle],
        # 接続待ちのスレッド数
        waiting: stat[:waiting],
        # チェックアウトタイムアウト
        checkout_timeout: stat[:checkout_timeout]
      }
    end
  end

  # ==========================================================================
  # 2. チェックアウト/チェックイン: 接続の取得と返却
  # ==========================================================================
  module CheckoutCheckin
    # 接続のチェックアウト（取得）とチェックイン（返却）の流れ
    #
    # checkout の内部処理:
    # 1. 現在のスレッドに既にバインドされた接続があればそれを返す
    # 2. なければ @available キューから取得を試みる
    # 3. キューが空でプールサイズに余裕があれば新規接続を作成
    # 4. 余裕がなければ checkout_timeout まで待機
    # 5. タイムアウトすると ActiveRecord::ConnectionTimeoutError を発生
    def self.demonstrate_checkout_checkin
      pool = ActiveRecord::Base.connection_pool

      # 明示的にチェックアウト
      conn = pool.checkout
      # Rails 8.1+ではレイジー接続のため、実際にクエリを実行して接続を確立する
      conn.execute('SELECT 1')
      stat_during = pool.stat

      # チェックイン（返却）
      pool.checkin(conn)
      stat_after = pool.stat

      {
        # チェックアウト中: busy が 1 増える
        during_checkout_busy: stat_during[:busy],
        during_checkout_idle: stat_during[:idle],
        # チェックイン後: idle が 1 増える
        after_checkin_busy: stat_after[:busy],
        after_checkin_idle: stat_after[:idle],
        # 接続オブジェクトのクラス
        connection_class: conn.class.name,
        # クエリ実行後は接続がアクティブになる
        connection_active: conn.active?
      }
    end

    # with_connection パターン: 接続の自動返却
    #
    # with_connection はブロック終了時に自動的に接続をプールに返す。
    # これが推奨パターンであり、接続リークを防止する。
    # Rails 7.2+ ではレイジー接続取得が導入され、
    # 実際にクエリを実行するまで接続を確保しない。
    def self.demonstrate_with_connection
      pool = ActiveRecord::Base.connection_pool

      # 別スレッドで実行することで、既存のスレッドバインディングの影響を避ける
      Thread.new do
        thread_results = {}
        busy_before = pool.stat[:busy]

        pool.with_connection do |conn|
          # Rails 8.1+ではレイジー接続のため、クエリ実行で接続を確立する
          conn.execute('SELECT 1')
          thread_results[:inside_connection_class] = conn.class.name
          thread_results[:inside_active] = conn.active?
          thread_results[:inside_busy] = pool.stat[:busy]
        end

        # ブロック終了後は接続が返却されている
        thread_results[:outside_busy] = pool.stat[:busy]
        thread_results[:busy_before] = busy_before
        # with_connectionブロック内ではbusy増加、ブロック外では元に戻る
        thread_results[:connection_auto_returned] =
          thread_results[:inside_busy] > thread_results[:busy_before] &&
          thread_results[:outside_busy] == thread_results[:busy_before]

        thread_results
      end.value
    end
  end

  # ==========================================================================
  # 3. スレッドローカルバインディング: 接続とスレッドの関係
  # ==========================================================================
  module ThreadLocalBinding
    # 各スレッドは自分専用の接続を持つ
    #
    # ActiveRecordは接続をスレッドにバインドする。
    # 同じスレッドから connection を呼び出すと常に同じ接続が返される。
    # これにより、トランザクションの整合性が保証される。
    def self.demonstrate_thread_connection_binding
      pool = ActiveRecord::Base.connection_pool
      main_conn_id = nil

      # メインスレッドの接続を取得
      pool.with_connection do |conn|
        main_conn_id = conn.object_id
      end

      # 複数スレッドで接続を取得 - 各スレッドに異なる接続がバインドされる
      threads = 3.times.map do
        Thread.new do
          pool.with_connection(&:object_id)
        end
      end

      thread_conn_ids = threads.map(&:value)

      {
        # メインスレッドの接続ID
        main_connection_id: main_conn_id,
        # 各スレッドの接続IDはすべて異なる（可能性が高い）
        thread_connection_ids: thread_conn_ids,
        # 各スレッドがユニークな接続を取得しているか
        all_unique: thread_conn_ids.uniq.size == thread_conn_ids.size,
        # 使用された接続の総数
        total_unique_connections: (thread_conn_ids + [main_conn_id]).uniq.size
      }
    end

    # 同一スレッド内では同じ接続が返されることを確認
    def self.demonstrate_same_thread_same_connection
      conn_ids = []

      ActiveRecord::Base.connection_pool.with_connection do |conn|
        conn_ids << conn.object_id

        # 同じスレッド内でもう一度 with_connection を呼ぶ
        ActiveRecord::Base.connection_pool.with_connection do |inner_conn|
          conn_ids << inner_conn.object_id
        end
      end

      {
        first_connection_id: conn_ids[0],
        second_connection_id: conn_ids[1],
        # 同じスレッドでは同じ接続が返される
        same_connection: conn_ids[0] == conn_ids[1]
      }
    end
  end

  # ==========================================================================
  # 4. プールサイズ設定: pool, checkout_timeout, idle_timeout, reaping
  # ==========================================================================
  module PoolConfiguration
    # プール設定のベストプラクティス
    #
    # 重要な設定パラメータ:
    # - pool: 最大接続数（デフォルト: 5）
    #   Pumaのスレッド数以上に設定する必要がある
    # - checkout_timeout: 接続取得の最大待機時間（デフォルト: 5秒）
    # - idle_timeout: アイドル接続の最大保持時間（デフォルト: 300秒）
    # - reaping_frequency: リーパーの実行間隔（デフォルト: 60秒）
    def self.demonstrate_configuration
      pool = ActiveRecord::Base.connection_pool
      db_config = pool.db_config

      {
        # 現在のプール設定
        pool_size: pool.size,
        checkout_timeout: pool.checkout_timeout,
        # データベース設定の詳細
        adapter: db_config.adapter,
        database: db_config.database,
        # 推奨設定の説明
        recommendation: {
          puma_threads: 'Pumaのmax_threads以上のpool値を設定',
          sidekiq_concurrency: 'Sidekiqのconcurrency以上のpool値を設定',
          formula: 'pool >= max(Puma max_threads, Sidekiq concurrency)',
          env_var: "ENV['RAILS_MAX_THREADS'] || 5 が一般的なデフォルト"
        }
      }
    end

    # 動的にプールサイズを変更する例
    # ※ 通常は database.yml で設定するが、テスト目的でプログラム的に変更
    def self.demonstrate_pool_size_info
      pool = ActiveRecord::Base.connection_pool

      {
        current_pool_size: pool.size,
        current_connections: pool.connections.size,
        # プールの状態
        stat: pool.stat
      }
    end
  end

  # ==========================================================================
  # 5. 接続枯渇: プール枯渇時のタイムアウト動作
  # ==========================================================================
  module ConnectionExhaustion
    # プールが枯渇した場合のタイムアウト動作を示す
    #
    # プール内の全接続が使用中の場合、新しい接続要求は
    # checkout_timeout（デフォルト5秒）だけ待機する。
    # タイムアウトすると ActiveRecord::ConnectionTimeoutError が発生する。
    def self.demonstrate_timeout_behavior
      # 小さいプールで新しい接続を確立してテスト
      config = {
        adapter: 'sqlite3',
        database: ':memory:',
        pool: 2,
        checkout_timeout: 1
      }

      hash_config = ActiveRecord::DatabaseConfigurations::HashConfig.new('test', 'primary', config)
      pool_config = ActiveRecord::ConnectionAdapters::PoolConfig.new(
        ActiveRecord::Base, hash_config, :writing, :default
      )
      pool = ActiveRecord::ConnectionAdapters::ConnectionPool.new(pool_config)

      # 2つの接続をすべてチェックアウト
      conn1 = pool.checkout
      conn2 = pool.checkout

      # 3つ目の取得を試みるとタイムアウトする
      timeout_error = nil
      elapsed = measure_time do
        pool.checkout
      rescue ActiveRecord::ConnectionTimeoutError => e
        timeout_error = e
      end

      # クリーンアップ
      pool.checkin(conn1)
      pool.checkin(conn2)
      pool.disconnect!

      {
        # タイムアウトエラーが発生した
        timeout_occurred: !timeout_error.nil?,
        error_class: timeout_error&.class&.name,
        error_message: timeout_error&.message,
        # おおよそ checkout_timeout 秒待機した
        elapsed_seconds: elapsed.round(1),
        approximate_timeout: elapsed.between?(0.9, 2.0)
      }
    end

    # 接続プール枯渇の検出方法
    def self.demonstrate_pool_exhaustion_detection
      pool = ActiveRecord::Base.connection_pool
      stat = pool.stat

      {
        # プール枯渇の兆候を検出するメトリクス
        pool_size: stat[:size],
        busy_connections: stat[:busy],
        idle_connections: stat[:idle],
        waiting_threads: stat[:waiting],
        # 枯渇判定: busy がサイズに近い場合は危険
        utilization_percent: stat[:size].positive? ? (stat[:busy].to_f / stat[:size] * 100).round(1) : 0,
        # 対処法
        remedies: %w[
          pool値をPumaスレッド数に合わせる
          with_connectionで接続を速やかに返却する
          長時間トランザクションを避ける
          コネクションリークを調査する
        ]
      }
    end

    def self.measure_time
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    end
  end

  # ==========================================================================
  # 6. with_connection パターン: 適切な接続管理
  # ==========================================================================
  module WithConnectionPattern
    # with_connection の正しい使い方と利点
    #
    # with_connection はブロックスコープで接続を管理する。
    # ブロック終了時に確実に接続がプールに返却されるため、
    # 接続リークを防止できる。
    def self.demonstrate_proper_usage
      pool = ActiveRecord::Base.connection_pool
      results = {}

      # 良い例: with_connection で接続を確実に返却
      pool.with_connection do |conn|
        results[:query_result] = conn.execute('SELECT 1 AS value').first
        results[:busy_during] = pool.stat[:busy]
      end
      results[:busy_after] = pool.stat[:busy]

      # 例外発生時も接続は返却される
      exception_returned = begin
        pool.with_connection do |_conn|
          raise StandardError, 'テストエラー'
        end
      rescue StandardError
        # 例外後もプールの接続状態を確認
        pool.stat[:busy]
      end
      results[:busy_after_exception] = exception_returned

      results
    end

    # connection メソッドの危険性
    #
    # ActiveRecord::Base.connection は接続をスレッドにバインドしたまま
    # 保持し続ける。明示的に返却しないと接続リークの原因になる。
    def self.demonstrate_connection_vs_with_connection
      {
        # connection: スレッドに接続がバインドされ続ける
        connection_behavior: 'ActiveRecord::Base.connectionはスレッドに紐付き保持される',
        # with_connection: ブロック終了で自動返却
        with_connection_behavior: 'with_connectionはブロック終了で自動返却',
        # 推奨パターン
        recommendation: 'バックグラウンドスレッドでは必ずwith_connectionを使用する',
        # Rails 7.2+のレイジー接続
        lazy_connection: 'Rails 7.2+ではwith_connectionもレイジーで実クエリまで接続を確保しない'
      }
    end
  end

  # ==========================================================================
  # 7. リーパースレッド: 不要な接続の回収
  # ==========================================================================
  module ReaperThread
    # リーパーの仕組みを解説
    #
    # Reaper はバックグラウンドスレッドとして動作し、
    # 定期的にプール内の接続を検査する。
    # - 所有スレッドが死んでいる接続を回収（reap）
    # - アイドル時間が idle_timeout を超えた接続を切断（flush）
    def self.demonstrate_reaper_concept
      pool = ActiveRecord::Base.connection_pool

      {
        # リーパーの役割
        purpose: 'デッドスレッドが保持する接続の回収とアイドル接続の切断',
        # リーパーの設定
        reaper_exists: pool.respond_to?(:reaper),
        # reap: 死んだスレッドの接続を回収
        reap_description: '所有スレッドがalive?でない接続をプールに戻す',
        # flush: アイドル接続の切断
        flush_description: 'idle_timeout秒以上使われていない接続を切断する',
        # 設定値
        configuration: {
          reaping_frequency: 'デフォルト60秒ごとにリーパーが実行される',
          idle_timeout: 'デフォルト300秒（5分）でアイドル接続を切断'
        }
      }
    end

    # 手動でリーパー処理を呼び出す
    def self.demonstrate_manual_reap
      pool = ActiveRecord::Base.connection_pool

      # スレッドで接続を取得し、スレッドを終了させる
      thread = Thread.new do
        pool.with_connection do |conn|
          conn.execute('SELECT 1')
          # スレッド終了時、with_connectionにより接続が返却される
        end
      end
      thread.join

      stat_before = pool.stat

      # reap を手動実行（死んだスレッドの接続を回収）
      pool.reap

      stat_after = pool.stat

      {
        before_reap: stat_before,
        after_reap: stat_after,
        # with_connectionを使用しているため、すでに返却済みの場合が多い
        note: 'with_connectionはブロック終了で自動返却するため、reapは主にリーク対策'
      }
    end
  end

  # ==========================================================================
  # 8. マルチスレッド安全性: Mutex と ConditionVariable の内部
  # ==========================================================================
  module MultiThreadSafety
    # コネクションプールの内部同期メカニズム
    #
    # ActiveRecordのConnectionPoolは以下の同期プリミティブを使用:
    # - Mutex: @connections 配列やプール状態への排他アクセス
    # - ConditionVariable: 接続の空き待ちに使用
    #
    # checkout の疑似コード:
    #   mutex.synchronize do
    #     loop do
    #       return available.pop if available.any?
    #       return new_connection if connections.size < size
    #       cond.wait(mutex, timeout)
    #       raise Timeout if timed_out?
    #     end
    #   end
    def self.demonstrate_thread_safety
      pool = ActiveRecord::Base.connection_pool
      results = Mutex.new
      collected = []

      # 複数スレッドから同時にプールにアクセス
      threads = 10.times.map do |i|
        Thread.new do
          pool.with_connection do |conn|
            # クエリを実行
            # i はループインデックス（Integer）のため安全
            value = conn.execute("SELECT #{i.to_i} AS num").first
            results.synchronize { collected << value }
          end
        end
      end

      threads.each(&:join)

      {
        # 全スレッドが正常に完了
        all_completed: collected.size == 10,
        result_count: collected.size,
        # プールのスレッドセーフ性が保証されている
        thread_safe: true,
        # プールのstat情報
        pool_stat: pool.stat
      }
    end

    # 複数スレッドでの同時書き込みテスト
    #
    # 注意: SQLite の :memory: データベースはコネクションごとに独立しているため、
    # file::memory:?cache=shared でない場合はスレッドからテーブルが見えない。
    # そのため、共有キャッシュが利用できない環境では直列書き込みにフォールバックする。
    def self.demonstrate_concurrent_writes
      # テーブルをクリーンアップ
      PoolTestRecord.delete_all

      db_config = ActiveRecord::Base.connection_db_config.configuration_hash
      shared_cache = db_config[:database].to_s.include?('cache=shared')

      if shared_cache
        # 共有キャッシュの場合: 真のマルチスレッド書き込み
        threads = 5.times.map do |i|
          Thread.new do
            ActiveRecord::Base.connection_pool.with_connection do
              PoolTestRecord.create!(name: "Thread-#{i}")
            end
          end
        end
        threads.each(&:join)
      else
        # 非共有 :memory: の場合: コネクションプールから接続を取得して書き込み
        # （スレッドセーフ性のデモはプールの checkout/checkin で示す）
        5.times do |i|
          ActiveRecord::Base.connection_pool.with_connection do
            PoolTestRecord.create!(name: "Thread-#{i}")
          end
        end
      end

      {
        # 全レコードが正常に作成された
        total_records: PoolTestRecord.count,
        records: PoolTestRecord.order(:name).pluck(:name),
        all_created: PoolTestRecord.count == 5
      }
    end
  end

  # ==========================================================================
  # 9. 教育用: 簡易コネクションプール実装
  # ==========================================================================
  #
  # ActiveRecordのConnectionPoolの核心アルゴリズムを
  # シンプルに再実装して内部動作を理解する。
  #
  # 主要コンポーネント:
  # - Mutex: 排他制御
  # - ConditionVariable: 接続の空き通知
  # - 接続キュー: 利用可能な接続の管理
  class SimpleConnectionPool
    attr_reader :size, :checkout_timeout, :connections, :available

    def initialize(size:, checkout_timeout: 5, &connection_factory)
      @size = size
      @checkout_timeout = checkout_timeout
      @connection_factory = connection_factory

      # 全接続を追跡する配列
      @connections = []
      # 利用可能な接続のキュー
      @available = []
      # スレッドごとの接続マッピング
      @thread_connections = {}

      # 排他制御用のMutex
      @mutex = Mutex.new
      # 接続の空き待ち用のConditionVariable
      @cond = ConditionVariable.new
    end

    # 接続をチェックアウト（取得）する
    #
    # 1. 現在のスレッドに既にバインドされた接続があればそれを返す
    # 2. 利用可能な接続があればキューから取得
    # 3. プールに余裕があれば新規作成
    # 4. なければタイムアウトまで待機
    def checkout
      @mutex.synchronize do
        # 現在のスレッドに接続がバインドされていればそれを返す
        thread_id = Thread.current.object_id
        return @thread_connections[thread_id] if @thread_connections[thread_id]

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @checkout_timeout

        loop do
          # 利用可能な接続があればそれを使う
          if (conn = @available.pop)
            @thread_connections[thread_id] = conn
            return conn
          end

          # プールに余裕があれば新規作成
          if @connections.size < @size
            conn = create_connection
            @thread_connections[thread_id] = conn
            return conn
          end

          # 待機時間を計算
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if remaining <= 0
            raise ConnectionTimeoutError,
                  "プール枯渇: #{@checkout_timeout}秒以内に接続を取得できませんでした " \
                  "(プールサイズ: #{@size}, 使用中: #{@connections.size - @available.size})"
          end

          # ConditionVariable で接続の空きを待つ
          @cond.wait(@mutex, remaining)
        end
      end
    end

    # 接続をチェックイン（返却）する
    def checkin(conn)
      @mutex.synchronize do
        thread_id = Thread.current.object_id
        @thread_connections.delete(thread_id)
        @available.push(conn)
        # 待機中のスレッドに通知
        @cond.signal
      end
    end

    # with_connection パターン: ブロック終了で自動返却
    def with_connection
      conn = checkout
      yield conn
    ensure
      checkin(conn) if conn
    end

    # プールの統計情報
    def stat
      @mutex.synchronize do
        {
          size: @size,
          connections: @connections.size,
          available: @available.size,
          busy: @connections.size - @available.size
        }
      end
    end

    # 全接続を切断
    def disconnect!
      @mutex.synchronize do
        @connections.each { |c| c[:active] = false }
        @connections.clear
        @available.clear
        @thread_connections.clear
      end
    end

    # 死んだスレッドの接続を回収（簡易版リーパー）
    def reap
      @mutex.synchronize do
        dead_thread_ids = @thread_connections.keys.reject do |tid|
          Thread.list.any? { |t| t.object_id == tid }
        end

        dead_thread_ids.each do |tid|
          conn = @thread_connections.delete(tid)
          @available.push(conn) if conn
          @cond.signal
        end

        dead_thread_ids.size
      end
    end

    private

    def create_connection
      conn = @connection_factory.call
      @connections << conn
      conn
    end
  end

  # SimpleConnectionPool 用のタイムアウトエラー
  class ConnectionTimeoutError < StandardError; end

  # ==========================================================================
  # SimpleConnectionPool のデモンストレーション
  # ==========================================================================
  module SimplePoolDemo
    # 基本的な使い方のデモ
    def self.demonstrate_basic_usage
      connection_count = 0
      pool = SimpleConnectionPool.new(size: 3, checkout_timeout: 2) do
        connection_count += 1
        { id: connection_count, active: true, created_at: Time.now }
      end

      results = {}

      # with_connection パターン
      pool.with_connection do |conn|
        results[:first_connection] = conn[:id]
        results[:stat_during] = pool.stat
      end
      results[:stat_after] = pool.stat

      results
    end

    # マルチスレッドでの動作デモ
    def self.demonstrate_multithreaded
      connection_count = 0
      mutex = Mutex.new
      pool = SimpleConnectionPool.new(size: 3, checkout_timeout: 2) do
        mutex.synchronize do
          connection_count += 1
          { id: connection_count, active: true }
        end
      end

      thread_results = []
      result_mutex = Mutex.new

      threads = 6.times.map do |i|
        Thread.new do
          pool.with_connection do |conn|
            sleep(0.01) # 短い処理をシミュレート
            result_mutex.synchronize do
              thread_results << { thread: i, connection_id: conn[:id] }
            end
          end
        end
      end

      threads.each(&:join)

      {
        total_threads: thread_results.size,
        all_completed: thread_results.size == 6,
        # 3つの接続が6スレッドで再利用された
        unique_connections: thread_results.map { |r| r[:connection_id] }.uniq.size,
        max_connections_created: connection_count,
        pool_stat: pool.stat
      }
    end

    # タイムアウト動作のデモ
    def self.demonstrate_timeout
      pool = SimpleConnectionPool.new(size: 1, checkout_timeout: 1) do
        { id: 1, active: true }
      end

      # 1つの接続をチェックアウトして保持
      conn = pool.checkout

      # 別スレッドでタイムアウトを確認
      error = nil
      thread = Thread.new do
        pool.checkout
      rescue ConnectionTimeoutError => e
        error = e
      end
      thread.join

      # クリーンアップ
      pool.checkin(conn)

      {
        timeout_occurred: !error.nil?,
        error_message: error&.message,
        error_class: error&.class&.name
      }
    end

    # リーパーのデモ
    def self.demonstrate_reaper
      connection_count = 0
      pool = SimpleConnectionPool.new(size: 3, checkout_timeout: 2) do
        connection_count += 1
        { id: connection_count, active: true }
      end

      # スレッドで接続を取得し、checkin せずにスレッドを終了
      # （意図的な接続リーク）
      thread = Thread.new do
        pool.checkout
        # checkin しない → スレッド終了後に接続がリークする
      end
      thread.join

      stat_before = pool.stat

      # リーパーで回収
      reaped_count = pool.reap

      stat_after = pool.stat

      {
        before_reap: stat_before,
        after_reap: stat_after,
        reaped_connections: reaped_count,
        # リーパーにより接続が利用可能になった
        connection_recovered: stat_after[:available] > stat_before[:available]
      }
    end
  end
end
