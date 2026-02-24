# frozen_string_literal: true

# ActiveRecordクエリ構築とArel ASTの内部構造を解説するモジュール
#
# ActiveRecordのクエリインターフェースは内部的にArel（A Relational Algebra）を使用して
# SQLを構築している。ArelはSQL ASTをRubyオブジェクトとして表現し、
# Visitorパターンを使って各DBMSに適したSQLを生成する。
#
# このモジュールでは、シニアRailsエンジニアが知るべきArelの仕組みと
# ActiveRecordのクエリ変換過程を実例を通じて学ぶ。

require 'active_record'

# --- インメモリSQLiteデータベースのセットアップ ---
ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:') unless ActiveRecord::Base.connected?
ActiveRecord::Base.logger = nil # テスト時のログ出力を抑制

ActiveRecord::Schema.define do
  create_table :arel_users, force: true do |t|
    t.string :name
    t.string :email
    t.integer :age
    t.timestamps null: false
  end

  create_table :arel_posts, force: true do |t|
    t.references :arel_user
    t.string :title
    t.text :body
    t.boolean :published, default: false
    t.timestamps null: false
  end
end

# --- モデル定義 ---
module ArelModels
  class User < ActiveRecord::Base
    self.table_name = 'arel_users'
    has_many :posts, class_name: 'ArelModels::Post', foreign_key: 'arel_user_id'
  end

  class Post < ActiveRecord::Base
    self.table_name = 'arel_posts'
    belongs_to :user, class_name: 'ArelModels::User', foreign_key: 'arel_user_id'
  end
end

