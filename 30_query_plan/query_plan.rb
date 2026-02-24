# frozen_string_literal: true

# EXPLAINとクエリプラン解析を解説するモジュール
#
# データベースのクエリ最適化において、EXPLAINはSQLがどのように実行されるかを
# 理解するための最も重要なツールである。クエリプランを読み解くことで、
# インデックスの有効活用、フルテーブルスキャンの回避、結合戦略の最適化が可能になる。
#
# このモジュールでは、シニアRailsエンジニアが知るべきクエリプラン解析の
# 手法とインデックス戦略を実例を通じて学ぶ。

require 'active_record'

# --- インメモリSQLiteデータベースのセットアップ ---
ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:') unless ActiveRecord::Base.connected?
ActiveRecord::Base.logger = nil # テスト時のログ出力を抑制

ActiveRecord::Schema.define do
  create_table :qp_products, force: true do |t|
    t.string :name
    t.decimal :price, precision: 10, scale: 2
    t.string :category
    t.boolean :active, default: true
    t.integer :stock_quantity, default: 0
    t.timestamps null: false
  end

  # 単一カラムインデックス: カテゴリによる絞り込みを高速化
  add_index :qp_products, :category

  # 複合インデックス: カテゴリ + 価格の範囲検索を最適化
  # 複合インデックスは左端のカラムから順に使われる（leftmost prefix rule）
  add_index :qp_products, %i[category price], name: 'index_products_on_category_and_price'

  # 価格単体のインデックス: 価格範囲検索用
  add_index :qp_products, :price

  create_table :qp_order_items, force: true do |t|
    t.references :qp_product, foreign_key: false
    t.integer :quantity
    t.decimal :unit_price, precision: 10, scale: 2
    t.timestamps null: false
  end

  create_table :qp_reviews, force: true do |t|
    t.references :qp_product, foreign_key: false
    t.integer :rating
    t.text :comment
    t.timestamps null: false
  end

  add_index :qp_reviews, %i[qp_product_id rating], name: 'index_qp_reviews_on_product_and_rating'
end

# --- モデル定義 ---
module QpModels
  class Product < ActiveRecord::Base
    self.table_name = 'qp_products'
    has_many :order_items, class_name: 'QpModels::OrderItem', foreign_key: 'qp_product_id'
    has_many :reviews, class_name: 'QpModels::Review', foreign_key: 'qp_product_id'
  end

  class OrderItem < ActiveRecord::Base
    self.table_name = 'qp_order_items'
    belongs_to :product, class_name: 'QpModels::Product', foreign_key: 'qp_product_id'
  end

  class Review < ActiveRecord::Base
    self.table_name = 'qp_reviews'
    belongs_to :product, class_name: 'QpModels::Product', foreign_key: 'qp_product_id'
  end
end

