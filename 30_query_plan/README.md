# EXPLAINとクエリプラン解析

## なぜクエリプラン解析の理解が重要か

データベースのパフォーマンス問題は、Railsアプリケーションにおける最も一般的なボトルネックです。EXPLAINコマンドを使ったクエリプラン解析は、
SQLがどのように実行されるかを理解し、適切なインデックス戦略を立てるための最も重要なスキルです。

シニアエンジニアがクエリプラン解析を深く理解すべき理由は以下の通りです。

- パフォーマンス問題の根本原因特定: スロークエリの原因がインデックス不足か、クエリ構造の問題かを判別できます
- インデックス設計の最適化: 不要なインデックスを削除し、必要なインデックスを追加する判断ができます
- スケーラビリティの確保: データ量の増加に伴うパフォーマンス劣化を事前に予測・対策できます
- コードレビューの質向上: マイグレーションやクエリの変更がパフォーマンスに与える影響を評価できます

## EXPLAINの読み方

### SQLiteのEXPLAIN QUERY PLAN

SQLiteでは`EXPLAIN QUERY PLAN`コマンドで実行計画を確認できます。ActiveRecordでは`.explain`メソッドを使用します。

```ruby

# ActiveRecordでのEXPLAIN実行

Product.where(category: "Electronics").explain

# => EXPLAIN for: SELECT "products".* FROM "products" WHERE "products"."category" = ?

#    SEARCH products USING INDEX index_products_on_category (category=?)

```

### 主要なキーワード

| キーワード | 意味 | パフォーマンス
| ----------- | ------ | -------------
| `SCAN` | テーブル全体を走査します（フルテーブルスキャン） | 遅いです（O(n)）
| `SEARCH` | インデックスを使用した検索を行います | 速いです（O(log n)）
| `USING INDEX` | 指定されたインデックスを使用します | インデックスを活用します
| `USING COVERING INDEX` | インデックスだけでクエリが完結します | 最速です
| `USING INTEGER PRIMARY KEY` | 主キーによる直接アクセスを行います | 非常に速いです
| `USING TEMPORARY B-TREE` | ソートのために一時的なB-treeを構築します | 追加コストがかかります

### PostgreSQLのEXPLAIN ANALYZE

PostgreSQLではより詳細な実行計画が得られます。

```sql

EXPLAIN ANALYZE SELECT * FROM products WHERE category = 'Electronics';

-- 出力例:
-- Index Scan using index_products_on_category on products
--   (cost=0.28..8.29 rows=1 width=100) (actual time=0.015..0.017 rows=10 loops=1)
--   Index Cond: ((category)::text = 'Electronics'::text)
-- Planning Time: 0.100 ms
-- Execution Time: 0.035 ms

```

PostgreSQLのEXPLAIN出力の読み方は以下の通りです。

- cost: `startup_cost..total_cost`の形式で、オプティマイザが見積もったコストを示します
- rows: 返される行数の推定値です
- actual time: 実際の実行時間です（ANALYZE使用時のみ）
- Seq Scan: シーケンシャルスキャン（フルテーブルスキャン）です
- Index Scan: インデックスを使った検索です
- Index Only Scan: カバリングインデックスによる検索です（テーブルアクセス不要）
- Bitmap Index Scan: ビットマップインデックススキャンです（複数インデックスの組み合わせ）
- Nested Loop / Hash Join / Merge Join: 結合戦略です

## インデックス戦略

### B-treeインデックス（デフォルト）

Railsで`add_index`を使うとB-treeインデックスが作成されます。ソート済みのツリー構造で、等値検索・範囲検索・ORDER BYに効果的です。

```ruby

# マイグレーションでのインデックス追加

class AddIndexToProducts < ActiveRecord::Migration[8.0]
  def change
    add_index :products, :category                        # 単一カラム
    add_index :products, [:category, :price]              # 複合インデックス
    add_index :products, :email, unique: true             # ユニークインデックス
  end
end

```

### 複合インデックスの設計原則

