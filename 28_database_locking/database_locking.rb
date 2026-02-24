# frozen_string_literal: true

# データベースロック戦略を解説するモジュール
#
# マルチユーザー環境のWebアプリケーションでは、同一レコードへの同時アクセスが
# 頻繁に発生する。適切なロック戦略を選択しないと、データの不整合（lost update）や
# デッドロックが発生し、致命的なバグにつながる。
#
# このモジュールでは、シニアRailsエンジニアが知るべきロック戦略を
# 実例を通じて学ぶ:
#   - 楽観的ロック（Optimistic Locking）: lock_version カラムによる競合検出
#   - 悲観的ロック（Pessimistic Locking）: SELECT FOR UPDATE による排他制御
#   - アドバイザリーロック（Advisory Locks）: アプリケーションレベルのロック
#   - デッドロック防止: ロック順序戦略とタイムアウト設定
#   - 競合状態の実例: ロックなしで発生する lost update 問題
#   - リトライパターン: StaleObjectError のハンドリング

require 'active_record'

# テスト用のインメモリSQLiteデータベースをセットアップ
# file::memory:?cache=shared を使用することで、複数の接続（スレッド）から
# 同一のインメモリデータベースにアクセスできる
unless ActiveRecord::Base.connected?
  ActiveRecord::Base.establish_connection(
    adapter: 'sqlite3',
    database: 'file::memory:?cache=shared',
    pool: 10
  )
end
ActiveRecord::Base.logger = nil # テスト時のログ出力を抑制

ActiveRecord::Schema.define do
  create_table :accounts, force: true do |t|
    t.string :name
    t.integer :balance, default: 0
    # lock_version カラム: ActiveRecordの楽観的ロックで使用
    # このカラムが存在すると、更新時に自動的にバージョンチェックが行われる
    t.integer :lock_version, default: 0
    t.timestamps null: false
  end

  create_table :transfer_logs, force: true do |t|
    t.integer :from_account_id
    t.integer :to_account_id
    t.integer :amount
    t.string :status
    t.timestamps null: false
  end
end

# 口座モデル: lock_version カラムにより楽観的ロックが自動有効化される
class Account < ActiveRecord::Base
  has_many :outgoing_transfers, class_name: 'TransferLog', foreign_key: :from_account_id
  has_many :incoming_transfers, class_name: 'TransferLog', foreign_key: :to_account_id

  validates :balance, numericality: { greater_than_or_equal_to: 0 }
end

# 送金ログモデル
class TransferLog < ActiveRecord::Base
  belongs_to :from_account, class_name: 'Account'
  belongs_to :to_account, class_name: 'Account'
end

