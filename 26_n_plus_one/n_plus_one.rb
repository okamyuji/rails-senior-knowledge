# frozen_string_literal: true

# N+1クエリ問題の検出とStrict Loadingによる防止策を解説するモジュール
#
# N+1問題はRailsアプリケーションで最も一般的なパフォーマンス劣化の原因である。
# 関連レコードをループ内で1件ずつ取得することで、データ量に比例して
# クエリ数が増大し、レスポンスタイムが悪化する。
#
# このモジュールでは、シニアRailsエンジニアが知るべきN+1問題の仕組み、
# 各種Eager Loading戦略、Strict Loadingによる防止、
# バッチ処理パターンを実例を通じて学ぶ。

require 'active_record'
require 'active_support/notifications'

# --- インメモリSQLiteデータベースのセットアップ ---
ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:') unless ActiveRecord::Base.connected?
ActiveRecord::Base.logger = nil # テスト時のログ出力を抑制

ActiveRecord::Schema.define do
  create_table :npo_authors, force: true do |t|
    t.string :name
    t.timestamps null: false
  end

  create_table :npo_books, force: true do |t|
    t.string :title
    t.references :npo_author, foreign_key: false
    t.timestamps null: false
  end

  create_table :npo_reviews, force: true do |t|
    t.text :body
    t.integer :rating
    t.references :npo_book, foreign_key: false
    t.timestamps null: false
  end
end

# --- モデル定義 ---
class Author < ActiveRecord::Base
  self.table_name = 'npo_authors'
  has_many :books, foreign_key: 'npo_author_id'
end

class Book < ActiveRecord::Base
  self.table_name = 'npo_books'
  belongs_to :author, foreign_key: 'npo_author_id'
  has_many :reviews, foreign_key: 'npo_book_id'
end

class Review < ActiveRecord::Base
  self.table_name = 'npo_reviews'
  belongs_to :book, foreign_key: 'npo_book_id'
end