複合インデックスはleftmost prefix rule（左端プレフィックスルール）に従います。

```sql

インデックス: (category, price, created_at)

使える検索パターン:
  WHERE category = 'Electronics'
  WHERE category = 'Electronics' AND price > 100
  WHERE category = 'Electronics' AND price > 100 AND created_at > '2024-01-01'

使えない検索パターン:
  WHERE price > 100                  （先頭のcategoryがありません）
  WHERE created_at > '2024-01-01'    （先頭のcategoryがありません）
  WHERE price > 100 AND created_at > '2024-01-01'  （先頭のcategoryがありません）

```

### 複合インデックスのカラム順序

最適なカラム順序は以下の優先度で決定します。

1. 等値条件（=）のカラム: 最も左に配置します
2. 範囲条件（>, <, BETWEEN）のカラム: 等値の次に配置します
3. ORDER BYのカラム: 範囲条件の次に配置します

```ruby

# クエリ: WHERE category = ? AND price > ? ORDER BY created_at

# 最適なインデックス:

add_index :products, [:category, :price, :created_at]

```

### カバリングインデックス

クエリに必要な全カラムがインデックスに含まれていれば、テーブル本体へのアクセスが不要になります。

```ruby

# SELECT category, price FROM products WHERE category = 'Electronics'

# インデックス(category, price)があればカバリングインデックスとして機能します

add_index :products, [:category, :price]

```

### 部分インデックス（PostgreSQL）

特定条件のレコードのみインデックスに含めます。

```ruby

# activeなレコードのみインデックス化します（インデックスサイズの削減）

add_index :products, :category, where: "active = true", name: "index_active_products_on_category"

```

### インデックスが効かないケース

```ruby

# 中間一致LIKE（先頭が不定）

Product.where("name LIKE ?", "%phone%")

# 関数の適用

Product.where("LOWER(category) = ?", "electronics")

# 否定条件（選択性が低い場合）

Product.where.not(category: "Electronics")

# OR条件（場合による）

Product.where("category = ? OR price > ?", "Electronics", 1000)

# 暗黙の型変換

Product.where("price = ?", "100")  # 文字列と数値の比較

```

## スロークエリ対策

### 1. ActiveSupport::Notificationsによる監視

```ruby

# config/initializers/slow_query_logger.rb

ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
  event = ActiveSupport::Notifications::Event.new(*args)
  if event.duration > 100 # 100ms以上のクエリ
    Rails.logger.warn(
      "[SLOW QUERY] #{event.duration.round(1)}ms: #{event.payload[:sql]}"
    )
  end
end

```

### 2. Query Log Tags（Rails 7+）

```ruby

# config/application.rb

config.active_record.query_log_tags_enabled = true
config.active_record.query_log_tags = [
  :application, :controller, :action, :job
]

# 実行されるSQLに発生元情報がタグ付けされます:

# SELECT * FROM products /* app:MyApp,controller:products,action:index */

```

### 3. strict_loading（Rails 6.1+）

```ruby

# N+1を検出したら例外を発生させます

class Product < ApplicationRecord
  self.strict_loading_by_default = true
end

# または個別のクエリで有効化します

Product.strict_loading.each do |product|
  product.reviews  # => ActiveRecord::StrictLoadingViolationError
end

```

### 4. EXPLAINベースのデバッグワークフロー

```ruby

# Step 1: SQLを確認します

query = Product.where(category: "Electronics").where("price > ?", 100)
puts query.to_sql

# Step 2: クエリプランを確認します

puts query.explain

# Step 3: インデックスを追加します（必要に応じて）

# rails generate migration AddIndexToProducts

# Step 4: 改善を確認します

puts query.explain

```

## クエリプラン最適化

### N+1問題の解決

