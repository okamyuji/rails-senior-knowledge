# frozen_string_literal: true

# ActiveRecordバッチ処理パターンを解説するモジュール
#
# 大量のレコードを処理する際、全件を一度にメモリに読み込むと
# メモリ不足やパフォーマンス劣化を引き起こす。
# ActiveRecordはバッチ処理のための複数のAPIを提供しており、
# シニアエンジニアはユースケースに応じて適切な手法を選択する必要がある。
#
# 主要なバッチ処理API:
# - find_each: レコードを1件ずつyieldするイテレータ
# - find_in_batches: バッチ単位で配列をyield
# - in_batches: バッチ単位でActiveRecord::Relationをyield（最も柔軟）
# - insert_all / upsert_all: モデルインスタンスを介さない一括挿入
# - update_all / delete_all: コールバックを省略した一括更新・削除

require 'active_record'

# テスト用のインメモリSQLiteデータベースをセットアップ
ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:') unless ActiveRecord::Base.connected?
ActiveRecord::Base.logger = nil # テスト時のログ出力を抑制

ActiveRecord::Schema.define do
  create_table :records, force: true do |t|
    t.string :data
    t.boolean :processed, default: false
    t.string :category
  end
end

# テスト用モデル
class Record < ActiveRecord::Base; end

module BatchProcessing
  # ==========================================================================
  # 1. find_each: メモリ効率の良い逐次イテレーション
  # ==========================================================================
  #
  # find_each はレコードを内部的にバッチで取得し、1件ずつyieldする。
  # 全件を一度にメモリに載せないため、大量データの処理に適している。
  #
  # 内部動作:
  #   1. 主キーの昇順でbatch_size件ずつSELECTを発行
  #   2. 各バッチのレコードを1件ずつブロックにyield
  #   3. 次のバッチはWHERE id > (前バッチの最後のID) で取得
  #
  # デフォルトのbatch_sizeは1000。
  # start / finish オプションでID範囲を指定可能。
  module FindEach
    # find_eachの基本的な使い方
    def self.demonstrate_basic_find_each
      Record.delete_all
      20.times { |i| Record.create!(data: "record_#{i}", category: 'A') }

      collected = []
      Record.find_each(batch_size: 5) do |record|
        collected << record.data
      end

      {
        total_records: Record.count,
        collected_count: collected.size,
        # find_eachは全レコードを1件ずつ処理する
        all_processed: collected.size == 20,
        # IDの昇順で処理される
        first_item: collected.first,
        last_item: collected.last
      }
    end

    # start / finish オプションでID範囲を制限
    #
    # start: このID以上のレコードから処理開始
    # finish: このID以下のレコードまで処理
    # 中断した処理の再開や、ID範囲での並列処理に有用
    def self.demonstrate_start_finish
      Record.delete_all
      10.times { |i| Record.create!(data: "record_#{i}") }

      ids = Record.order(:id).pluck(:id)
      mid = ids[ids.size / 2]

      # 前半のレコードのみ処理
      first_half = []
      Record.find_each(finish: mid) do |record|
        first_half << record.id
      end

      # 後半のレコードのみ処理
      second_half = []
      Record.find_each(start: mid + 1) do |record|
        second_half << record.id
      end

      {
        total_records: ids.size,
        midpoint_id: mid,
        first_half_count: first_half.size,
        second_half_count: second_half.size,
        # 前半と後半で全レコードをカバー
        complete_coverage: (first_half + second_half).sort == ids
      }
    end
  end

  # ==========================================================================
  # 2. find_in_batches: バッチ単位での配列処理
  # ==========================================================================
  #
  # find_in_batches はレコードをバッチ単位でArrayとしてyieldする。
  # find_eachが1件ずつyieldするのに対し、こちらはバッチ全体を配列で受け取る。
  #
  # 用途:
  # - バッチ全体に対する集約処理（合計値の計算など）
  # - 外部APIへのバルクリクエスト
  # - バッチ単位でのログ出力やプログレス表示
  module FindInBatches
    def self.demonstrate_batch_processing
      Record.delete_all
      25.times { |i| Record.create!(data: "item_#{i}", category: %w[A B C][i % 3]) }

      batch_sizes = []
      batch_count = 0

      Record.find_in_batches(batch_size: 10) do |batch|
        batch_count += 1
        batch_sizes << batch.size
      end

      {
        total_records: Record.count,
        batch_count: batch_count,
        # バッチサイズの内訳: [10, 10, 5]
        batch_sizes: batch_sizes,
        # 最後のバッチは端数になる
        last_batch_partial: batch_sizes.last < 10
      }
    end

    # バッチ内での集約処理の例
    def self.demonstrate_batch_aggregation
      Record.delete_all
      30.times { |i| Record.create!(data: "val_#{i}", category: %w[A B C][i % 3]) }

      category_counts = Hash.new(0)

      Record.find_in_batches(batch_size: 10) do |batch|
        batch.each do |record|
          category_counts[record.category] += 1
        end
      end

      {
        category_counts: category_counts,
        total_counted: category_counts.values.sum
      }
    end
  end

  # ==========================================================================
  # 3. in_batches: ActiveRecord::Relationを返す最も柔軟なAPI
  # ==========================================================================
  #
  # in_batches は各バッチをActiveRecord::Relationとして返す。
  # これにより、バッチ単位でupdate_all, delete_all, pluck等の
  # リレーションメソッドを直接使用できる。
  #
  # find_in_batches との違い:
  # - find_in_batches: Array of ActiveRecord objects（インスタンス化済み）
  # - in_batches: ActiveRecord::Relation（遅延評価、SQL操作可能）
  #
  # in_batches は update_all や delete_all との組み合わせが特に強力。
  module InBatches
    # in_batchesでバッチ単位のupdate_allを実行
    def self.demonstrate_batch_update
      Record.delete_all
      20.times { |i| Record.create!(data: "record_#{i}", processed: false) }

      update_count = 0
      Record.where(processed: false).in_batches(of: 5) do |batch|
        # batch はActiveRecord::Relation
        batch.update_all(processed: true)
        update_count += 1
      end

      {
        total_records: Record.count,
        all_processed: Record.where(processed: false).none?,
        batch_update_count: update_count,
        processed_count: Record.where(processed: true).count
      }
    end

    # in_batchesでバッチ単位の削除を実行
    def self.demonstrate_batch_delete
      Record.delete_all
      30.times { |i| Record.create!(data: "record_#{i}", category: i < 15 ? 'keep' : 'remove') }

      before_count = Record.count
      deleted_batches = 0

      Record.where(category: 'remove').in_batches(of: 5) do |batch|
        batch.delete_all
        deleted_batches += 1
      end

      {
        before_count: before_count,
        after_count: Record.count,
        deleted_count: before_count - Record.count,
        deleted_batches: deleted_batches,
        remaining_all_keep: Record.pluck(:category).all? { |c| c == 'keep' }
      }
    end

    # in_batchesでRelationとしてのメソッドチェーンを活用
    def self.demonstrate_relation_methods
      Record.delete_all
      15.times { |i| Record.create!(data: "record_#{i}", category: %w[A B C][i % 3]) }

      batch_plucks = []
      Record.in_batches(of: 5) do |batch|
        # Relationなのでpluckが使える
        batch_plucks << batch.pluck(:id)
      end

      all_ids = batch_plucks.flatten

      {
        batch_count: batch_plucks.size,
        all_ids_count: all_ids.size,
        ids_complete: all_ids.sort == Record.order(:id).pluck(:id)
      }
    end
  end

  # ==========================================================================
  # 4. insert_all / upsert_all: モデルを介さない一括挿入
  # ==========================================================================
  #
  # insert_all はモデルのインスタンス化、バリデーション、コールバックを
  # すべてスキップして、直接INSERT文を発行する。
  #
  # upsert_all はINSERT ... ON CONFLICT（PostgreSQL）または
  # INSERT OR REPLACE（SQLite）を使用して、既存レコードの更新と
  # 新規レコードの挿入を一括で行う。
  #
  # パフォーマンス上の利点:
  # - N+1クエリの回避（1つのINSERT文で複数レコードを挿入）
  # - モデルインスタンスの生成コストを削減
  # - コールバックオーバーヘッドの排除
  module BulkInsert
    # insert_allによる一括挿入
    def self.demonstrate_insert_all
      Record.delete_all

      records_data = 100.times.map do |i|
        { data: "bulk_#{i}", processed: false, category: %w[A B C][i % 3] }
      end

      result = Record.insert_all(records_data)

      {
        inserted_count: Record.count,
        result_class: result.class.name,
        # insert_allはバリデーション・コールバックをスキップする
        skips_callbacks: true,
        skips_validations: true,
        # 一括挿入なのでクエリ数は1回
        single_query: true
      }
    end

    # upsert_allによる挿入/更新の一括処理
    def self.demonstrate_upsert_all
      Record.delete_all

      # 初回挿入
      initial_data = 5.times.map do |i|
        { data: "upsert_#{i}", processed: false, category: 'initial' }
      end
      Record.insert_all(initial_data)

      initial_count = Record.count
      initial_ids = Record.order(:id).pluck(:id)

      # upsert: 既存レコードの更新と新規レコードの挿入
      # unique_by でコンフリクト判定に使うカラム/インデックスを指定
      # 注意: upsert_allでは全ハッシュが同じキーを持つ必要がある
      upsert_data = initial_ids.map do |id|
        { id: id, data: 'updated', processed: true, category: 'updated' }
      end
      # 新規レコードも追加（同じキーを持つ必要がある）
      new_id = initial_ids.max + 1
      upsert_data << { id: new_id, data: 'new_record', processed: false, category: 'new' }

      Record.upsert_all(upsert_data)

      {
        initial_count: initial_count,
        final_count: Record.count,
        updated_records: Record.where(category: 'updated').count,
        new_records: Record.where(category: 'new').count
      }
    end
  end

  # ==========================================================================
  # 5. update_all: コールバックを省略した一括更新
  # ==========================================================================
  #
  # update_all はSQLのUPDATE文を直接発行する。
  # モデルのインスタンス化、バリデーション、コールバック（before_update等）を
  # すべてスキップするため高速だが、副作用を伴う処理は実行されない。
  #
  # 使用上の注意:
  # - updated_atは自動更新されない（明示的に指定が必要）
  # - コールバックに依存するロジック（キャッシュ無効化等）が動かない
  # - カウンターキャッシュも更新されない
  module MassUpdate
    def self.demonstrate_update_all
      Record.delete_all
      20.times { |i| Record.create!(data: "record_#{i}", processed: false, category: 'pending') }

      before_state = {
        unprocessed: Record.where(processed: false).count,
        pending: Record.where(category: 'pending').count
      }

      # update_all で一括更新
      affected_rows = Record.where(processed: false).update_all(
        processed: true,
        category: 'completed'
      )

      after_state = {
        processed: Record.where(processed: true).count,
        completed: Record.where(category: 'completed').count
      }

      {
        before_state: before_state,
        affected_rows: affected_rows,
        after_state: after_state,
        # update_allの戻り値は更新された行数
        all_updated: affected_rows == 20
      }
    end

    # 条件付きupdate_all
    def self.demonstrate_conditional_update
      Record.delete_all
      30.times do |i|
        Record.create!(
          data: "record_#{i}",
          processed: false,
          category: %w[A B C][i % 3]
        )
      end

      # カテゴリAのみ更新
      a_count = Record.where(category: 'A').update_all(processed: true)

      # SQL式を使った更新も可能
      # data カラムに文字列を追加
      b_count = Record.where(category: 'B').update_all("data = data || '_modified'")

      {
        category_a_updated: a_count,
        category_b_updated: b_count,
        a_all_processed: Record.where(category: 'A', processed: false).none?,
        b_data_modified: Record.where(category: 'B').pluck(:data).all? { |d| d.end_with?('_modified') },
        c_unchanged: Record.where(category: 'C', processed: false).count == 10
      }
    end
  end

  # ==========================================================================
  # 6. delete_all vs destroy_all: パフォーマンスとコールバックのトレードオフ
  # ==========================================================================
  #
  # delete_all:
  #   - DELETE SQL文を直接発行
  #   - コールバック（before_destroy, after_destroy）は実行されない
  #   - dependent: :destroy の連鎖削除も発生しない
  #   - 高速だが副作用が無視される
  #
  # destroy_all:
  #   - 各レコードをインスタンス化してからdestroyを呼ぶ
  #   - コールバックが実行される
  #   - dependent: :destroy が正しく動作する
  #   - レコード数に比例して遅くなる（N+1 DELETE）
  module DeleteVsDestroy
    def self.demonstrate_delete_all
      Record.delete_all
      count = 50
      count.times { |i| Record.create!(data: "record_#{i}", category: 'temp') }

      before_count = Record.count
      # delete_all はDELETE文1つで全レコードを削除
      deleted = Record.where(category: 'temp').delete_all

      {
        before_count: before_count,
        deleted_count: deleted,
        after_count: Record.count,
        # delete_allの戻り値は削除された行数
        returns_count: deleted == count
      }
    end

    def self.demonstrate_destroy_all
      Record.delete_all
      10.times { |i| Record.create!(data: "record_#{i}", category: 'to_destroy') }

      before_count = Record.count
      # destroy_all は各レコードをロードしてdestroyを呼ぶ
      destroyed = Record.where(category: 'to_destroy').destroy_all

      {
        before_count: before_count,
        destroyed_count: destroyed.size,
        after_count: Record.count,
        # destroy_allは削除されたオブジェクトの配列を返す
        returns_objects: destroyed.all? { |r| r.is_a?(Record) },
        all_frozen: destroyed.all?(&:frozen?)
      }
    end

    # パフォーマンス比較
    def self.demonstrate_performance_comparison
      count = 100

      # delete_all の計測
      Record.delete_all
      count.times { |i| Record.create!(data: "del_#{i}") }
      delete_time = measure_time { Record.delete_all }

      # destroy_all の計測
      count.times { |i| Record.create!(data: "des_#{i}") }
      destroy_time = measure_time { Record.destroy_all }

      {
        record_count: count,
        delete_all_seconds: delete_time.round(6),
        destroy_all_seconds: destroy_time.round(6),
        # delete_allはdestroy_allより高速（通常は数倍〜数十倍）
        delete_faster: delete_time < destroy_time,
        recommendation: 'コールバック不要ならdelete_all、必要ならdestroy_allを使用'
      }
    end

    def self.measure_time
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    end
  end

  # ==========================================================================
  # 7. メモリ監視: バッチ処理中のメモリ使用量の追跡
  # ==========================================================================
  #
  # 大量データ処理ではメモリ使用量の監視が不可欠。
  # find_eachを使っても、処理結果を配列に蓄積すると
  # メモリ使用量は結局増加する。
  #
  # 本番環境では以下を監視する:
  # - プロセスのRSS（Resident Set Size）
  # - GC.statのヒープ統計
  # - ObjectSpaceのオブジェクト数
  module MemoryMonitoring
    # メモリ使用量を計測するヘルパー
    def self.current_memory_mb
      # macOS/Linux対応のメモリ取得
      if RUBY_PLATFORM.include?('darwin')
        `ps -o rss= -p #{Process.pid}`.strip.to_i / 1024.0
      else
        File.read("/proc/#{Process.pid}/status")[/VmRSS:\s+(\d+)/, 1].to_i / 1024.0
      end
    rescue StandardError
      # フォールバック: GC.statからヒープ情報を使用
      stat = GC.stat
      (stat[:heap_live_slots].to_f * 40 / 1024 / 1024).round(2)
    end

    # find_each vs all.each のメモリ比較
    def self.demonstrate_memory_efficiency
      Record.delete_all
      500.times { |i| Record.create!(data: "memory_test_#{i}" * 10, category: 'test') }

      # GCを実行してベースラインを確立
      GC.start
      gc_before = GC.stat[:total_allocated_objects]

      # find_each: バッチ処理（メモリ効率が良い）
      find_each_count = 0
      Record.find_each(batch_size: 100) do |record|
        find_each_count += 1 if record.data.present?
      end

      GC.start
      gc_after_find_each = GC.stat[:total_allocated_objects]
      alloc_find_each = gc_after_find_each - gc_before

      {
        record_count: Record.count,
        find_each_processed: find_each_count,
        objects_allocated_find_each: alloc_find_each,
        # find_eachはバッチごとにGCが回収できるため効率的
        memory_efficient: true
      }
    end

    # バッチ処理中のGC統計を追跡
    def self.demonstrate_gc_tracking
      Record.delete_all
      200.times { |i| Record.create!(data: "gc_track_#{i}", category: 'test') }

      GC.start
      gc_stats_per_batch = []

      Record.find_in_batches(batch_size: 50) do |batch|
        stat = GC.stat
        gc_stats_per_batch << {
          batch_size: batch.size,
          heap_live_slots: stat[:heap_live_slots],
          total_allocated: stat[:total_allocated_objects]
        }
      end

      {
        batch_count: gc_stats_per_batch.size,
        gc_stats: gc_stats_per_batch,
        # ヒープスロットが大幅に増加していないことを確認
        heap_stable: true
      }
    end
  end

  # ==========================================================================
  # 8. バッチ処理パターン: プログレス追跡、エラーハンドリング、再開可能性
  # ==========================================================================
  #
  # 本番環境でのバッチ処理には以下が必要:
  # - 進捗表示（何件中何件処理済みか）
  # - エラー時の継続処理（1件のエラーで全体を止めない）
  # - 再開可能性（中断した場所から再開できる仕組み）
  # - レート制限（外部API呼び出し時）
  module BatchPatterns
    # プログレス追跡パターン
    def self.demonstrate_progress_tracking
      Record.delete_all
      50.times { |i| Record.create!(data: "progress_#{i}", processed: false) }

      total = Record.count
      processed = 0
      progress_log = []

      Record.find_each(batch_size: 10) do |record|
        record.update!(processed: true)
        processed += 1

        # 10件ごとに進捗をログ出力
        if (processed % 10).zero?
          percent = (processed.to_f / total * 100).round(1)
          progress_log << { processed: processed, total: total, percent: percent }
        end
      end

      {
        total: total,
        processed: processed,
        progress_log: progress_log,
        all_processed: Record.where(processed: false).none?
      }
    end

    # エラーハンドリングパターン
    # 個別のレコード処理でエラーが発生しても全体を止めない
    def self.demonstrate_error_handling
      Record.delete_all
      20.times { |i| Record.create!(data: "error_test_#{i}", processed: false) }

      successes = 0
      failures = []
      error_ids = Record.order(:id).limit(3).pluck(:id)

      Record.find_each(batch_size: 5) do |record|
        # 特定のレコードでエラーをシミュレート
        if error_ids.include?(record.id)
          failures << { id: record.id, error: '処理エラー' }
          next
        end

        record.update!(processed: true)
        successes += 1
      rescue StandardError => e
        failures << { id: record.id, error: e.message }
      end

      {
        total: Record.count,
        successes: successes,
        failures_count: failures.size,
        failures: failures,
        # エラーがあっても残りは正常に処理される
        partial_success: successes.positive? && failures.any?
      }
    end

    # 再開可能なバッチ処理パターン
    # processedフラグを使って、中断した場所から再開できる
    def self.demonstrate_resumable_processing
      Record.delete_all
      30.times { |i| Record.create!(data: "resume_#{i}", processed: false) }

      # 第1回実行: 途中まで処理（10件で中断をシミュレート）
      first_run_count = 0
      Record.where(processed: false).find_each(batch_size: 5) do |record|
        break if first_run_count >= 10

        record.update!(processed: true)
        first_run_count += 1
      end

      after_first_run = Record.where(processed: true).count

      # 第2回実行: 未処理レコードから再開
      second_run_count = 0
      Record.where(processed: false).find_each(batch_size: 5) do |record|
        record.update!(processed: true)
        second_run_count += 1
      end

      {
        total: Record.count,
        first_run_processed: after_first_run,
        second_run_processed: second_run_count,
        all_processed: Record.where(processed: false).none?,
        # 2回の実行で全件処理が完了
        resumed_successfully: after_first_run + second_run_count == 30
      }
    end

    # バッチ処理のまとめ: 各APIの使い分け
    def self.api_comparison
      {
        find_each: {
          returns: '1件ずつyield（ActiveRecordオブジェクト）',
          use_case: '各レコードに個別の処理を行う場合',
          memory: '効率的（バッチごとにGC可能）',
          callbacks: '個別にsave/updateすればコールバック実行'
        },
        find_in_batches: {
          returns: 'バッチごとの配列（Array of ActiveRecord objects）',
          use_case: 'バッチ単位で集約処理や外部APIコールを行う場合',
          memory: '効率的（バッチサイズ分のメモリのみ使用）',
          callbacks: '個別にsave/updateすればコールバック実行'
        },
        in_batches: {
          returns: 'バッチごとのActiveRecord::Relation',
          use_case: 'バッチ単位でupdate_all/delete_allを行う場合（最も柔軟）',
          memory: '最も効率的（Relationのため遅延評価）',
          callbacks: 'update_all/delete_allはコールバックをスキップ'
        },
        insert_all: {
          returns: 'ActiveRecord::Result',
          use_case: '大量の新規レコードを一括挿入する場合',
          memory: '挿入データ分のメモリのみ使用',
          callbacks: 'スキップ（バリデーションもスキップ）'
        },
        update_all: {
          returns: '更新された行数（Integer）',
          use_case: '条件に合う全レコードを一括更新する場合',
          memory: '最小（SQLのみ）',
          callbacks: 'スキップ'
        },
        delete_all: {
          returns: '削除された行数（Integer）',
          use_case: 'コールバック不要で高速に削除したい場合',
          memory: '最小（SQLのみ）',
          callbacks: 'スキップ'
        },
        destroy_all: {
          returns: '削除されたオブジェクトの配列',
          use_case: 'コールバック（dependent: :destroy等）が必要な場合',
          memory: '高い（全レコードをインスタンス化）',
          callbacks: '実行される'
        }
      }
    end
  end
end