module NPlusOneDetection
  module_function

  # ==========================================================================
  # ヘルパー: SQLクエリカウンター
  # ==========================================================================
  #
  # ActiveSupport::Notifications の "sql.active_record" イベントを購読し、
  # ブロック内で発行されたSQLクエリの数をカウントする。
  # SCHEMA クエリやトランザクション制御文は除外する。
  #
  # Bullet gem などのN+1検出ツールも内部的に同じ仕組みを使っている。
  def count_queries(&)
    count = 0
    counter = lambda do |_name, _start, _finish, _id, payload|
      # SCHEMA クエリ（テーブル作成等）とトランザクション制御は除外
      unless payload[:name] == 'SCHEMA' || payload[:sql].match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)
        count += 1
      end
    end

    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
    count
  end

  # ==========================================================================
  # テストデータの準備
  # ==========================================================================
  #
  # 各デモンストレーションメソッドで使用するテストデータを準備する。
  # 3人の著者、各著者に2冊の本、各本に2件のレビューを作成する。
  def setup_test_data
    Author.delete_all
    Book.delete_all
    Review.delete_all

    authors = 3.times.map do |i|
      Author.create!(name: "著者#{i + 1}")
    end

    authors.each do |author|
      2.times do |j|
        book = Book.create!(title: "#{author.name}の本#{j + 1}", author: author)
        2.times do |k|
          Review.create!(body: "レビュー#{k + 1}", rating: (k + 3), book: book)
        end
      end
    end

    { authors: authors.size, books: Book.count, reviews: Review.count }
  end

  # ==========================================================================
  # 1. N+1問題のデモンストレーション: 遅延ロードとEager Loadingの比較
  # ==========================================================================
  #
  # N+1問題の本質:
  #   - 1回のクエリで親レコード（N件）を取得
  #   - ループ内で各親レコードの関連を参照するたびに追加クエリが発行される（N回）
  #   - 合計 N+1 回のクエリが実行される
  #
  # 例: 著者3人 × 本2冊の場合
  #   遅延ロード: 1（著者取得）+ 3（各著者の本を取得）= 4クエリ
  #   Eager Loading: 1（著者取得）+ 1（本を一括取得）= 2クエリ
  def demonstrate_n_plus_one_problem
    setup_test_data

    # --- N+1パターン（遅延ロード）---
    # Author.all で著者を取得した後、author.books でループごとにクエリが発行される
    lazy_queries = count_queries do
      Author.all.each do |author|
        author.books.to_a
      end
    end

    # --- Eager Loadingパターン ---
    # includes を使うと関連レコードを事前に一括取得する
    eager_queries = count_queries do
      Author.includes(:books).each do |author|
        author.books.to_a
      end
    end

    {
      lazy_query_count: lazy_queries,
      eager_query_count: eager_queries,
      query_reduction: lazy_queries - eager_queries,
      # N+1の計算式: 1（親取得）+ N（各親の子を個別取得）
      n_plus_one_formula: "1 + N = 1 + #{Author.count} = #{1 + Author.count}"
    }
  end

  # ==========================================================================
  # 2. includes vs preload vs eager_load の使い分け
  # ==========================================================================
  #
  # ActiveRecordは3つのEager Loading戦略を提供する:
  #
  # ■ includes（推奨・デフォルト）
  #   - 状況に応じてpreloadまたはeager_loadを自動選択する
  #   - WHERE句で関連テーブルを参照しない場合 → preload（別クエリ）
  #   - WHERE句で関連テーブルを参照する場合 → eager_load（LEFT OUTER JOIN）
  #
  # ■ preload（別クエリ戦略）
  #   - 関連レコードを別のSELECTクエリで取得する
  #   - SELECT * FROM authors; SELECT * FROM books WHERE author_id IN (1,2,3);
  #   - メリット: 各テーブルのインデックスを最大限活用できる
  #   - デメリット: WHERE句で関連テーブルのカラムを参照できない
  #
  # ■ eager_load（LEFT OUTER JOIN戦略）
  #   - LEFT OUTER JOINで1つのクエリにまとめる
  #   - SELECT * FROM authors LEFT OUTER JOIN books ON ...
  #   - メリット: WHERE句で関連テーブルのカラムを参照できる
  #   - デメリット: JOINによるデータ膨張（カーテシアン積の問題）
  def demonstrate_loading_strategies
    setup_test_data

    # --- preload: 別クエリ戦略 ---
    preload_queries = []
    preload_count = count_queries do
      subscriber = lambda do |_name, _start, _finish, _id, payload|
        unless payload[:name] == 'SCHEMA' || payload[:sql].match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)
          preload_queries << payload[:sql]
        end
      end
      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
        Author.preload(:books).to_a
      end
    end

    # --- eager_load: LEFT OUTER JOIN戦略 ---
    eager_load_queries = []
    eager_load_count = count_queries do
      subscriber = lambda do |_name, _start, _finish, _id, payload|
        unless payload[:name] == 'SCHEMA' || payload[:sql].match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)
          eager_load_queries << payload[:sql]
        end
      end
      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
        Author.eager_load(:books).to_a
      end
    end

    # --- includes: 自動選択 ---
    # WHERE句で関連テーブルを参照しない場合 → preloadと同じ挙動
    includes_simple_queries = []
    includes_simple_count = count_queries do
      subscriber = lambda do |_name, _start, _finish, _id, payload|
        unless payload[:name] == 'SCHEMA' || payload[:sql].match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)
          includes_simple_queries << payload[:sql]
        end
      end
      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
        Author.includes(:books).to_a
      end
    end

    # --- includes + references: WHERE句で関連テーブルを参照する場合 → eager_loadと同じ挙動 ---
    includes_ref_queries = []
    includes_ref_count = count_queries do
      subscriber = lambda do |_name, _start, _finish, _id, payload|
        unless payload[:name] == 'SCHEMA' || payload[:sql].match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)
          includes_ref_queries << payload[:sql]
        end
      end
      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
        Author.includes(:books).where(npo_books: { title: '著者1の本1' }).references(:books).to_a
      end
    end

    {
      preload_query_count: preload_count,
      preload_uses_separate_queries: preload_queries.size >= 2,
      preload_has_in_clause: preload_queries.any? { |q| q.include?('IN') },
      eager_load_query_count: eager_load_count,
      eager_load_uses_join: eager_load_queries.any? { |q| q.include?('LEFT OUTER JOIN') },
      includes_simple_count: includes_simple_count,
      includes_ref_count: includes_ref_count,
      includes_ref_uses_join: includes_ref_queries.any? { |q| q.include?('LEFT OUTER JOIN') }
    }
  end

  # ==========================================================================
  # 3. ネストした関連のEager Loading
  # ==========================================================================
  #
  # N+1問題は多段階の関連で深刻化する。
  # 例: Author → Books → Reviews の3階層で、
  #   遅延ロード: 1 + N + N*M クエリ（著者N人、各著者M冊の本）
  #   Eager Loading: 最大3クエリ（各テーブルにつき1クエリ）
  #
  # includes にはハッシュ構文でネストした関連を指定できる。
  def demonstrate_nested_eager_loading
    setup_test_data

    # --- ネストしたN+1問題 ---
    lazy_nested_count = count_queries do
      Author.all.each do |author|
        author.books.each do |book|
          book.reviews.to_a
        end
      end
    end

    # --- ネストしたEager Loading ---
    eager_nested_count = count_queries do
      Author.includes(books: :reviews).each do |author|
        author.books.each do |book|
          book.reviews.to_a
        end
      end
    end

    # ロードされたデータの確認
    authors = Author.includes(books: :reviews).to_a
    total_reviews = authors.sum { |a| a.books.sum { |b| b.reviews.size } }

    {
      lazy_nested_query_count: lazy_nested_count,
      eager_nested_query_count: eager_nested_count,
      query_reduction: lazy_nested_count - eager_nested_count,
      total_reviews_loaded: total_reviews,
      # 3テーブル分のクエリ: authors + books + reviews
      expected_eager_queries: 3
    }
  end

  # ==========================================================================
  # 4. strict_loading: N+1問題の防止メカニズム
  # ==========================================================================
  #
  # Rails 6.1で導入されたstrict_loadingは、遅延ロードを明示的に禁止する仕組み。
  # Eager Loadingされていない関連にアクセスすると例外が発生する。
  #
  # 設定レベル:
  #   1. モデルレベル: self.strict_loading_by_default = true
  #   2. 関連レベル: has_many :books, strict_loading: true
  #   3. インスタンスレベル: author.strict_loading!
  #   4. スコープレベル: Author.strict_loading.all
  #
  # 開発環境でN+1を早期発見するために非常に有効。
  def demonstrate_strict_loading
    setup_test_data

    # --- スコープレベルのstrict_loading ---
    # strict_loadingスコープで取得したレコードの関連にアクセスすると例外
    scope_error = nil
    begin
      author = Author.strict_loading.first
      author.books.to_a
    rescue ActiveRecord::StrictLoadingViolationError => e
      scope_error = e.message
    end

    # --- インスタンスレベルのstrict_loading! ---
    instance_error = nil
    begin
      author = Author.first
      author.strict_loading!
      author.books.to_a
    rescue ActiveRecord::StrictLoadingViolationError => e
      instance_error = e.message
    end

    # --- strict_loadingとincludes の組み合わせ ---
    # Eager Loadingされた関連はstrict_loadingでもアクセスできる
    no_error = nil
    loaded_books_count = 0
    begin
      author = Author.strict_loading.includes(:books).first
      loaded_books_count = author.books.size
      no_error = true
    rescue ActiveRecord::StrictLoadingViolationError
      no_error = false
    end

    {
      scope_strict_loading_error: scope_error,
      instance_strict_loading_error: instance_error,
      scope_error_raised: !scope_error.nil?,
      instance_error_raised: !instance_error.nil?,
      eager_loaded_no_error: no_error,
      eager_loaded_books_count: loaded_books_count
    }
  end

  # ==========================================================================
  # 5. 関連レベルのstrict_loading
  # ==========================================================================
  #
  # 特定の関連だけにstrict_loadingを適用できる。
  # パフォーマンスクリティカルな関連（大量のレコードを持つ可能性がある関連）に対して
  # 個別にN+1を防止する場合に有効。
  def demonstrate_association_strict_loading
    setup_test_data

    # 関連レベルのstrict_loadingを持つモデルを動的に定義
    # 無名クラスではActiveRecordの内部でname.demodulizeが失敗するため、
    # 定数に代入してクラス名を付与する
    unless defined?(::StrictAuthor)
      Object.const_set(:StrictAuthor, Class.new(ActiveRecord::Base) do
        self.table_name = 'npo_authors'
        has_many :books, strict_loading: true, foreign_key: 'npo_author_id', class_name: 'Book'
      end)
    end

    # strict_loading が設定された関連にアクセスすると例外
    assoc_error = nil
    begin
      author = StrictAuthor.first
      author.books.to_a
    rescue ActiveRecord::StrictLoadingViolationError => e
      assoc_error = e.message
    end

    # preloadで事前読み込みすればアクセス可能
    preloaded_ok = nil
    preloaded_count = 0
    begin
      author = StrictAuthor.includes(:books).first
      preloaded_count = author.books.size
      preloaded_ok = true
    rescue ActiveRecord::StrictLoadingViolationError
      preloaded_ok = false
    end

    {
      association_strict_loading_error: assoc_error,
      association_error_raised: !assoc_error.nil?,
      preloaded_bypasses_strict: preloaded_ok,
      preloaded_count: preloaded_count
    }
  end

  # ==========================================================================
  # 6. クエリカウントパターンとN+1検出の仕組み
  # ==========================================================================
  #
  # Bullet gemなどのN+1検出ツールの内部的な仕組みを解説する。
  #
  # 検出の基本原理:
  #   1. ActiveSupport::Notifications で "sql.active_record" イベントを購読
  #   2. 発行されたクエリのパターンを分析
  #   3. 同じテーブルへの同一パターンのクエリが繰り返される場合にN+1と判定
  #
  # この仕組みを理解することで、カスタムN+1検出も実装できる。
  def demonstrate_query_counting_pattern
    setup_test_data

    # --- カスタムN+1検出器 ---
    # テーブルごとのクエリパターンを記録する簡易的な検出器
    query_patterns = Hash.new { |h, k| h[k] = [] }

    detector = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql]
      return if payload[:name] == 'SCHEMA'
      return if sql.match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)

      # テーブル名を抽出（FROM句またはJOIN句から）
      table_match = sql.match(/FROM\s+"?(\w+)"?/i)
      return unless table_match

      table = table_match[1]
      # パラメータ部分を正規化してパターン化
      normalized = sql.gsub(/= \$?\d+/, '= ?').gsub(/IN \([^)]+\)/, 'IN (...)')
      query_patterns[table] << normalized
    end

    # N+1が発生するコードを実行
    ActiveSupport::Notifications.subscribed(detector, 'sql.active_record') do
      Author.all.each do |author|
        author.books.to_a
      end
    end

    # N+1の判定: 同じテーブルに対して同一パターンのクエリが複数回発行されている
    potential_n_plus_one = query_patterns.select do |_table, queries|
      # 同一パターンが2回以上出現
      queries.group_by(&:itself).any? { |_pattern, occurrences| occurrences.size > 1 }
    end

    {
      total_tables_queried: query_patterns.keys.size,
      queries_per_table: query_patterns.transform_values(&:size),
      n_plus_one_detected: !potential_n_plus_one.empty?,
      detected_tables: potential_n_plus_one.keys,
      detection_mechanism: "ActiveSupport::Notifications 'sql.active_record' イベント購読"
    }
  end

  # ==========================================================================
  # 7. バッチ処理パターン: find_each / find_in_batches
  # ==========================================================================
  #
  # 大量のレコードを処理する場合、全件を一度にメモリに読み込むと
  # メモリ使用量が爆発的に増加する。
  #
  # find_each / find_in_batches はレコードをバッチ単位で取得・処理する。
  # デフォルトバッチサイズは1000件。
  #
  # 注意点:
  #   - ORDER BYは主キーの昇順に固定される（カスタムソートは不可）
  #   - includes と組み合わせてN+1を防止しつつバッチ処理できる
  #   - in_batches はRelationを返すため、update_allやdelete_allと組み合わせやすい
  def demonstrate_batch_loading
    setup_test_data

    # --- find_each: レコードを1件ずつ処理（内部的にバッチ取得）---
    find_each_results = []
    find_each_query_count = count_queries do
      # batch_size を小さくしてバッチ処理の動作を確認
      Author.find_each(batch_size: 2) do |author|
        find_each_results << author.name
      end
    end

    # --- find_in_batches: バッチ単位で配列として処理 ---
    batch_sizes = []
    find_in_batches_query_count = count_queries do
      Author.find_in_batches(batch_size: 2) do |batch|
        batch_sizes << batch.size
      end
    end

    # --- in_batches: Relationを返す（update_all等と組み合わせ可能）---
    in_batches_count = 0
    count_queries do
      Author.in_batches(of: 2) do |relation|
        in_batches_count += relation.count
      end
    end

    # --- find_each + includes: バッチ処理とEager Loadingの組み合わせ ---
    batch_eager_results = []
    batch_eager_query_count = count_queries do
      Author.includes(:books).find_each(batch_size: 2) do |author|
        batch_eager_results << { name: author.name, books: author.books.size }
      end
    end

    {
      find_each_results: find_each_results,
      find_each_query_count: find_each_query_count,
      batch_sizes: batch_sizes,
      find_in_batches_query_count: find_in_batches_query_count,
      in_batches_total: in_batches_count,
      batch_eager_results: batch_eager_results,
      batch_eager_query_count: batch_eager_query_count,
      batch_processing_note: 'find_each/find_in_batches はORDER BY主キー固定、カスタムソート不可'
    }
  end

  # ==========================================================================
  # 8. 実践的なN+1対策パターン集
  # ==========================================================================
  #
  # 実務でよく遭遇するN+1パターンとその解決策をまとめる。
  #
  # ■ counter_cache: COUNT クエリのN+1を防止
  # ■ size vs count vs length: ロード状態に応じた使い分け
  # ■ 条件付きプリロードでの注意点
  def demonstrate_practical_patterns
    setup_test_data

    # --- size vs count vs length の違い ---
    # size: ロード済みならlength、未ロードならCOUNTクエリ
    # count: 常にCOUNTクエリを発行
    # length: 常に全件ロードしてRuby側でカウント

    # length はロードを伴う
    length_queries = count_queries do
      author = Author.first
      author.books.length
    end

    # count は常にCOUNTクエリ
    count_queries_num = count_queries do
      author = Author.first
      author.books.count
    end

    # size はロード状態に応じて振る舞いが変わる
    # 未ロード時: COUNTクエリ
    size_unloaded = count_queries do
      author = Author.first
      author.books.size
    end

    # ロード済み時: メモリ上のサイズを返す（追加クエリなし）
    size_loaded = count_queries do
      author = Author.includes(:books).first
      author.books.size
    end

    # --- pluckによるN+1回避 ---
    # 関連オブジェクト全体ではなく、必要なカラムだけを取得
    pluck_queries = count_queries do
      Author.all.each do |author|
        author.books.pluck(:title)
      end
    end

    # JOINSとpluckで1クエリに最適化
    optimized_queries = count_queries do
      Book.joins(:author).pluck('npo_authors.name', 'npo_books.title')
    end

    {
      length_query_count: length_queries,
      count_query_count: count_queries_num,
      size_unloaded_query_count: size_unloaded,
      size_loaded_query_count: size_loaded,
      pluck_n_plus_one_count: pluck_queries,
      optimized_single_query_count: optimized_queries,
      size_recommendation: 'Eager Loading済みの場合はsizeが最適（追加クエリなし）'
    }
  end
end
