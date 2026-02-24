# N+1クエリ問題の検出と防止

## なぜN+1問題の理解が重要か

N+1クエリ問題は、Railsアプリケーションにおけるパフォーマンス劣化の最も一般的な原因です。一見正常に動作するコードが、
データ量の増加に伴い線形的にクエリ数が増大し、レスポンスタイムを著しく悪化させます。

シニアエンジニアがN+1問題を深く理解すべき理由は以下の通りです。

- パフォーマンスの予測能力: コードレビュー段階でN+1問題を発見し、本番環境での障害を未然に防ぎます
- 適切な最適化戦略の選択: includes / preload / eager_loadの特性を理解し、状況に応じた最適な手法を選択します
- 防御的プログラミング: strict_loadingを活用して、N+1が発生しうるコードパスを開発段階で検出します
- 大規模データの取り扱い: バッチ処理パターンを組み合わせて、メモリ効率とクエリ効率を両立します

## N+1問題の仕組みと影響

### N+1問題とは

N+1問題は、親レコードを取得する1回のクエリに加え、各親レコードの関連レコードを個別に取得するN回のクエリが発行される問題です。

```ruby

# N+1問題の典型例

# 著者が100人いる場合、101回のSQLクエリが発行されます

authors = Author.all                    # 1回: SELECT * FROM authors
authors.each do |author|
  puts author.books.map(&:title)        # N回: SELECT * FROM books WHERE author_id = ?
end

```

### 影響の深刻さ

| データ量 | 遅延ロード | Eager Loading | 差分
| --------- | ----------- | -------------- | ------
| 10件 | 11クエリ | 2クエリ | 9クエリ
| 100件 | 101クエリ | 2クエリ | 99クエリ
| 1,000件 | 1,001クエリ | 2クエリ | 999クエリ
| 10,000件 | 10,001クエリ | 2クエリ | 9,999クエリ

各クエリにはネットワークラウンドトリップのオーバーヘッドがあるため、データ量に比例してレスポンスタイムが悪化します。

### クエリカウントの計測方法

ActiveSupport::Notificationsを使ってクエリ数を計測できます。

```ruby

def count_queries(&block)
  count = 0
  counter = lambda do |_name, _start, _finish, _id, payload|
    unless payload[:name] == "SCHEMA" ||
           payload[:sql].match?(/\A\s*(BEGIN|COMMIT|ROLLBACK)/i)
      count += 1
    end
  end
  ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
  count
end

# 使用例

lazy_count = count_queries { Author.all.each { |a| a.books.to_a } }
eager_count = count_queries { Author.includes(:books).each { |a| a.books.to_a } }

```

## includes / preload / eager_loadの使い分け

### 3つの戦略の比較

| 戦略 | SQL手法 | クエリ数 | WHERE句で関連参照 | メモリ効率
| ------ | -------- | --------- | ----------------- | -----------
| `preload` | 別クエリ + IN句 | 2回 | できません | 良いです
| `eager_load` | LEFT OUTER JOIN | 1回 | 可能です | JOINで膨張します
| `includes` | 自動選択 | 状況次第 | references併用で可能です | 状況次第です

### preload（別クエリ戦略）

```ruby

Author.preload(:books)

# 発行されるSQL:

# SELECT "authors".* FROM "authors"

# SELECT "books".* FROM "books" WHERE "books"."author_id" IN (1, 2, 3)

```

メリットは以下の通りです。

- 各テーブルのインデックスを最大限に活用できます
- JOINによるデータ膨張がありません

デメリットは以下の通りです。

- WHERE句で関連テーブルのカラムを参照できません

### eager_load（LEFT OUTER JOIN戦略）

```ruby

Author.eager_load(:books)

# 発行されるSQL:

# SELECT "authors"."id" AS t0_r0, "authors"."name" AS t0_r1, ...

#   "books"."id" AS t1_r0, "books"."title" AS t1_r1, ...

# FROM "authors"

# LEFT OUTER JOIN "books" ON "books"."author_id" = "authors"."id"

```

メリットは以下の通りです。

- WHERE句で関連テーブルのカラムを参照できます
- 1つのクエリで完結します

デメリットは以下の通りです。

- JOINによるデータの重複（カーテシアン積）が発生します
- 多段階のJOINでデータ量が爆発的に増加する可能性があります

### includes（自動選択）

```ruby

# 単純な場合 → preloadと同じ挙動（別クエリ）

Author.includes(:books)

# WHERE句で関連テーブルを参照する場合 → eager_loadと同じ挙動（JOIN）

Author.includes(:books).where(books: { title: "Rails入門" }).references(:books)

```

### 選択の指針