```ruby

# N+1問題が発生するコード

Product.all.each do |product|
  product.reviews.each { |r| puts r.rating }
end

# → products取得で1クエリ + 各productのreviews取得でNクエリが発行されます

# includesで解決します（2クエリ）

Product.includes(:reviews).each do |product|
  product.reviews.each { |r| puts r.rating }
end

# eager_loadで解決します（LEFT OUTER JOINで1クエリ）

Product.eager_load(:reviews).each do |product|
  product.reviews.each { |r| puts r.rating }
end

```

### EXISTSとCOUNTの使い分け

```ruby

# 非効率: 全件カウントしてから比較します

if Product.where(category: "Electronics").count > 0
  # ...
end

# 効率的: 最初の1件が見つかった時点で停止します

if Product.where(category: "Electronics").exists?
  # ...
end

```

### SELECT句の最小化

```ruby

# 不要なカラムも全て取得しています

products = Product.where(category: "Electronics")

# 必要なカラムだけ取得します（I/O削減）

products = Product.where(category: "Electronics").select(:id, :name, :price)

# pluckで値だけ取得します（ActiveRecordオブジェクト生成を回避）

names = Product.where(category: "Electronics").pluck(:name)

```

### バッチ処理

```ruby

# 全件をメモリに読み込みます

Product.all.each do |product|
  # 大量データでメモリを圧迫します
end

# find_eachでバッチ処理します（デフォルト1000件ずつ）

Product.find_each(batch_size: 500) do |product|
  # 500件ずつ処理します
end

# find_in_batchesでバッチ単位で処理します

Product.find_in_batches(batch_size: 500) do |batch|
  batch.each { |product| # ... }
end

```

### 結合戦略の選択

```ruby

# JOINが適切なケース（フィルタリング用途）

Product.joins(:reviews).where("reviews.rating >= ?", 4).distinct

# includesが適切なケース（関連データの事前読み込み）

Product.includes(:reviews).where("reviews.rating >= ?", 4).references(:reviews)

# サブクエリが適切なケース（存在確認）

Product.where(id: Review.where("rating >= ?", 4).select(:product_id))

```

## 実務での活用場面

### マイグレーションレビュー

新しいインデックスの追加時には以下を確認します。

1. 既存のインデックスと重複していないか確認します: 複合インデックスの先頭が同じ場合、単一インデックスは冗長です
2. 書き込み頻度の高いテーブルか確認します: インデックスが多いとINSERT/UPDATE/DELETEが遅くなります
3. カーディナリティは十分か確認します: boolean型のカラムにインデックスを張っても効果は薄いです
4. 大規模テーブルへの追加か確認します: 本番環境でのインデックス追加は`CONCURRENTLY`オプションを検討してください（PostgreSQL）

```ruby

# PostgreSQLでのロックなしインデックス追加

class AddIndexConcurrently < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_index :products, :category, algorithm: :concurrently
  end
end

```

### パフォーマンス監視の自動化

```ruby

# spec/support/query_counter.rb（テスト環境でのクエリ数監視）

RSpec.configure do |config|
  config.around(:each, :query_limit) do |example|
    queries = []
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
      event = ActiveSupport::Notifications::Event.new(*args)
      queries << event.payload[:sql] unless event.payload[:name] == "SCHEMA"
    end

    example.run

    ActiveSupport::Notifications.unsubscribe(subscription)
    limit = example.metadata[:query_limit]
    expect(queries.size).to be <= limit, "Expected at most #{limit} queries, got #{queries.size}"
  end
end

# テストでの使用

it "N+1が発生しないこと", query_limit: 3 do
  Product.includes(:reviews).each { |p| p.reviews.to_a }
end

```

## 実行方法

```bash

# テストの実行

bundle exec rspec 30_query_plan/query_plan_spec.rb

# 個別のメソッドを試す

ruby -r ./30_query_plan/query_plan -e "pp QueryPlanAnalysis.demonstrate_explain_basics"
ruby -r ./30_query_plan/query_plan -e "pp QueryPlanAnalysis.demonstrate_index_types"
ruby -r ./30_query_plan/query_plan -e "pp QueryPlanAnalysis.demonstrate_n_plus_one_detection"

```
