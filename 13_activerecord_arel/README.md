# ActiveRecordとArelの内部構造

## 概要

ActiveRecordのクエリインターフェースは、内部的にArel（A Relational
Algebra）というライブラリを使用してSQLを構築しています。ArelはSQLをRubyオブジェクトの木構造（AST:
抽象構文木）として表現し、Visitorパターンを使って各DBMSに適したSQL文字列を生成します。

シニアRailsエンジニアにとって、Arelの理解は以下の場面で不可欠です。

- ActiveRecordの `where` や `joins` だけでは表現できない複雑なクエリを構築する場合
- パフォーマンスチューニング時にSQL生成過程を理解する場合
- SQLインジェクション防止の仕組みを把握する場合
- カスタムスコープやクエリオブジェクトを設計する場合

## Arelの仕組み - Visitorパターン

### ASTの構造

Arelは関係代数の各操作をノードオブジェクトとして表現します。

```text

SelectManager（SELECTクエリ全体）
├── SelectCore
│   ├── Projections（SELECT句）
│   │   └── [Attribute(:name), Attribute(:email)]
│   ├── Source（FROM句）
│   │   └── Table(:users)
│   └── Wheres（WHERE句）
│       └── And
│           ├── Equality(Attribute(:age), 25)
│           └── Matches(Attribute(:email), '%@example.com')
├── Orders（ORDER BY句）
│   └── Ascending(Attribute(:name))
└── Limit（LIMIT句）
    └── Literal(10)

```

### Visitorパターンによるダブルディスパッチ

ArelのSQL生成はGoFデザインパターンのVisitorパターンを使用しています。

```ruby

# 各ノードはacceptメソッドを持ちます

class Arel::Nodes::Equality
  def accept(visitor)
    visitor.visit(self)  # ← ダブルディスパッチ
  end
end

# Visitorはノードの型に応じたメソッドを呼び出します

class Arel::Visitors::ToSql
  def visit_Arel_Nodes_Equality(node, collector)
    visit(node.left, collector)  # カラム名を出力
    collector << " = "
    visit(node.right, collector) # 値を出力（バインドパラメータ化）
  end
end

```

DBMS固有のVisitorがベースを継承してオーバーライドします。

| Visitor | 対象DBMS | 固有機能
| --------- | ---------- | ----------
| `Arel::Visitors::SQLite` | SQLite | 型キャスト、LIMIT
| `Arel::Visitors::MySQL` | MySQL | バッククォート、LOCK
| `Arel::Visitors::PostgreSQL` | PostgreSQL | DISTINCT ON、RETURNING

## 複雑クエリの構築テクニック

### 動的WHERE句の構築

検索フォームのように、条件が動的に変わるクエリはArelで安全に構築できます。

```ruby

users = User.arel_table
conditions = []

# パラメータが存在する場合のみ条件を追加します

conditions << users[:age].gteq(params[:min_age]) if params[:min_age]
conditions << users[:name].matches("%#{params[:keyword]}%") if params[:keyword]
conditions << users[:email].not_eq(nil) if params[:email_required]

# reduceで全条件をAND結合します

scope = if conditions.any?
          User.where(conditions.reduce(:and))
        else
          User.all
        end

```

### EXISTS句によるサブクエリ

JOINよりもEXISTSの方がパフォーマンスが良い場合があります（特に1対多の関連で重複を避けたい場合）。

```ruby

users = User.arel_table
posts = Post.arel_table

# 公開済み投稿を持つユーザーを検索します

exists_subquery = posts.project(Arel.sql("1"))
                       .where(posts[:user_id].eq(users[:id]))
                       .where(posts[:published].eq(true))

User.where(Arel::Nodes::Exists.new(exists_subquery))

```

### ウィンドウ関数

```ruby

users = User.arel_table

row_number = Arel::Nodes::Over.new(
  Arel::Nodes::NamedFunction.new("ROW_NUMBER", []),
  Arel::Nodes::Window.new.order(users[:age].desc)
)

User.select(
  users[:name],
  users[:age],
  Arel::Nodes::As.new(row_number, Arel.sql("ranking"))
)

```

### CASE WHEN文

```ruby

users = User.arel_table

category = Arel::Nodes::Case.new
             .when(users[:age].gteq(30)).then(Arel.sql("'senior'"))
             .else(Arel.sql("'junior'"))

User.select(users[:name], Arel::Nodes::As.new(category, Arel.sql("level")))

```

### UNION

