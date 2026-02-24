# マルチDB構成とシャーディング

## なぜマルチDB構成の理解が重要か

Webアプリケーションの成長に伴い、単一データベースではパフォーマンスやスケーラビリティの限界に直面します。Rails
6.0以降で公式サポートされたマルチデータベース機能は、読み書き分離やホリゾンタルシャーディングをフレームワークレベルで実現します。

シニアエンジニアがマルチDB構成を深く理解すべき理由は以下の通りです。

- スケーラビリティの確保: 読み取り負荷をレプリカに分散し、プライマリDBの負荷を軽減できます
- データ分離: テナントごとにシャードを分けることで、データの物理的な分離とパフォーマンスの最適化が可能です
- 障害耐性: プライマリ障害時にレプリカへのフェイルオーバーが可能な構成を設計できます
- 運用効率: データベースごとのマイグレーション管理、バックアップ戦略を適切に設計できます

## マルチDB構成の仕組み

### database.ymlの構成

マルチDB構成の起点は`database.yml`です。Rails 6.0以降では、1つの環境に対して複数のデータベースを定義できます。

```yaml

production:
  primary:
    database: myapp_production
    host: primary-db.example.com
    adapter: postgresql
    pool: 10
  primary_replica:
    database: myapp_production
    host: replica-db.example.com
    adapter: postgresql
    pool: 10
    replica: true

```

`replica:
true`を指定すると、そのデータベースは読み取り専用として扱われ、書き込み操作（INSERT/UPDATE/DELETE）が自動的にブロックされます。

### connects_toによるモデルの接続宣言

```ruby

class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to database: { writing: :primary, reading: :primary_replica }
end

```

`connects_to`は`ActiveRecord::ConnectionHandling`モジュールで定義されており、
内部的には`ConnectionHandler`にロール別のコネクションプールを登録します。`:writing`と`:reading`はロール（role）
と呼ばれ、`connected_to(role:)`で切り替えます。

### ConnectionHandlerの内部構造

```text

ActiveRecord::ConnectionAdapters::ConnectionHandler
  └── PoolManager
        ├── writing / default → ConnectionPool (primary DB)
        ├── reading / default → ConnectionPool (replica DB)
        ├── writing / shard_one → ConnectionPool (shard1 primary)
        └── reading / shard_one → ConnectionPool (shard1 replica)

```

データベース、ロール、シャードの組み合わせごとに独立したコネクションプールが作成されます。プール間で接続の共有は行われません。

## 読み書き分離

### 自動ロールスイッチング

Railsはミドルウェア`DatabaseSelector`を提供しており、HTTPメソッドに基づいて自動的にロールを切り替えます。

```ruby

# config/application.rb

config.active_record.database_selector = { delay: 2.seconds }
config.active_record.database_resolver =
  ActiveRecord::Middleware::DatabaseSelector::Resolver
config.active_record.database_resolver_context =
  ActiveRecord::Middleware::DatabaseSelector::Resolver::Session

```

動作ロジックは以下の通りです。

| HTTPメソッド | 接続ロール | 説明
| ------------ | ---------- | ------
| GET / HEAD | reading | レプリカから読み取ります
| POST / PUT / DELETE / PATCH | writing | プライマリに書き込みます

### delayパラメータによるレプリケーション遅延対策

`delay:
2.seconds`を設定すると、最後の書き込みから2秒以内の読み取りはプライマリから行われます。これにより、
レプリケーション遅延中に古いデータを返すことを防止します。

```text

書き込み発生 → セッションにタイムスタンプ記録
  ↓
次のGETリクエスト時:
  現在時刻 - タイムスタンプ < delay → プライマリから読みます
  現在時刻 - タイムスタンプ >= delay → レプリカから読みます

```

### connected_toによる明示的切り替え

自動スイッチングに加えて、`connected_to`ブロックで明示的にロールを指定できます。

```ruby

# レポート生成では確実にレプリカを使用します

class ReportsController < ApplicationController
  def show
    ActiveRecord::Base.connected_to(role: :reading) do
      @report = Article.group(:status).count
      @monthly = Article.where("created_at > ?", 1.month.ago).count
    end
  end
end

```

### prevent_writesオプション

`prevent_writes: true`を指定すると、ロールに関係なく書き込みがブロックされます。

```ruby

ActiveRecord::Base.connected_to(role: :writing, prevent_writes: true) do
  Article.count          # => 成功します（読み取りは可能）
  Article.create!(...)   # => ActiveRecord::ReadOnlyErrorが発生します
end

```

## シャーディング戦略

### ホリゾンタルシャーディングとは

ホリゾンタルシャーディングは、同じスキーマのテーブルを複数のデータベースに分散配置する手法です。データ量やアクセス頻度に応じてデータを分割することで、
スケーラビリティを確保します。

### 3つのシャーディング戦略

#### 1. テナントベースシャーディング

SaaSアプリケーションで最も一般的な戦略です。テナント（顧客）ごとにシャードを割り当てます。

```ruby

# database.yml

production:
  primary_shard_one:
    database: myapp_tenant_group_a
    host: shard1-db.example.com
  primary_shard_two:
    database: myapp_tenant_group_b
    host: shard2-db.example.com

```

```ruby

class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to shards: {
    shard_one: { writing: :primary_shard_one, reading: :primary_shard_one_replica },
    shard_two: { writing: :primary_shard_two, reading: :primary_shard_two_replica }
  }
end

```