module DatabaseLocking
  # ==========================================================================
  # 1. 楽観的ロック（Optimistic Locking）: lock_version による競合検出
  # ==========================================================================
  #
  # 楽観的ロックは「ほとんどの場合、競合は起きない」という前提に基づく。
  # データ読み取り時にバージョン番号を取得し、更新時にバージョンが変わって
  # いないことを確認する。変わっていた場合は StaleObjectError を発生させる。
  #
  # ActiveRecordでは lock_version カラムが存在するだけで自動的に有効になる。
  # UPDATE accounts SET balance = ?, lock_version = lock_version + 1
  # WHERE id = ? AND lock_version = ?
  module OptimisticLocking
    # 楽観的ロックの基本動作を示す
    #
    # 同一レコードを2つのインスタンスで読み取り、
    # 片方が先に更新すると、もう片方の更新時に StaleObjectError が発生する。
    def self.demonstrate_basic_optimistic_lock
      Account.delete_all
      account = Account.create!(name: 'Alice', balance: 1000)

      # 2つのインスタンスで同じレコードを読み取る
      # （2つのブラウザタブで同じページを開いた状況をシミュレート）
      instance_a = Account.find(account.id)
      instance_b = Account.find(account.id)

      initial_version = instance_a.lock_version

      # インスタンスAが先に更新（成功する）
      instance_a.update!(balance: 900)
      version_after_a = instance_a.lock_version

      # インスタンスBが更新を試みる（StaleObjectError が発生する）
      stale_error = nil
      begin
        instance_b.update!(balance: 800)
      rescue ActiveRecord::StaleObjectError => e
        stale_error = e
      end

      # データベース上の最新値を確認
      account.reload

      {
        initial_version: initial_version,
        version_after_a_update: version_after_a,
        stale_error_occurred: !stale_error.nil?,
        stale_error_class: stale_error&.class&.name,
        stale_error_message: stale_error&.message&.slice(0, 100),
        # インスタンスBの更新は反映されていない
        final_balance: account.balance,
        final_version: account.lock_version,
        # lock_version は更新ごとに1ずつ増加する
        version_incremented: version_after_a == initial_version + 1
      }
    end

    # lock_version の自動インクリメントを確認する
    def self.demonstrate_version_increment
      Account.delete_all
      account = Account.create!(name: 'Bob', balance: 500)

      versions = [account.lock_version]
      3.times do |i|
        account.update!(balance: 500 + ((i + 1) * 100))
        versions << account.lock_version
      end

      {
        # lock_version は 0, 1, 2, 3 と増加する
        version_history: versions,
        monotonically_increasing: versions.each_cons(2).all? { |a, b| b == a + 1 }
      }
    end
  end

  # ==========================================================================
  # 2. 悲観的ロック（Pessimistic Locking）: SELECT FOR UPDATE
  # ==========================================================================
  #
  # 悲観的ロックは「競合が頻繁に起きる」という前提に基づく。
  # データを読み取る時点で排他ロックを取得し、トランザクション終了まで
  # 他のトランザクションからのアクセスをブロックする。
  #
  # ActiveRecordでは lock! メソッドや with_lock ブロックで利用できる。
  # ※ SQLiteは SELECT FOR UPDATE をサポートしないため、
  #   ここでは概念の説明とSQLiteで可能な範囲のデモを行う。
  module PessimisticLocking
    # lock! メソッドの概念を示す
    #
    # lock! は SELECT ... FOR UPDATE を発行し、
    # そのレコードに対する排他ロックを取得する。
    # トランザクション内でのみ有効。
    def self.demonstrate_lock_concept
      Account.delete_all
      account = Account.create!(name: 'Charlie', balance: 2000)

      result = nil
      Account.transaction do
        # lock! はレコードをリロードし、排他ロックを取得する
        # SQLiteでは FOR UPDATE は発行されないが、トランザクション内の
        # シリアライゼーションにより同等の効果がある
        locked_account = Account.find(account.id)
        locked_account.lock!

        # ロック取得後、安全に残高を更新
        locked_account.balance -= 500
        locked_account.save!

        result = {
          balance_after_withdrawal: locked_account.balance,
          lock_version: locked_account.lock_version
        }
      end

      account.reload

      {
        balance: account.balance,
        lock_version: account.lock_version,
        transaction_result: result,
        # 悲観的ロックでは lock_version は変更されない
        # （lock_versionは楽観的ロック専用）
        note: 'lock!は楽観的ロックのlock_versionとは独立して動作する'
      }
    end

    # with_lock ブロックの使用法を示す
    #
    # with_lock はトランザクション開始 + lock! + ブロック実行を
    # 一括で行う便利メソッド。実務で最もよく使うパターン。
    def self.demonstrate_with_lock
      Account.delete_all
      account = Account.create!(name: 'Diana', balance: 3000)

      # with_lock はトランザクション + lock! を自動で行う
      account.with_lock do
        account.balance -= 1000
        account.save!
      end

      account.reload

      {
        balance: account.balance,
        # with_lock はブロック内で安全にレコードを更新できる
        expected_balance: 2000,
        balance_correct: account.balance == 2000,
        usage_pattern: 'account.with_lock { account.update!(balance: new_value) }'
      }
    end

    # 悲観的ロックが生成するSQLの概念を説明する
    def self.demonstrate_sql_concepts
      {
        # PostgreSQL/MySQLで発行されるSQL
        select_for_update: 'SELECT * FROM accounts WHERE id = 1 FOR UPDATE',
        # NOWAIT: ロック取得できない場合は即座にエラー
        select_for_update_nowait: 'SELECT * FROM accounts WHERE id = 1 FOR UPDATE NOWAIT',
        # SKIP LOCKED: ロックされたレコードをスキップ（キューパターンで有用）
        select_skip_locked: 'SELECT * FROM accounts WHERE id = 1 FOR UPDATE SKIP LOCKED',
        # ActiveRecordでの使い方
        activerecord_usage: {
          basic: 'Account.lock.find(1)',
          nowait: 'Account.lock("FOR UPDATE NOWAIT").find(1)',
          skip_locked: 'Account.lock("FOR UPDATE SKIP LOCKED").find(1)',
          with_lock: 'account.with_lock { account.update!(balance: 100) }'
        }
      }
    end
  end

  # ==========================================================================
  # 3. アドバイザリーロック（Advisory Locks）: アプリケーションレベルのロック
  # ==========================================================================
  #
  # アドバイザリーロックはデータベースが提供するアプリケーションレベルの
  # ロック機構。テーブルやレコードに紐付かず、任意のキーに対して
  # ロックを取得できる。
  #
  # PostgreSQLの pg_advisory_lock / pg_try_advisory_lock が代表的。
  # Rails自体も内部でマイグレーション時にアドバイザリーロックを使用する。
  module AdvisoryLocks
    # アドバイザリーロックの概念と使用パターンを説明する
    def self.demonstrate_advisory_lock_concepts
      {
        # アドバイザリーロックの特徴
        characteristics: {
          application_level: 'テーブルやレコードに紐付かない自由なロック',
          key_based: '整数キーまたは文字列キーでロックを識別',
          session_or_transaction: 'セッションスコープまたはトランザクションスコープ',
          non_blocking_option: 'pg_try_advisory_lock でノンブロッキング取得可能'
        },
        # PostgreSQLでの使用例
        postgresql_examples: {
          session_lock: 'SELECT pg_advisory_lock(12345)',
          session_unlock: 'SELECT pg_advisory_unlock(12345)',
          transaction_lock: 'SELECT pg_advisory_xact_lock(12345)',
          try_lock: 'SELECT pg_try_advisory_lock(12345)'
        },
        # Railsでの活用例
        rails_usage: {
          migration_lock: 'Railsのマイグレーションはアドバイザリーロックで排他制御',
          custom_lock: '独自のバッチ処理やキュー処理の二重実行防止に活用'
        },
        # 実装パターン: Rubyのミューテックスによるシミュレーション
        mutex_simulation: demonstrate_mutex_based_lock
      }
    end

    # Rubyのミューテックスを使ったアドバイザリーロックのシミュレーション
    #
    # 本番環境ではPostgreSQLのアドバイザリーロックを使うが、
    # 概念理解のためにRubyレベルでシミュレートする。
    def self.demonstrate_mutex_based_lock
      lock_registry = {}

      # ロック取得関数（アドバイザリーロックの概念を模倣）
      acquire_lock = lambda do |key|
        lock_registry[key] ||= Mutex.new
        lock_registry[key].try_lock
      end

      release_lock = lambda do |key|
        lock_registry[key]&.unlock if lock_registry[key]&.owned?
      end

      # 逐次的にロック取得を試みる（概念の説明）
      # プロセスAがロックを取得
      acquired_a = acquire_lock.call('batch_job_001')

      # プロセスBが同じキーでロックを取得しようとする（失敗する）
      acquired_b = acquire_lock.call('batch_job_001')

      results = [
        { process: 'A', lock_acquired: acquired_a },
        { process: 'B', lock_acquired: acquired_b }
      ]

      # ロック解放
      release_lock.call('batch_job_001')

      {
        results: results,
        # 最初の取得者だけがロックを獲得できる
        exactly_one_acquired: results.one? { |r| r[:lock_acquired] },
        first_acquired: acquired_a,
        second_blocked: !acquired_b
      }
    end
  end

  # ==========================================================================
  # 4. デッドロック防止: ロック順序戦略とタイムアウト設定
  # ==========================================================================
  #
  # デッドロックは2つ以上のトランザクションが互いのロック解放を
  # 待ち続ける状態。例えば:
  #   トランザクションA: 口座1をロック → 口座2のロック待ち
  #   トランザクションB: 口座2をロック → 口座1のロック待ち
  #
  # 防止策:
  # 1. ロック順序の固定（ID昇順でロック）
  # 2. タイムアウトの設定
  # 3. リトライパターンの実装
  module DeadlockPrevention
    # ロック順序によるデッドロック防止を示す
    #
    # 口座間送金時に、常にID昇順でロックを取得することで
    # デッドロックを防止する。
    def self.demonstrate_lock_ordering
      Account.delete_all
      account_a = Account.create!(name: 'Account-A', balance: 1000)
      account_b = Account.create!(name: 'Account-B', balance: 1000)

      # 安全な送金: ID昇順でロックを取得する
      transfer_result = safe_transfer(
        from_id: account_a.id,
        to_id: account_b.id,
        amount: 300
      )

      account_a.reload
      account_b.reload

      {
        transfer_success: transfer_result[:success],
        account_a_balance: account_a.balance,
        account_b_balance: account_b.balance,
        total_balance: account_a.balance + account_b.balance,
        # 総残高が保存されている（整合性の確認）
        balance_preserved: (account_a.balance + account_b.balance) == 2000,
        lock_order: transfer_result[:lock_order]
      }
    end

    # 安全な送金処理: ロック順序を固定してデッドロックを防止
    def self.safe_transfer(from_id:, to_id:, amount:)
      # 常にID昇順でロックを取得する（デッドロック防止の鍵）
      first_id, second_id = [from_id, to_id].sort

      Account.transaction do
        first = Account.lock.find(first_id)
        second = Account.lock.find(second_id)

        # from/to を正しく割り当て
        from_account = from_id == first_id ? first : second
        to_account = to_id == first_id ? first : second

        return { success: false, error: '残高不足' } if from_account.balance < amount

        from_account.balance -= amount
        to_account.balance += amount
        from_account.save!
        to_account.save!

        TransferLog.create!(
          from_account_id: from_id,
          to_account_id: to_id,
          amount: amount,
          status: 'completed'
        )

        { success: true, lock_order: [first_id, second_id] }
      end
    end

    # デッドロック発生シナリオの説明
    def self.demonstrate_deadlock_scenario
      {
        # デッドロックが発生するパターン
        dangerous_pattern: {
          step1: 'トランザクションA: 口座1をロック（成功）',
          step2: 'トランザクションB: 口座2をロック（成功）',
          step3: 'トランザクションA: 口座2をロック（待ち）← Bが保持中',
          step4: 'トランザクションB: 口座1をロック（待ち）← Aが保持中',
          result: 'デッドロック！両方が永遠に待ち続ける'
        },
        # 安全なパターン（ロック順序の固定）
        safe_pattern: {
          rule: '常にIDの昇順でロックを取得する',
          step1: 'トランザクションA: 口座1をロック（成功）',
          step2: 'トランザクションB: 口座1をロック（待ち）← Aの完了を待つ',
          step3: 'トランザクションA: 口座2をロック（成功）、処理完了、ロック解放',
          step4: 'トランザクションB: 口座1をロック（成功）、口座2をロック（成功）',
          result: 'デッドロックなし！順序が保証される'
        },
        # タイムアウト設定
        timeout_config: {
          mysql: 'SET innodb_lock_wait_timeout = 5',
          postgresql: "SET lock_timeout = '5s'",
          rails: "ActiveRecord::Base.connection.execute(\"SET lock_timeout = '5s'\")"
        }
      }
    end
  end

  # ==========================================================================
  # 5. 競合状態（Race Condition）: ロックなしの lost update 問題
  # ==========================================================================
  #
  # ロックなしで同一レコードを同時更新すると、一方の更新が消失する。
  # これが「lost update」問題。典型例:
  #   1. スレッドA: balance = 1000 を読み取る
  #   2. スレッドB: balance = 1000 を読み取る
  #   3. スレッドA: balance = 1000 - 100 = 900 に更新
  #   4. スレッドB: balance = 1000 - 200 = 800 に更新（Aの更新が消失！）
  module RaceConditionExamples
    # ロックなしの競合状態（lost update）をシミュレーションで再現する
    #
    # 本番環境（PostgreSQL/MySQL）ではスレッド並行処理で発生するが、
    # ここでは教育目的で、2つのインスタンスが古いデータを基に更新する
    # シナリオを逐次的に再現する。
    #
    # シナリオ:
    #   1. インスタンスA: balance = 1000 を読み取る
    #   2. インスタンスB: balance = 1000 を読み取る（同じ古い値）
    #   3. インスタンスA: balance = 1000 - 100 = 900 に更新
    #   4. インスタンスB: balance = 1000 - 200 = 800 に更新（Aの更新が消失！）
    def self.demonstrate_lost_update
      Account.delete_all
      account = Account.create!(name: 'Race-Test', balance: 1000)

      # 2つのインスタンスが同時にデータを読み取る状況をシミュレート
      instance_a = Account.find(account.id)
      instance_b = Account.find(account.id)

      # 両方とも balance = 1000 を読み取り済み
      balance_a_read = instance_a.balance
      balance_b_read = instance_b.balance

      # インスタンスAが -100 で更新（update_columns はlock_versionを無視する）
      instance_a.update_columns(balance: balance_a_read - 100) # → 900
      # インスタンスBが古い値（1000）を基に -200 で更新（Aの更新が消失）
      instance_b.update_columns(balance: balance_b_read - 200) # → 800
      account.reload
      # 期待値: 1000 - 100 - 200 = 700
      # 実際値: 800（インスタンスAの -100 が消失）
      expected_balance = 700

      {
        balance_a_read: balance_a_read,
        balance_b_read: balance_b_read,
        final_balance: account.balance,
        expected_balance: expected_balance,
        lost_update_occurred: account.balance != expected_balance,
        lost_amount: account.balance - expected_balance,
        explanation: 'read-modify-writeをロックなしで実行すると ' \
                     'lost updateが発生し、Aの引き出し100円分が消失した'
      }
    end

    # 安全な更新: SQLレベルのアトミック操作
    #
    # UPDATE accounts SET balance = balance - 100 WHERE id = ?
    # この方法なら中間の read が不要で、DBレベルでアトミックに処理される。
    def self.demonstrate_atomic_update
      Account.delete_all
      account = Account.create!(name: 'Atomic-Test', balance: 1000)

      # 10回の引き出しを逐次アトミックSQLで実行
      # 本番環境では並行実行されるが、アトミック操作なので結果は同じ
      10.times do
        Account.where(id: account.id).update_all('balance = balance - 100')
      end

      account.reload

      {
        final_balance: account.balance,
        expected_balance: 0,
        balance_correct: account.balance.zero?,
        # SQLレベルのアトミック更新なので lost update が発生しない
        explanation: 'UPDATE ... SET balance = balance - 100 は ' \
                     'DBレベルでアトミックに処理されるため安全'
      }
    end

    # 楽観的ロックによる競合検出を示す
    #
    # 2つのインスタンスが同時に更新を試み、
    # 後から更新した方が StaleObjectError で拒否されることを確認する。
    def self.demonstrate_safe_update_with_optimistic_lock
      Account.delete_all
      account = Account.create!(name: 'Optimistic-Test', balance: 1000)

      success_count = 0
      stale_count = 0

      # 5回の更新を試みる（各回で2つのインスタンスが競合する）
      5.times do
        instance_a = Account.find(account.id)
        instance_b = Account.find(account.id)

        # インスタンスAが先に更新（成功する）
        begin
          instance_a.balance -= 100
          instance_a.save!
          success_count += 1
        rescue ActiveRecord::StaleObjectError
          stale_count += 1
        end

        # インスタンスBが更新を試みる（StaleObjectError が発生する）
        begin
          instance_b.balance -= 100
          instance_b.save!
          success_count += 1
        rescue ActiveRecord::StaleObjectError
          stale_count += 1
        end
      end

      account.reload

      {
        success_count: success_count,
        stale_error_count: stale_count,
        total_attempts: success_count + stale_count,
        final_balance: account.balance,
        # 楽観的ロックにより、競合した更新は StaleObjectError で拒否される
        explanation: '楽観的ロックにより同時更新の競合を検出し、' \
                     'StaleObjectError で安全に拒否する'
      }
    end
  end

  # ==========================================================================
  # 6. リトライパターン: StaleObjectError のハンドリング
  # ==========================================================================
  #
  # 楽観的ロックで StaleObjectError が発生した場合、
  # レコードを再読み込みしてリトライするパターン。
  # 指数バックオフを組み合わせて、高競合環境でも安定動作させる。
  module RetryPatterns
    # 基本的なリトライパターンを示す
    def self.demonstrate_basic_retry
      Account.delete_all
      account = Account.create!(name: 'Retry-Test', balance: 1000)

      retry_count = 0
      max_retries = 3

      # リトライ付き更新: StaleObjectError発生時にDBから再取得してリトライ
      result = begin
        acc = Account.find(account.id)
        acc.balance -= 100
        acc.save!
        { success: true, retries: retry_count }
      rescue ActiveRecord::StaleObjectError
        retry_count += 1
        retry if retry_count <= max_retries
        { success: false, retries: retry_count, error: '最大リトライ回数超過' }
      end

      account.reload

      {
        result: result,
        final_balance: account.balance,
        pattern: 'StaleObjectError → Account.find（再取得） → retry（最大3回）'
      }
    end

    # 指数バックオフ付きリトライパターン
    #
    # 高競合環境ではリトライ間隔をランダムに広げることで
    # 衝突確率を下げる（Exponential Backoff with Jitter）。
    def self.demonstrate_exponential_backoff_retry
      Account.delete_all
      Account.create!(name: 'Backoff-Test', balance: 1000)

      # リトライヘルパーメソッドの使用例
      update_result = with_optimistic_retry(max_retries: 5) do
        acc = Account.find(Account.last.id)
        acc.balance -= 200
        acc.save!
        acc.balance
      end

      {
        result: update_result,
        pattern: '指数バックオフ + ジッターによるリトライ',
        backoff_formula: 'sleep(base_delay * (2 ** retry_count) * rand)',
        recommendation: '高競合環境では max_retries を 5〜10 に設定'
      }
    end

    # 汎用的なリトライヘルパーメソッド
    #
    # @param max_retries [Integer] 最大リトライ回数
    # @param base_delay [Float] 基本待機時間（秒）
    # @yield リトライ対象のブロック
    # @return [Hash] 実行結果
    def self.with_optimistic_retry(max_retries: 3, base_delay: 0.01)
      retries = 0
      begin
        result = yield
        { success: true, value: result, retries: retries }
      rescue ActiveRecord::StaleObjectError
        retries += 1
        if retries <= max_retries
          # 指数バックオフ + ジッター
          delay = base_delay * (2**retries) * rand
          sleep(delay)
          retry
        end
        { success: false, retries: retries, error: "最大リトライ回数 (#{max_retries}) 超過" }
      end
    end

    # 実務での包括的な更新パターンを示す
    def self.demonstrate_production_pattern
      Account.delete_all
      account = Account.create!(name: 'Production-Test', balance: 5000)

      # 実務で推奨されるパターン: リトライ + ログ + フォールバック
      withdrawal_result = production_safe_withdraw(
        account_id: account.id,
        amount: 500
      )

      account.reload

      {
        result: withdrawal_result,
        final_balance: account.balance,
        pattern_description: {
          step1: '楽観的ロックでまず試行',
          step2: 'StaleObjectError で指数バックオフリトライ',
          step3: 'リトライ上限超過時はエラーレスポンスを返す',
          step4: '必要に応じて悲観的ロックにフォールバック'
        }
      }
    end

    # 実務向けの安全な出金処理
    def self.production_safe_withdraw(account_id:, amount:, max_retries: 3)
      retries = 0
      begin
        account = Account.find(account_id)

        return { success: false, error: '残高不足', balance: account.balance } if account.balance < amount

        account.balance -= amount
        account.save!

        { success: true, new_balance: account.balance, retries: retries }
      rescue ActiveRecord::StaleObjectError
        retries += 1
        if retries <= max_retries
          sleep(0.01 * (2**retries) * rand)
          retry
        end
        # リトライ上限超過: 悲観的ロックにフォールバック
        pessimistic_withdraw(account_id: account_id, amount: amount)
      end
    end

    # 悲観的ロックによるフォールバック出金処理
    def self.pessimistic_withdraw(account_id:, amount:)
      Account.transaction do
        account = Account.lock.find(account_id)

        return { success: false, error: '残高不足（悲観的ロック）', balance: account.balance } if account.balance < amount

        account.balance -= amount
        account.save!

        { success: true, new_balance: account.balance, method: 'pessimistic_fallback' }
      end
    end
  end

  # ==========================================================================
  # 7. ロック戦略の選択: 楽観的 vs 悲観的の判断基準
  # ==========================================================================
  #
  # どのロック戦略を使うかは、アプリケーションの特性に依存する。
  # 以下の判断基準を参考に選択する。
  module LockStrategyDecision
    # ロック戦略の判断フレームワーク
    def self.demonstrate_decision_framework
      {
        optimistic_locking: {
          description: '楽観的ロック（lock_version）',
          when_to_use: [
            '読み取りが多く、書き込みの競合が少ない場合',
            'フォーム送信のような人間操作ベースの更新',
            '長時間のトランザクションを避けたい場合',
            'Web UIで編集フォームを提供する場合'
          ],
          advantages: [
            'ロック保持時間がゼロ（読み取り時にロックしない）',
            'デッドロックが発生しない',
            'スループットが高い',
            '実装がシンプル（lock_versionカラム追加のみ）'
          ],
          disadvantages: %w[
            競合時にユーザー側のリトライが必要
            高競合環境ではリトライが頻発する
            StaleObjectErrorのハンドリングが必須
          ],
          implementation: 'テーブルにlock_version:integerカラムを追加するだけ'
        },
        pessimistic_locking: {
          description: '悲観的ロック（SELECT FOR UPDATE）',
          when_to_use: [
            '書き込みの競合が頻繁に発生する場合',
            '金融取引など絶対にlost updateを許容できない場合',
            'トランザクションが短い場合',
            'バッチ処理でのレコード排他処理'
          ],
          advantages: %w[
            競合を完全に防止できる
            リトライ不要で確実に更新できる
            実装のメンタルモデルがシンプル
          ],
          disadvantages: %w[
            ロック保持中は他のトランザクションがブロックされる
            デッドロックのリスクがある
            長時間ロックはスループットを低下させる
          ],
          implementation: 'account.with_lock { account.update!(...) }'
        },
        atomic_sql: {
          description: 'SQLレベルのアトミック操作',
          when_to_use: [
            'カウンター・残高のインクリメント/デクリメント',
            '単純な数値の加減算',
            'ロックのオーバーヘッドを避けたい場合'
          ],
          advantages: %w[
            最もシンプルで高速
            ロック不要
            デッドロックなし
          ],
          disadvantages: [
            '複雑な条件付き更新には不向き',
            'ActiveRecordのコールバック・バリデーションが実行されない',
            'ビジネスロジックをSQL内に書く必要がある場合がある'
          ],
          implementation: "Account.where(id: 1).update_all('balance = balance - 100')"
        },
        advisory_locks: {
          description: 'アドバイザリーロック',
          when_to_use: [
            'テーブル・レコードに紐付かないロックが必要な場合',
            'バッチ処理の二重実行防止',
            'マイグレーションの排他制御',
            '分散システムでのリーダー選出'
          ],
          advantages: %w[
            柔軟なロック対象を指定できる
            テーブルロックよりもきめ細かい制御が可能
          ],
          disadvantages: [
            'PostgreSQL固有の機能（他DBMSでは異なる実装が必要）',
            'ロック解放忘れのリスク'
          ],
          implementation: "ActiveRecord::Base.connection.execute('SELECT pg_advisory_lock(key)')"
        }
      }
    end

    # 実務シナリオ別のロック推奨を示す
    def self.demonstrate_practical_scenarios
      {
        ecommerce_stock: {
          scenario: 'ECサイトの在庫管理',
          recommendation: '悲観的ロック or アトミックSQL',
          reason: '在庫数の正確性が重要で、同時購入が頻繁に発生する'
        },
        user_profile_edit: {
          scenario: 'ユーザープロフィール編集',
          recommendation: '楽観的ロック',
          reason: '同一ユーザーの同時編集は稀で、競合時はユーザーに再試行を促せる'
        },
        bank_transfer: {
          scenario: '銀行口座間送金',
          recommendation: '悲観的ロック + ロック順序固定',
          reason: '金額の正確性が最重要で、デッドロック防止も必要'
        },
        page_view_counter: {
          scenario: 'ページビューカウンター',
          recommendation: 'アトミックSQL（update_counters）',
          reason: 'シンプルなインクリメントで、厳密な正確性は不要'
        },
        batch_job: {
          scenario: 'バッチ処理の二重実行防止',
          recommendation: 'アドバイザリーロック',
          reason: 'レコードではなくプロセスレベルの排他制御が必要'
        }
      }
    end
  end
end