```text

関連テーブルのカラムでフィルタリングが必要か？
  ├── はい → eager_loadまたはincludes + references
  └── いいえ → preloadまたはincludes
         ├── 関連レコードが大量 → preload（JOINの膨張を回避します）
         └── 通常 → includes（自動選択に任せます）

```

### ネストした関連のEager Loading

```ruby

# Author → Books → Reviewsの3階層を一括ロードします

Author.includes(books: :reviews)

# 複数の関連を同時に指定します

Author.includes(:books, :profile)

# ネストと複数の組み合わせも可能です

Author.includes(books: [:reviews, :categories])

```

## strict_loadingによる防止

### strict_loadingの種類

Rails 6.1で導入されたstrict_loadingは、N+1問題を開発段階で検出するための仕組みです。

#### 1. スコープレベル

```ruby

# 全関連で遅延ロードを禁止します

authors = Author.strict_loading.all
authors.first.books  # => ActiveRecord::StrictLoadingViolationError

```

#### 2. インスタンスレベル

```ruby

author = Author.first
author.strict_loading!
author.books  # => ActiveRecord::StrictLoadingViolationError

```

#### 3. モデルレベル（デフォルト設定）

```ruby

class Author < ApplicationRecord
  self.strict_loading_by_default = true
  has_many :books
end

Author.first.books  # => ActiveRecord::StrictLoadingViolationError

```

#### 4. 関連レベル

```ruby

class Author < ApplicationRecord
  has_many :books, strict_loading: true
end

Author.first.books  # => ActiveRecord::StrictLoadingViolationError

# preloadで事前読み込みすればアクセス可能です

Author.includes(:books).first.books  # => 正常にアクセスできます

```

### strict_loadingの活用戦略

```ruby

# 開発・テスト環境でのみ有効化する例

class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true

  if Rails.env.development? || Rails.env.test?
    self.strict_loading_by_default = true
  end
end

# 明示的にEager Loadingを指定します

class AuthorsController < ApplicationController
  def index
    @authors = Author.includes(:books).strict_loading
  end
end

```

## クエリ最適化戦略

### バッチ処理パターン

大量のレコードを処理する場合、全件を一度にメモリに読み込むのは危険です。

```ruby

# 危険: 全件をメモリに読み込みます

Author.all.each { |author| process(author) }

# 安全: バッチ単位で処理します（デフォルト1000件ずつ）

Author.find_each { |author| process(author) }

# バッチサイズの指定もできます

Author.find_each(batch_size: 500) { |author| process(author) }

# バッチ単位で配列として受け取ります

Author.find_in_batches(batch_size: 500) do |batch|
  batch.each { |author| process(author) }
end

# Relationとして受け取ります（update_all等と組み合わせ可能）

Author.in_batches(of: 500) do |relation|
  relation.update_all(processed: true)
end

```

### size / count / lengthの使い分け

```ruby

# count: 常にCOUNTクエリを発行します

author.books.count   # SELECT COUNT(*) FROM books WHERE author_id = ?

# length: 全件をロードしてRuby側でカウントします

author.books.length  # SELECT * FROM books WHERE author_id = ?  → .size

# size: ロード状態に応じて最適な方を選択します

# 未ロード時 → COUNTクエリ

# ロード済み時 → メモリ上のサイズ（追加クエリなし）

author.books.size

```

Eager Loading済みの場合は`size`を使用することを推奨します。

### pluckによる最適化

```ruby

# N+1: 各著者のbooks全体をロードしています

Author.all.each { |a| a.books.map(&:title) }

# 最適化: JOINSとpluckで1クエリに集約します

Book.joins(:author).pluck("authors.name", "books.title")

```

### N+1検出ツール

#### Bullet gem

```ruby

# Gemfile

group :development do
  gem "bullet"
end

# config/environments/development.rb

config.after_initialize do
  Bullet.enable = true
  Bullet.alert = true          # ブラウザアラート
  Bullet.bullet_logger = true  # ログファイル出力
  Bullet.rails_logger = true   # Railsログ出力
  Bullet.raise = true          # テスト時に例外を発生させます
end

```

Bullet gemの内部的な仕組みは以下の通りです。

1. `ActiveSupport::Notifications`で`sql.active_record`イベントを購読します
2. 発行されたクエリのパターンを分析します
3. 同じテーブルへの同一パターンのクエリが繰り返される場合にN+1と判定します
4. 未使用のEager Loadingも検出します（不要なincludesの警告）

## 実行方法

```bash

# テストの実行

bundle exec rspec 26_n_plus_one/n_plus_one_spec.rb

# 個別のメソッドを試す

ruby -r ./26_n_plus_one/n_plus_one -e "pp NPlusOneDetection.demonstrate_n_plus_one_problem"

```