module QueryPlanAnalysis
  module_function

  # ==========================================================================
  # 1. EXPLAIN基礎: ActiveRecordでのEXPLAIN実行方法
  # ==========================================================================
  #
  # EXPLAINはSQLクエリの実行計画をデータベースに問い合わせるコマンドである。
  # ActiveRecordでは `.explain` メソッドを使用してクエリプランを取得できる。
  #
  # SQLiteのEXPLAIN QUERY PLANは以下の情報を提供する:
  #   - SCAN: テーブル全体を走査（フルテーブルスキャン）
  #   - SEARCH: インデックスを使用した検索
  #   - USING INDEX: どのインデックスが使用されたか
  #   - USING COVERING INDEX: インデックスだけでクエリが完結（テーブルアクセス不要）
  def demonstrate_explain_basics
    seed_test_data

    # ActiveRecordの.explainメソッドでクエリプランを取得
    # 内部的にはEXPLAIN QUERY PLANを実行している
    basic_explain = QpModels::Product.where(category: 'Electronics').explain

    # 生SQLでEXPLAINを直接実行
    raw_explain = ActiveRecord::Base.connection.execute(
      "EXPLAIN QUERY PLAN SELECT * FROM qp_products WHERE category = 'Electronics'"
    ).to_a

    # 全件取得のEXPLAIN（フルテーブルスキャン）
    full_scan_explain = QpModels::Product.all.explain

    # 主キー検索のEXPLAIN（最速のアクセスパス）
    pk_explain = QpModels::Product.where(id: 1).explain

    {
      basic_explain: explain_to_s(basic_explain),
      raw_explain: raw_explain,
      full_scan_explain: explain_to_s(full_scan_explain),
      pk_explain: explain_to_s(pk_explain),
      # EXPLAINの読み方ガイド
      guide: {
        'SCAN' => 'テーブル全体を走査（遅い・O(n)）',
        'SEARCH' => 'インデックスを使用した効率的な検索（速い・O(log n)）',
        'USING INDEX' => '指定されたインデックスを使用',
        'USING COVERING INDEX' => 'インデックスだけでクエリが完結（最速）',
        'USING INTEGER PRIMARY KEY' => '主キーによる直接アクセス（B-tree探索）'
      }
    }
  end

  # ==========================================================================
  # 2. インデックスの種類と選択戦略
  # ==========================================================================
  #
  # B-treeインデックス（デフォルト）:
  #   - 等値検索（=）、範囲検索（<, >, BETWEEN）、ORDER BYに有効
  #   - ソート済みのツリー構造で O(log n) のアクセス時間
  #
  # 複合インデックス:
  #   - 複数カラムを組み合わせたインデックス
  #   - 左端のカラムから順に使われる（leftmost prefix rule）
  #   - (category, price) のインデックスは category 単独でも使える
  #   - ただし price 単独では使えない
  #
  # カバリングインデックス:
  #   - クエリに必要な全カラムがインデックスに含まれている場合
  #   - テーブル本体へのアクセスが不要になり最速
  #
  # 部分インデックス（Partial Index）:
  #   - WHERE句付きのインデックス（PostgreSQLで利用可能）
  #   - 特定条件のレコードのみインデックスに含める
  #   - 例: active = true のレコードのみインデックス化
  def demonstrate_index_types
    seed_test_data

    # --- 単一カラムインデックスの効果 ---
    # category に単一インデックスがあるので SEARCH が使われる
    single_index_plan = QpModels::Product.where(category: 'Electronics').explain

    # --- 複合インデックスの効果 ---
    # (category, price) の複合インデックスが使われる
    composite_index_plan = QpModels::Product.where(category: 'Electronics')
                                            .where('price > ?', 100)
                                            .explain

    # --- 複合インデックスのleftmost prefix rule ---
    # category が先頭なので、category 単独でも複合インデックスが使える
    leftmost_plan = QpModels::Product.where(category: 'Books').explain

    # price だけの検索では複合インデックス (category, price) は使えない
    # ただし price 単体のインデックスがあるのでそちらが使われる
    price_only_plan = QpModels::Product.where('price > ?', 500).explain

    # --- ORDER BY とインデックス ---
    # インデックスがソート順に一致していればソート操作が不要になる
    ordered_plan = QpModels::Product.where(category: 'Electronics')
                                    .order(:price)
                                    .explain

    # --- インデックスが使えないケース ---
    # LIKE '%...' は先頭が不定なのでインデックスが使えない
    like_prefix_plan = QpModels::Product.where('name LIKE ?', '%phone%').explain

    # 関数を適用するとインデックスが使えなくなる
    function_plan = QpModels::Product.where('LOWER(category) = ?', 'electronics').explain

    {
      single_index: explain_to_s(single_index_plan),
      composite_index: explain_to_s(composite_index_plan),
      leftmost_prefix: explain_to_s(leftmost_plan),
      price_only: explain_to_s(price_only_plan),
      ordered: explain_to_s(ordered_plan),
      like_no_index: explain_to_s(like_prefix_plan),
      function_no_index: explain_to_s(function_plan),
      index_selection_rules: {
        '使える' => ['等値検索(=)', '範囲検索(>, <, BETWEEN)', "前方一致LIKE('abc%')", 'ORDER BY'],
        '使えない' => ["中間一致LIKE('%abc%')", '関数適用(LOWER(col))', '否定条件(!=, NOT IN)', 'OR条件（一部）']
      }
    }
  end

  # ==========================================================================
  # 3. クエリ最適化パターン: フルテーブルスキャンの回避
  # ==========================================================================
  #
  # フルテーブルスキャンが発生する典型的なパターンと、
  # インデックスを活用した最適化手法を解説する。
  #
  # 選択性（Selectivity）:
  #   インデックスの効果はカラムの選択性に依存する。
  #   選択性 = ユニークな値の数 / 全レコード数
  #   選択性が高い（値が多様）ほどインデックスが効果的。
  #   例: boolean型（true/false の2値）は選択性が低くインデックスの効果が薄い。
  def demonstrate_optimization_patterns
    seed_test_data

    # --- パターン1: カバリングインデックスによるクエリ最適化 ---
    # SELECTするカラムがすべてインデックスに含まれていれば
    # テーブル本体へのアクセスが不要になる
    #
    # (category, price) のインデックスがあるため、
    # この2カラムのみのSELECTではカバリングインデックスが使われる可能性がある
    covering_plan = QpModels::Product.where(category: 'Electronics')
                                     .select(:category, :price)
                                     .explain

    # --- パターン2: COUNT最適化 ---
    # COUNTはインデックスを使えば高速に計算できる
    QpModels::Product.where(category: 'Electronics').explain

    # --- パターン3: EXISTS vs COUNT ---
    # 存在確認にはCOUNT > 0よりEXISTSの方が効率的
    # EXISTSは最初の1件が見つかった時点で走査を停止する
    exists_sql = "SELECT EXISTS(SELECT 1 FROM qp_products WHERE category = 'Electronics')"
    count_sql = "SELECT COUNT(*) FROM qp_products WHERE category = 'Electronics'"

    exists_plan = ActiveRecord::Base.connection.execute(
      "EXPLAIN QUERY PLAN #{exists_sql}"
    ).to_a
    count_plan_raw = ActiveRecord::Base.connection.execute(
      "EXPLAIN QUERY PLAN #{count_sql}"
    ).to_a

    # --- パターン4: LIMIT最適化 ---
    # LIMITを使うと必要な行数だけ取得して走査を停止できる
    limit_plan = QpModels::Product.where(category: 'Electronics')
                                  .order(:price)
                                  .limit(5)
                                  .explain

    # --- パターン5: 選択性の概念 ---
    # 選択性が低いカラム（boolean型など）にインデックスを張っても効果が薄い
    low_selectivity_plan = QpModels::Product.where(active: true).explain

    {
      covering_index: explain_to_s(covering_plan),
      count_optimization: {
        exists_plan: exists_plan,
        count_plan: count_plan_raw,
        recommendation: '存在確認にはexists?メソッドを使用する（COUNT > 0は非効率）'
      },
      limit_optimization: explain_to_s(limit_plan),
      low_selectivity: explain_to_s(low_selectivity_plan),
      optimization_guidelines: {
        'SELECT句の最小化' => '必要なカラムだけをSELECTしてI/Oを削減',
        'EXISTS活用' => "QpModels::Product.exists?(category: 'X') はCOUNT > 0より効率的",
        'LIMIT活用' => '必要な行数だけ取得（特にORDER BY + LIMITはTop-Nクエリ）',
        '選択性の考慮' => 'boolean型のカラムにインデックスを張るのは通常非効率'
      }
    }
  end

  # ==========================================================================
  # 4. N+1問題のSQLレベルでの検出
  # ==========================================================================
  #
  # N+1問題はActiveRecordの遅延ロード（lazy loading）により発生する。
  # 親レコードN件に対して子レコードの取得が1件ずつ実行され、
  # 合計N+1回のクエリが発行される。
  #
  # EXPLAINレベルでは、同じテーブルに対するSEARCH(主キーまたは外部キー)が
  # 繰り返し実行されるパターンとして観測できる。
  #
  # 解決策:
  #   - includes: LEFT OUTER JOINまたは別クエリでプリロード
  #   - preload: 常に別クエリでプリロード
  #   - eager_load: 常にLEFT OUTER JOINでプリロード
  #   - strict_loading: N+1を検出したら例外を発生させる
  def demonstrate_n_plus_one_detection
    seed_test_data

    # --- N+1が発生するパターン ---
    # QpModels::Product.all でクエリ1回、各productのreviewsで追加クエリN回
    n_plus_one_queries = collect_queries do
      QpModels::Product.all.each do |product|
        product.reviews.to_a
      end
    end

    # --- includes（プリロード）で解決 ---
    # 1回または2回のクエリでまとめて取得
    optimized_queries = collect_queries do
      QpModels::Product.includes(:reviews).each do |product|
        product.reviews.to_a
      end
    end

    # --- eager_load（LEFT OUTER JOIN）で解決 ---
    eager_load_queries = collect_queries do
      QpModels::Product.eager_load(:reviews).each do |product|
        product.reviews.to_a
      end
    end

    # --- JOINのクエリプラン ---
    join_plan = QpModels::Product.joins(:reviews)
                                 .where('qp_reviews.rating >= ?', 4)
                                 .explain

    {
      n_plus_one: {
        query_count: n_plus_one_queries.size,
        queries: n_plus_one_queries.first(3), # 最初の3件のみ表示
        problem: 'N件のproductごとにreviewsを個別取得 → N+1回のクエリ'
      },
      optimized_includes: {
        query_count: optimized_queries.size,
        queries: optimized_queries,
        solution: 'includesで事前にまとめて取得 → 2回のクエリ'
      },
      eager_load: {
        query_count: eager_load_queries.size,
        queries: eager_load_queries.first(2),
        solution: 'eager_loadでLEFT OUTER JOINにより1回のクエリ'
      },
      join_plan: explain_to_s(join_plan),
      detection_methods: {
        'Bullet gem' => '開発環境でN+1を自動検出してアラート',
        'strict_loading' => 'Rails 6.1+: N+1発生時にStrictLoadingViolationError',
        'クエリログ' => '同じパターンのSELECTが繰り返し実行されていないか確認'
      }
    }
  end

  # ==========================================================================
  # 5. スロークエリの特定と対策
  # ==========================================================================
  #
  # 本番環境でのスロークエリ特定には複数のアプローチがある:
  #
  # 1. ActiveSupport::Notifications:
  #    sql.active_record イベントを購読してクエリ時間を監視
  #
  # 2. スロークエリログ（MySQL/PostgreSQL）:
  #    設定した閾値を超えるクエリを自動的にログに記録
  #
  # 3. Query Log Tags（Rails 7+）:
  #    クエリにアプリケーション情報（コントローラ名等）をタグ付け
  #
  # 4. EXPLAIN ANALYZE（PostgreSQL）:
  #    実際の実行時間と行数を含む詳細な実行計画
  def demonstrate_slow_query_detection
    seed_test_data

    # --- ActiveSupport::Notificationsによるクエリ監視 ---
    slow_queries = []
    threshold_ms = 0.0 # テスト用に閾値を0msに設定（通常は100ms程度）

    subscription = ActiveSupport::Notifications.subscribe('sql.active_record') do |*args|
      event = ActiveSupport::Notifications::Event.new(*args)
      if event.duration > threshold_ms
        slow_queries << {
          sql: event.payload[:sql],
          duration_ms: event.duration.round(3),
          name: event.payload[:name]
        }
      end
    end

    # いくつかのクエリを実行してモニタリング
    QpModels::Product.where(category: 'Electronics').to_a
    QpModels::Product.where('price > ?', 1000).order(:price).to_a
    QpModels::Product.joins(:reviews).group('qp_products.id').having('COUNT(qp_reviews.id) > 1').to_a

    ActiveSupport::Notifications.unsubscribe(subscription)

    # --- クエリプランの比較分析 ---
    # 効率的なクエリ（インデックスあり）
    efficient_plan = QpModels::Product.where(category: 'Electronics').explain

    # 非効率なクエリ（フルテーブルスキャンになりやすい）
    inefficient_plan = QpModels::Product.where('name || category LIKE ?', '%test%').explain

    {
      monitored_queries: slow_queries.reject { |q| q[:name] == 'SCHEMA' }.first(5),
      efficient_plan: explain_to_s(efficient_plan),
      inefficient_plan: explain_to_s(inefficient_plan),
      slow_query_strategies: {
        'ActiveSupport::Notifications' => 'sql.active_recordイベントで閾値超えを検出',
        'Query Log Tags (Rails 7+)' => "annotate('source')でクエリ発生元を特定",
        'database_statements' => 'ActiveRecord::LogSubscriberでクエリログを拡張',
        'APMツール' => 'New Relic, Datadog等でクエリパフォーマンスを可視化'
      }
    }
  end

  # ==========================================================================
  # 6. 結合戦略の分析: Nested Loop vs Hash Join
  # ==========================================================================
  #
  # SQLiteは主にNested Loop Joinを使用するが、PostgreSQLやMySQLでは
  # データ量とインデックスの有無に応じて異なる結合戦略が選択される:
  #
  # Nested Loop Join:
  #   - 外部テーブルの各行に対して内部テーブルを検索
  #   - 内部テーブルにインデックスがある場合に効率的
  #   - 小さいテーブル同士の結合に適している
  #
  # Hash Join:
  #   - 内部テーブルからハッシュテーブルを構築
  #   - 外部テーブルの各行でハッシュルックアップ
  #   - 大きいテーブル同士の結合で効率的
  #
  # Merge Join (Sort-Merge Join):
  #   - 両テーブルをソートしてマージ
  #   - 両テーブルにインデックスがある場合に効率的
  def demonstrate_join_strategies
    seed_test_data

    # --- INNER JOIN のクエリプラン ---
    inner_join_plan = QpModels::Product.joins(:reviews).explain

    # --- LEFT OUTER JOIN のクエリプラン ---
    left_join_plan = QpModels::Product.left_joins(:reviews).explain

    # --- 複数テーブルJOIN ---
    multi_join_plan = QpModels::Product.joins(:reviews, :order_items).explain

    # --- JOINの方向と結合順序 ---
    # データベースオプティマイザは結合順序を自動最適化する
    join_with_condition = QpModels::Product.joins(:reviews)
                                           .where(category: 'Electronics')
                                           .where('qp_reviews.rating >= ?', 4)
                                           .explain

    # --- サブクエリ vs JOIN の比較 ---
    # JOINアプローチ
    join_sql = QpModels::Product.joins(:reviews)
                                .where('qp_reviews.rating >= ?', 4)
                                .distinct
                                .to_sql

    # サブクエリアプローチ
    subquery_sql = QpModels::Product.where(
      id: QpModels::Review.where('rating >= ?', 4).select(:qp_product_id)
    ).to_sql

    {
      inner_join: explain_to_s(inner_join_plan),
      left_join: explain_to_s(left_join_plan),
      multi_join: explain_to_s(multi_join_plan),
      join_with_condition: explain_to_s(join_with_condition),
      comparison: {
        join_approach: join_sql,
        subquery_approach: subquery_sql,
        recommendation: '小さい結果セット → サブクエリ、大きい結果セット → JOIN が有利な傾向'
      },
      join_optimization_tips: {
        '結合カラムにインデックス' => '外部キーには必ずインデックスを張る',
        '結合前にフィルタ' => 'WHERE条件で行数を減らしてからJOIN',
        '必要なカラムのみSELECT' => 'JOINで不要なカラムを取得しない',
        'EXPLAINで確認' => '想定通りの結合戦略が選択されているか確認'
      }
    }
  end

  # ==========================================================================
  # 7. ActiveRecord EXPLAINの活用: 実践的なデバッグ手法
  # ==========================================================================
  #
  # ActiveRecordのexplainメソッドは開発・デバッグにおいて
  # クエリパフォーマンスの問題を特定するための強力なツールである。
  #
  # 使い方:
  #   User.where(name: "Alice").explain
  #   → EXPLAIN QUERY PLAN を実行して結果を文字列として返す
  #
  # Rails 7.1+ では explain(:analyze) でEXPLAIN ANALYZEも実行可能
  # （PostgreSQL/MySQLで実際の実行統計を取得）
  def demonstrate_activerecord_explain
    seed_test_data

    # --- 基本的なexplainの使い方 ---
    simple_explain = QpModels::Product.where(category: 'Electronics').explain

    # --- 複雑なクエリのexplain ---
    complex_explain = QpModels::Product.joins(:reviews)
                                       .where(category: 'Electronics')
                                       .where('qp_reviews.rating >= ?', 4)
                                       .group('qp_products.id')
                                       .having('COUNT(qp_reviews.id) >= 2')
                                       .order('qp_products.price DESC')
                                       .explain

    # --- to_sql でSQLを確認してからexplain ---
    query = QpModels::Product.where(category: 'Electronics')
                             .where('price BETWEEN ? AND ?', 100, 500)
                             .order(:price)
    sql_preview = query.to_sql
    query_explain = query.explain

    # --- 集約クエリのexplain ---
    aggregate_explain = QpModels::Product.group(:category)
                                         .select('category, AVG(price) as avg_price, COUNT(*) as count')
                                         .explain

    # --- サブクエリのexplain ---
    subquery_explain = QpModels::Product.where(
      id: QpModels::Review.where('rating >= ?', 4).select(:qp_product_id)
    ).explain

    {
      simple_explain: explain_to_s(simple_explain),
      complex_explain: explain_to_s(complex_explain),
      sql_preview: sql_preview,
      query_explain: explain_to_s(query_explain),
      aggregate_explain: explain_to_s(aggregate_explain),
      subquery_explain: explain_to_s(subquery_explain),
      explain_workflow: {
        '1. to_sqlで確認' => 'まずSQLを確認して意図通りか検証',
        '2. explainで分析' => 'SCAN/SEARCHの確認、インデックス使用状況の確認',
        '3. インデックス追加' => '必要に応じてmigrationでインデックスを追加',
        '4. 再度explain' => 'インデックス追加後に改善を確認'
      }
    }
  end

  # ==========================================================================
  # 8. インデックス設計のベストプラクティス
  # ==========================================================================
  #
  # インデックスは読み取り性能を向上させるが、書き込みコストが増加する。
  # 適切なインデックス設計にはトレードオフの理解が不可欠である。
  #
  # 設計原則:
  #   1. 頻繁に検索されるカラムにインデックスを張る
  #   2. 外部キーには必ずインデックスを張る（has_many/belongs_to）
  #   3. 複合インデックスは選択性の高いカラムを先頭に配置
  #   4. 不要なインデックスは削除（書き込み性能の低下を防ぐ）
  #   5. カバリングインデックスを意識する
  def demonstrate_index_best_practices
    seed_test_data

    # --- 現在のインデックス一覧を取得 ---
    connection = ActiveRecord::Base.connection
    product_indexes = connection.indexes(:qp_products).map do |idx|
      { name: idx.name, columns: idx.columns, unique: idx.unique }
    end

    review_indexes = connection.indexes(:qp_reviews).map do |idx|
      { name: idx.name, columns: idx.columns, unique: idx.unique }
    end

    # --- 複合インデックスの順序の重要性 ---
    # (category, price) は category = ? AND price > ? に最適
    optimal_order_plan = QpModels::Product.where(category: 'Electronics')
                                          .where('price > ?', 100)
                                          .explain

    # --- 不要なインデックスの検出 ---
    # 単一カラムインデックスが複合インデックスの先頭と重複する場合、
    # 単一カラムインデックスは冗長になる可能性がある
    # 例: category の単一インデックスは (category, price) の複合インデックスで代替可能
    redundant_check = {
      single_index: 'index_products_on_category',
      composite_index: 'index_products_on_category_and_price',
      analysis: '複合インデックスの先頭カラムが同じため、単一インデックスは冗長の可能性あり'
    }

    # --- WHERE + ORDER BY の最適インデックス ---
    # WHERE category = ? ORDER BY price は (category, price) の複合インデックスで最適化
    where_order_plan = QpModels::Product.where(category: 'Electronics')
                                        .order(:price)
                                        .explain

    {
      product_indexes: product_indexes,
      review_indexes: review_indexes,
      optimal_order: explain_to_s(optimal_order_plan),
      redundant_check: redundant_check,
      where_order: explain_to_s(where_order_plan),
      best_practices: {
        '外部キーインデックス' => 'belongs_toの外部キーには必ずインデックスを張る',
        '複合インデックスの順序' => 'WHERE等値条件のカラム → 範囲条件のカラム → ORDER BYのカラム',
        '選択性の確認' => 'カーディナリティが低いカラム単体のインデックスは効果が薄い',
        '書き込みへの影響' => 'インデックスが多いとINSERT/UPDATE/DELETEが遅くなる',
        '定期的な見直し' => 'pg_stat_user_indexes等で使用頻度を確認し不要なものを削除'
      }
    }
  end

  # ==========================================================================
  # ヘルパーメソッド
  # ==========================================================================

  # ExplainProxyからクエリプラン文字列を取得するヘルパー
  # Rails 8.1ではexplainがExplainProxyを返し、inspectで実際のプランが取得できる
  def explain_to_s(explain_proxy)
    explain_proxy.inspect
  end

  # テストデータの投入
  def seed_test_data
    # 外部キー制約があるため、子テーブルから先に削除する
    QpModels::OrderItem.delete_all
    QpModels::Review.delete_all
    QpModels::Product.delete_all

    categories = %w[Electronics Books Clothing Food Sports]
    products = []

    50.times do |i|
      products << QpModels::Product.create!(
        name: "Product #{i + 1}",
        price: (rand * 1000).round(2),
        category: categories[i % categories.size],
        active: i < 45, # 90%がactive
        stock_quantity: rand(0..100)
      )
    end

    # レビューデータ
    products.first(30).each do |product|
      rand(1..5).times do
        QpModels::Review.create!(
          product: product,
          rating: rand(1..5),
          comment: "レビューコメント for #{product.name}"
        )
      end
    end

    # 注文データ
    products.first(20).each do |product|
      rand(1..3).times do
        QpModels::OrderItem.create!(
          product: product,
          quantity: rand(1..10),
          unit_price: product.price
        )
      end
    end
  end

  # クエリを収集するヘルパー
  # ActiveSupport::Notificationsを使って実行されたSQLを記録する
  def collect_queries
    queries = []
    subscription = ActiveSupport::Notifications.subscribe('sql.active_record') do |*args|
      event = ActiveSupport::Notifications::Event.new(*args)
      # スキーマ関連のクエリを除外
      next if event.payload[:name] == 'SCHEMA'
      next if event.payload[:sql].start_with?('PRAGMA')

      queries << event.payload[:sql]
    end

    yield

    ActiveSupport::Notifications.unsubscribe(subscription)
    queries
  end
end