利点: テナント間のデータ分離が物理レベルで保証されます
注意: テナントの成長が不均一だとホットスポットが発生します

#### 2. 範囲ベースシャーディング

IDの範囲でシャードを決定します。

```ruby

def resolve_shard(user_id)
  case user_id
  when 1..10_000_000 then :shard_one
  when 10_000_001..20_000_000 then :shard_two
  else :shard_three
  end
end

```

利点: シャード決定ロジックが単純です
注意: 新しいデータが最新シャードに集中しやすくなります

#### 3. ハッシュベースシャーディング

キーのハッシュ値でシャードを決定します。

```ruby

def resolve_shard(user_id, shard_count: 3)
  shard_index = Digest::MD5.hexdigest(user_id.to_s).hex % shard_count
  :"shard_#{shard_index}"
end

```

利点: データが均等に分散されます
注意: シャード数の変更時にリバランシングが必要です

### ShardSelectorミドルウェア（Rails 7.1+）

```ruby

# config/application.rb

config.active_record.shard_selector = { lock: true }
config.active_record.shard_resolver = ->(request) {
  tenant = Tenant.find_by(subdomain: request.subdomain)
  tenant&.shard_name&.to_sym || :default
}

```

`lock:
true`を設定すると、ミドルウェアが設定したシャード内で`connected_to(shard:)`による切り替えが禁止されます。これにより、
テナントのデータが意図せず別シャードに書き込まれることを防ぎます。

### クロスシャードクエリ

シャード間のJOINはデータベースレベルでサポートされないため、アプリケーション層で対処します。

```ruby

# 各シャードからデータを収集して統合します

results = []
[:shard_one, :shard_two, :shard_three].each do |shard|
  ActiveRecord::Base.connected_to(shard: shard) do
    results.concat(User.where(active: true).to_a)
  end
end

# 並列実行版

results = Concurrent::Array.new
threads = [:shard_one, :shard_two, :shard_three].map do |shard|
  Thread.new do
    ActiveRecord::Base.connected_to(shard: shard) do
      results.concat(User.where(active: true).to_a)
    end
  end
end
threads.each(&:join)

```

## 大規模DB運用パターン

### マイグレーションの管理

マルチDB構成では、データベースごとにマイグレーションファイルを分離して管理します。

```text

db/
  migrate/                      # プライマリDB用
  shard_one_migrate/            # シャード1用
  shard_two_migrate/            # シャード2用
  schema.rb                     # プライマリのスキーマ
  shard_one_schema.rb           # シャード1のスキーマ

```

```bash

# 全DBのマイグレーション

rails db:migrate

# 特定DBのマイグレーション

rails db:migrate:primary

# マイグレーション生成時にDBを指定します

rails generate migration AddEmailToUsers email:string --database primary

```

### コネクションプールのサイジング

マルチDB構成ではプール数が増えるため、合計コネクション数の管理が重要になります。

```text

合計コネクション数 = Pumaスレッド数 × DB数 × ロール数

例: Puma 5スレッド × 3シャード × 2ロール(writing/reading) = 30コネクション

```

各プールの`pool`設定値はPumaの`max_threads`以上に設定する必要があります。

```yaml

# database.yml

production:
  primary:
    pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
  primary_replica:
    pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>

```

### 監視ポイント

大規模マルチDB運用では以下を継続的に監視します。

| 監視項目 | 説明 | 閾値の目安
| --------- | ------ | -----------
| レプリケーション遅延 | プライマリとレプリカのデータ差分です | 5秒以上で警告します
| コネクションプール使用率 | busy / sizeの割合です | 80%以上で警告します
| シャード間データ偏り | 各シャードのレコード数比率です | 2倍以上の偏りで調査します
| クエリパフォーマンス | シャードごとのP95レスポンスタイムです | シャード間で2倍以上の差で調査します
| 接続タイムアウト | ConnectionTimeoutErrorの発生回数です | 1件でも即座に調査します

### トランザクション設計

マルチDB構成ではクロスDBトランザクションがサポートされないため、データの一貫性を保つ設計パターンが重要になります。

```ruby

# 悪い例: クロスDBトランザクション（サポートされません）

ActiveRecord::Base.transaction do
  ActiveRecord::Base.connected_to(shard: :shard_one) { User.create!(...) }
  ActiveRecord::Base.connected_to(shard: :shard_two) { Order.create!(...) }
  # shard_twoで失敗してもshard_oneはロールバックされません
end

# 良い例: Sagaパターンによる補償トランザクション

def create_order_with_saga(user_params, order_params)
  user = nil
  ActiveRecord::Base.connected_to(shard: :shard_one) do
    user = User.create!(user_params)
  end

  ActiveRecord::Base.connected_to(shard: :shard_two) do
    Order.create!(order_params.merge(user_id: user.id))
  end
rescue => e
  # 補償処理: 先に作成したリソースを削除します
  ActiveRecord::Base.connected_to(shard: :shard_one) do
    user&.destroy
  end
  raise e
end

```

## 実行方法

```bash

# テストの実行

bundle exec rspec 27_multi_db/multi_db_spec.rb

# 個別のメソッドを試す

ruby -r ./27_multi_db/multi_db -e "pp MultiDbSharding::MultipleConnections.demonstrate_connection_config"
ruby -r ./27_multi_db/multi_db -e "pp MultiDbSharding::PracticalPatterns.demonstrate_production_checklist"

```