```ruby

young = User.where(age: ..24).select(:name, :email)
senior = User.where(age: 40..).select(:name, :email)

# Arel経由でUNIONを実行します

union = young.arel.union(senior.arel)
User.from(Arel::Nodes::As.new(union, User.arel_table))

```

## SQLインジェクション防止

### 安全なパターン

Arelの述語メソッドは値を自動的にクォート/エスケープします。

```ruby

users = User.arel_table
input = "'; DROP TABLE users; --"

# 安全: Arel述語（自動エスケープ）

users[:name].eq(input)

# => "users"."name" = '''; DROP TABLE users; --'

# シングルクォートがエスケープされ、攻撃が無効化されます

# 安全: ActiveRecordプレースホルダ

User.where("name = ?", input)

# => バインドパラメータとして処理されます

# 安全: Hash条件

User.where(name: input)

# => 内部的にArel eq述語に変換されます

```

### 危険なパターン

```ruby

input = "'; DROP TABLE users; --"

# 危険: 文字列補間

User.where("name = '#{input}'")

# => SQL: name = ''; DROP TABLE users; --'

# DROP TABLE文が実行されてしまいます

# 危険: Arel.sqlにユーザー入力を渡す

User.where(Arel.sql("name = '#{input}'"))

# => Arel.sqlは内容をそのまま渡すため、インジェクションが発生します

```

### 安全性の判断基準

| パターン | 安全性 | 理由
| ---------- | -------- | ------
| `where(name: input)` | 安全 | Hash → Arel eq → 自動エスケープされます
| `where("name = ?", input)` | 安全 | プレースホルダ → バインドパラメータとして処理されます
| `arel[:name].eq(input)` | 安全 | Arel述語 → 自動クォートされます
| `where("name = '#{input}'")` | 危険 | 文字列補間 → エスケープされません
| `Arel.sql("... #{input} ...")` | 危険 | 生SQL → エスケープされません

## ActiveRecordのクエリ変換過程

ActiveRecordのメソッドチェーンからSQLが実行されるまでの全過程を以下に示します。

```sql

1. ActiveRecord::QueryMethods
   User.where(name: "Alice").where(age: 25..35).order(:name)
   │
   ├── where(name: "Alice")
   │   → WhereClause にHash条件を追加
   │   → 内部で Arel::Table#[](:name).eq("Alice") に変換
   │
   ├── where(age: 25..35)
   │   → WhereClause にRange条件を追加
   │   → 内部で Arel::Table#[](:age).between(25..35) に変換
   │
   └── order(:name)
       → OrderClause に追加
       → 内部で Arel::Table#[](:name).asc に変換

2. ActiveRecord::Relation#build_arel
   WhereClause, OrderClause, SelectClause等をまとめて
   Arel::SelectManager を構築する

3. Arel::SelectManager#to_sql（Visitorパターン）
   → Arel::Visitors::SQLite#accept(ast)
   → ノードを再帰的にvisitしてSQL文字列を組み立てる

4. SQL実行
   SELECT "users".* FROM "users"
   WHERE "users"."name" = 'Alice'
     AND "users"."age" BETWEEN 25 AND 35
   ORDER BY "users"."name" ASC

```

### ActiveRecord::Relationの遅延評価

重要な点として、ActiveRecord::Relationはメソッドチェーンの段階ではSQLを実行しません。以下のメソッドが呼ばれた時点で初めてSQLが発行されます。

- `to_a` / `records` - 配列に変換します
- `each` / `map` - イテレーションを実行します
- `first` / `last` - 先頭/末尾を取得します
- `count` / `sum` - 集計を実行します
- `pluck` - カラム値を取得します
- `exists?` - 存在を確認します
- `inspect` - コンソール表示時に実行されます

```ruby

# この時点ではSQLは実行されません（Relationオブジェクトが返ります）

relation = User.where(age: 25..35).order(:name)

# ここで初めてSQLが実行されます

users = relation.to_a

```

## 実行方法

```bash

# メインファイルの実行

ruby 13_activerecord_arel/activerecord_arel.rb

# テストの実行

bundle exec rspec 13_activerecord_arel/activerecord_arel_spec.rb

```

## 参考資料

-
  [Arelソースコード（Rails内蔵）](https://github.com/rails/rails/tree/main/activerecord/lib/arel)
- [ActiveRecord Query
  Interface（Railsガイド）](https://railsguides.jp/active_record_querying.html)
-
  [Arel::Visitors::ToSql](https://github.com/rails/rails/blob/main/activerecord/lib/arel/visitors/to_sql.rb)