module ActiveRecordArel
  module_function

  # ==========================================================================
  # 1. Arelテーブルとノード: AST（抽象構文木）の基本要素
  # ==========================================================================
  #
  # Arel::Tableはデータベーステーブルを表現するオブジェクト。
  # テーブルの各カラムはArel::Attributes::Attributeとして参照でき、
  # これらを組み合わせてSQL AST（抽象構文木）を構築する。
  #
  # ActiveRecordモデルは内部的にarel_tableメソッドでArel::Tableにアクセスする。
  def demonstrate_arel_table_and_nodes
    # Arel::Tableの取得方法
    users_table = Arel::Table.new(:arel_users)
    # ActiveRecordモデル経由でも取得可能
    users_from_model = ArelModels::User.arel_table

    # カラムへの参照（Arel::Attributes::Attribute）
    name_attr = users_table[:name]
    age_attr = users_table[:age]

    # Arel::Tableは同じテーブルを指す
    same_table = users_table.name == users_from_model.name

    # 属性ノードのクラス構造
    attr_class = name_attr.class

    # SelectManagerを使ったSELECTクエリの構築
    # project = SELECT句、from = FROM句
    select_manager = users_table.project(users_table[:name], users_table[:age])
    select_sql = select_manager.to_sql

    {
      table_name: users_table.name,
      same_table: same_table,
      attr_class: attr_class.name,
      name_attr_name: name_attr.name.to_s,
      age_attr_name: age_attr.name.to_s,
      select_sql: select_sql
    }
  end

  # ==========================================================================
  # 2. Arelの述語（Predicates）: WHERE句の構築
  # ==========================================================================
  #
  # Arelの述語メソッドはArel::Nodes::Nodeのサブクラスを返す。
  # eq, not_eq, gt, lt, gteq, lteq, matches, in, between など
  # SQLのWHERE句に相当するAST ノードを生成する。
  #
  # これらのノードは直接to_sqlでSQL文字列に変換できる。
  def demonstrate_arel_predicates
    users = ArelModels::User.arel_table

    # 等値比較: eq（=）, not_eq（!=）
    eq_node = users[:name].eq('Alice')
    not_eq_node = users[:name].not_eq('Bob')

    # 比較: gt（>）, lt（<）, gteq（>=）, lteq（<=）
    gt_node = users[:age].gt(25)
    lt_node = users[:age].lt(60)

    # パターンマッチ: matches（LIKE）
    matches_node = users[:email].matches('%@example.com')

    # 包含: in（IN）
    in_node = users[:age].in([25, 30, 35])

    # 範囲: between（BETWEEN）
    between_node = users[:age].between(20..40)

    # NULL判定: eq(nil)はIS NULLに変換される
    null_node = users[:email].eq(nil)
    not_null_node = users[:email].not_eq(nil)

    {
      eq_sql: eq_node.to_sql,
      not_eq_sql: not_eq_node.to_sql,
      gt_sql: gt_node.to_sql,
      lt_sql: lt_node.to_sql,
      matches_sql: matches_node.to_sql,
      in_sql: in_node.to_sql,
      between_sql: between_node.to_sql,
      null_sql: null_node.to_sql,
      not_null_sql: not_null_node.to_sql,
      # ノードのクラスを確認
      eq_node_class: eq_node.class.name,
      gt_node_class: gt_node.class.name
    }
  end

  # ==========================================================================
  # 3. Arelの合成可能性（Composability）: 複雑な条件の構築
  # ==========================================================================
  #
  # Arelのノードはandとorで合成できる。
  # これにより、動的にWHERE句を構築できる。
  # ActiveRecordのwhereチェーンは内部的にこの仕組みを使っている。
  def demonstrate_arel_composability
    users = ArelModels::User.arel_table

    # AND条件の構築
    age_condition = users[:age].gteq(20).and(users[:age].lteq(40))

    # OR条件の構築
    name_condition = users[:name].eq('Alice').or(users[:name].eq('Bob'))

    # 複合条件: (age >= 20 AND age <= 40) AND (name = 'Alice' OR name = 'Bob')
    complex_condition = age_condition.and(name_condition)

    # NOT条件
    not_condition = users[:name].eq('Charlie').not

    # 動的な条件の構築パターン
    # 検索パラメータに応じて条件を追加する実践的な例
    conditions = []
    conditions << users[:age].gteq(18)
    conditions << users[:name].matches('%田%')

    # reduceで条件をANDで結合
    combined = conditions.reduce(:and)

    # SelectManagerに条件を適用
    query = users.project(Arel.star).where(complex_condition)

    {
      and_sql: age_condition.to_sql,
      or_sql: name_condition.to_sql,
      complex_sql: complex_condition.to_sql,
      not_sql: not_condition.to_sql,
      combined_sql: combined.to_sql,
      full_query_sql: query.to_sql
    }
  end

  # ==========================================================================
  # 4. ActiveRecordからArelへの変換過程
  # ==========================================================================
  #
  # ActiveRecordのwhere, joins, order, select メソッドは
  # 内部的にArel ASTを構築している。
  # to_sqlメソッドで最終的なSQL文字列を確認できる。
  #
  # ActiveRecord::Relationはレイジーロード（遅延評価）であり、
  # 実際にDBアクセスするのはto_a, each, firstなどが呼ばれた時。
  def demonstrate_activerecord_to_arel
    # whereチェーン → Arel条件の構築
    where_sql = ArelModels::User.where(name: 'Alice').where('age > ?', 25).to_sql

    # Hashのwhere → Arelのeq述語に変換される
    hash_where_sql = ArelModels::User.where(name: 'Alice', age: 30).to_sql

    # 配列条件のwhere → バインドパラメータとして処理
    array_where_sql = ArelModels::User.where('name = ? AND age > ?', 'Alice', 25).to_sql

    # order → Arel::Nodes::Ascending / Descending
    order_sql = ArelModels::User.order(age: :desc, name: :asc).to_sql

    # Arel直接利用: ActiveRecordのwhereにArelノードを渡す
    users = ArelModels::User.arel_table
    arel_where_sql = ArelModels::User.where(users[:age].gt(25).and(users[:name].matches('A%'))).to_sql

    # joins → Arel::Nodes::InnerJoin
    join_sql = ArelModels::User.joins(:posts).to_sql

    # select → Arel::Nodes::SqlLiteral / project
    select_sql = ArelModels::User.select(:name, :email).to_sql

    # group + having
    group_sql = ArelModels::User.joins(:posts)
                                .group('arel_users.id')
                                .having('COUNT(arel_posts.id) > 3')
                                .select('arel_users.name, COUNT(arel_posts.id) as post_count')
                                .to_sql

    {
      where_sql: where_sql,
      hash_where_sql: hash_where_sql,
      array_where_sql: array_where_sql,
      order_sql: order_sql,
      arel_where_sql: arel_where_sql,
      join_sql: join_sql,
      select_sql: select_sql,
      group_sql: group_sql
    }
  end

  # ==========================================================================
  # 5. Arel SQL生成: VisitorパターンによるSQL出力
  # ==========================================================================
  #
  # ArelはVisitorパターンを使用してAST（抽象構文木）からSQLを生成する。
  #
  # 構造:
  #   Arel::Visitors::ToSql       - 標準SQL生成（ベース）
  #   Arel::Visitors::SQLite      - SQLite固有の変換
  #   Arel::Visitors::MySQL       - MySQL固有の変換
  #   Arel::Visitors::PostgreSQL  - PostgreSQL固有の変換
  #
  # 各ノード（Arel::Nodes::*）はacceptメソッドを持ち、
  # Visitorのvisitメソッドに自分を渡す（ダブルディスパッチ）。
  #
  # このパターンにより、同じASTから異なるDBMS向けのSQLを生成できる。
  def demonstrate_arel_sql_generation
    users = ArelModels::User.arel_table

    # ASTノードの構造を確認
    eq_node = users[:name].eq('Alice')

    # ノードのクラス階層
    node_ancestors = eq_node.class.ancestors.select { |a| a.name&.start_with?('Arel') }

    # Visitorを使ったSQL生成の内部プロセス
    # ActiveRecordの接続アダプタがVisitorを提供する
    connection = ActiveRecord::Base.connection
    visitor_class = connection.visitor.class.name

    # to_sqlはVisitor#accept(node)を呼び出す
    # accept内部ではvisit_Arel_Nodes_Equality のようなメソッドが呼ばれる
    generated_sql = eq_node.to_sql

    # SelectManagerを使った完全なクエリのAST
    manager = users.project(users[:name])
                   .where(users[:age].gt(20))
                   .order(users[:name].asc)
    manager_sql = manager.to_sql

    # Arel.sqlでリテラルSQLを表現
    literal = Arel.sql('COUNT(*)')
    count_query = users.project(literal)
    count_sql = count_query.to_sql

    {
      node_class: eq_node.class.name,
      node_ancestors: node_ancestors.map(&:name),
      visitor_class: visitor_class,
      generated_sql: generated_sql,
      manager_sql: manager_sql,
      count_sql: count_sql,
      # Visitorパターンの概念図
      visitor_concept: 'AST Node#accept(visitor) → visitor#visit(node) → SQL文字列'
    }
  end

  # ==========================================================================
  # 6. サブクエリとArel: EXISTS句、サブSELECT
  # ==========================================================================
  #
  # Arelを使うことで、ActiveRecordだけでは表現しにくい
  # サブクエリやEXISTS句を構築できる。
  def demonstrate_subqueries
    users = ArelModels::User.arel_table
    posts = ArelModels::Post.arel_table

    # EXISTS句: 投稿を持つユーザーを検索
    # SELECT * FROM arel_users WHERE EXISTS (SELECT 1 FROM arel_posts WHERE arel_posts.arel_user_id = arel_users.id)
    exists_subquery = posts.project(Arel.sql('1'))
                           .where(posts[:arel_user_id].eq(users[:id]))
    exists_condition = Arel::Nodes::Exists.new(exists_subquery)
    exists_sql = users.project(Arel.star).where(exists_condition).to_sql

    # NOT EXISTS: 投稿を持たないユーザーを検索
    not_exists_condition = Arel::Nodes::Not.new(exists_condition)
    not_exists_sql = users.project(Arel.star).where(not_exists_condition).to_sql

    # INサブクエリ: 公開済み投稿を持つユーザーIDを取得
    published_user_ids = posts.project(posts[:arel_user_id])
                              .where(posts[:published].eq(true))
    in_subquery_sql = users.project(Arel.star)
                           .where(users[:id].in(published_user_ids))
                           .to_sql

    # ActiveRecordでのサブクエリ活用
    # whereにActiveRecord::Relationを渡すとサブクエリになる
    ar_subquery_sql = ArelModels::User.where(
      id: ArelModels::Post.where(published: true).select(:arel_user_id)
    ).to_sql

    # スカラーサブクエリ: ユーザーごとの投稿数を取得
    post_count_subquery = posts.project(posts[:id].count)
                               .where(posts[:arel_user_id].eq(users[:id]))
    scalar_sql = users.project(
      users[:name],
      Arel::Nodes::As.new(post_count_subquery, Arel.sql('post_count'))
    ).to_sql

    {
      exists_sql: exists_sql,
      not_exists_sql: not_exists_sql,
      in_subquery_sql: in_subquery_sql,
      ar_subquery_sql: ar_subquery_sql,
      scalar_subquery_sql: scalar_sql
    }
  end

  # ==========================================================================
  # 7. SQLインジェクション防止: Arelのパラメータ化クエリ
  # ==========================================================================
  #
  # Arelは述語メソッド（eq, matches等）を使用すると自動的に
  # 値をクォートまたはバインドパラメータとして処理し、
  # SQLインジェクションを防止する。
  #
  # 一方、文字列補間やArel.sqlにユーザー入力を直接渡すと
  # インジェクションのリスクが発生する。
  def demonstrate_injection_prevention
    users = ArelModels::User.arel_table

    # === 安全なクエリ（Arel述語による自動エスケープ） ===
    # Arel述語はシングルクォートのエスケープを自動で行う
    malicious_input = "'; DROP TABLE arel_users; --"
    safe_node = users[:name].eq(malicious_input)
    safe_sql = safe_node.to_sql

    # matchesも安全にエスケープする
    safe_matches = users[:email].matches("%#{malicious_input}%")
    safe_matches_sql = safe_matches.to_sql

    # ActiveRecordのwhereも安全
    # プレースホルダ（?）はバインドパラメータとして処理される
    ar_safe_sql = ArelModels::User.where('name = ?', malicious_input).to_sql

    # Hashのwhereも安全
    ar_hash_sql = ArelModels::User.where(name: malicious_input).to_sql

    # === 危険なクエリ（文字列補間） ===
    # 以下は実行せず、危険性の説明のみ
    dangerous_example = "ArelModels::User.where(\"name = '#{malicious_input}'\")"

    # === Arel.sqlの正しい使い方と危険な使い方 ===
    # Arel.sqlは生SQLを挿入するため、ユーザー入力を渡してはならない
    safe_arel_sql_usage = "Arel.sql('COUNT(*)') -- 定数のみ使用"
    dangerous_arel_sql_usage = "Arel.sql(\"name = '#{malicious_input}'\") -- 絶対にやってはいけない"

    {
      safe_sql: safe_sql,
      safe_matches_sql: safe_matches_sql,
      ar_safe_sql: ar_safe_sql,
      ar_hash_sql: ar_hash_sql,
      # 危険なパターンは文字列として説明のみ
      dangerous_example: dangerous_example,
      safe_arel_sql_usage: safe_arel_sql_usage,
      dangerous_arel_sql_usage: dangerous_arel_sql_usage,
      # エスケープ確認: シングルクォートが適切にエスケープされている
      injection_prevented: safe_sql.include?("''")
    }
  end

  # ==========================================================================
  # 8. カスタムArelノード: DB固有機能の拡張
  # ==========================================================================
  #
  # Arelは拡張可能な設計になっており、標準ノードだけでは表現できない
  # DB固有の機能（ウィンドウ関数、CTE、LATERAL JOINなど）を
  # カスタムノードとして実装できる。
  #
  # ただし、Rails 7以降ではActiveRecordが多くの高度な機能を
  # サポートするようになっている。
  def demonstrate_custom_arel_nodes
    users = ArelModels::User.arel_table

    # --- ウィンドウ関数 ---
    # Arel::Nodes::Overを使ってウィンドウ関数を構築
    # ROW_NUMBER() OVER (ORDER BY age DESC)
    row_number = Arel::Nodes::Over.new(
      Arel::Nodes::NamedFunction.new('ROW_NUMBER', []),
      Arel::Nodes::Window.new.order(users[:age].desc)
    )
    window_sql = users.project(
      users[:name],
      users[:age],
      Arel::Nodes::As.new(row_number, Arel.sql('row_num'))
    ).to_sql

    # --- NamedFunction: カスタムSQL関数 ---
    # COALESCE(email, 'unknown')
    coalesce = Arel::Nodes::NamedFunction.new(
      'COALESCE',
      [users[:email], Arel.sql("'unknown'")]
    )
    coalesce_sql = users.project(users[:name], coalesce).to_sql

    # UPPER(name)
    upper = Arel::Nodes::NamedFunction.new('UPPER', [users[:name]])
    upper_sql = users.project(upper).to_sql

    # --- CASE WHEN文 ---
    # CASE WHEN age >= 30 THEN 'senior' ELSE 'junior' END
    case_node = Arel::Nodes::Case.new
                                 .when(users[:age].gteq(30)).then(Arel.sql("'senior'"))
                                 .else(Arel.sql("'junior'"))
    case_sql = users.project(
      users[:name],
      Arel::Nodes::As.new(case_node, Arel.sql('category'))
    ).to_sql

    # --- UNION ---
    # ActiveRecordのRelationに対してarel.unionを使う
    young_users = users.project(users[:name]).where(users[:age].lt(25))
    senior_users = users.project(users[:name]).where(users[:age].gteq(40))
    union_node = young_users.union(senior_users)
    # UNIONをサブクエリとして利用
    union_sql = Arel::Nodes::As.new(union_node, Arel.sql('combined_users'))

    {
      window_sql: window_sql,
      coalesce_sql: coalesce_sql,
      upper_sql: upper_sql,
      case_sql: case_sql,
      union_node_class: union_node.class.name,
      union_as_sql: union_sql.to_sql
    }
  end

  # ==========================================================================
  # 9. 実行結果の検証用: テストデータの投入と実クエリ実行
  # ==========================================================================
  #
  # ArelのSQL生成だけでなく、実際にデータベースに対して
  # クエリを実行して結果を検証する。
  def demonstrate_query_execution
    # テストデータの投入
    ArelModels::User.delete_all
    ArelModels::Post.delete_all

    alice = ArelModels::User.create!(name: 'Alice', email: 'alice@example.com', age: 28)
    bob = ArelModels::User.create!(name: 'Bob', email: 'bob@example.com', age: 35)
    ArelModels::User.create!(name: 'Charlie', email: 'charlie@test.com', age: 22)

    ArelModels::Post.create!(user: alice, title: 'Rails入門', body: 'Railsの基礎', published: true)
    ArelModels::Post.create!(user: alice, title: 'Arel解説', body: 'Arelの内部構造', published: true)
    ArelModels::Post.create!(user: bob, title: 'Ruby Tips', body: '便利なテクニック', published: false)

    users = ArelModels::User.arel_table

    # Arel述語を使ったクエリの実行
    age_filtered = ArelModels::User.where(users[:age].gteq(25)).order(:name).pluck(:name)

    # LIKE検索
    email_filtered = ArelModels::User.where(users[:email].matches('%@example.com')).pluck(:name)

    # EXISTS句で投稿を持つユーザーを検索
    # ActiveRecordのwhereにEXISTS条件を渡す場合、
    # SelectManagerではなくそのAST(.ast)を渡す必要がある（SQLite互換性のため）
    posts = ArelModels::Post.arel_table
    exists_subquery = posts.project(Arel.sql('1'))
                           .where(posts[:arel_user_id].eq(users[:id]))
                           .where(posts[:published].eq(true))
    users_with_published = ArelModels::User.where(
      Arel::Nodes::Exists.new(exists_subquery.ast)
    ).pluck(:name)

    # OR条件の実行
    or_result = ArelModels::User.where(
      users[:name].eq('Alice').or(users[:age].lt(25))
    ).order(:name).pluck(:name)

    {
      age_filtered: age_filtered,
      email_filtered: email_filtered,
      users_with_published: users_with_published,
      or_result: or_result,
      total_users: ArelModels::User.count,
      total_posts: ArelModels::Post.count
    }
  end
end
