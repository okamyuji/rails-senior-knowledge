# Block, Proc, Lambda - Rubyのクロージャを極める

## 概要

Rubyには「無名関数」を扱う3つの仕組みがあります。それぞれの特性を正確に理解することは、Railsのコールバック設計やDSL構築において不可欠です。

| 特性 | Block | Proc | Lambda
| ------ | ------- | ------ | --------
| オブジェクトか | No（構文要素） | Yes | Yes（Procのサブタイプ）
| 引数チェック | 寛容 | 寛容 | 厳密
| returnの挙動 | 囲むメソッドを抜ける | 囲むメソッドを抜ける | Lambda内で完結
| 生成方法 | `do...end` / `{...}` | `Proc.new` | `lambda {}` / `->{}`

## いつ何を使うべきか

### Blockを使うべき場面

- イテレーション: `each`, `map`, `select`などのメソッドに処理を渡します
- リソース管理: `File.open`のようにブロック終了時にクリーンアップします
- 一度きりの処理: その場限りで名前を付ける必要がない処理に使います

```ruby

# リソース管理パターン（Railsでも頻出）

ActiveRecord::Base.transaction do
  user.save!
  order.save!
end

```

### Procを使うべき場面

- コールバックの保存: 後で呼び出すためにブロックをオブジェクトとして保持します
- 柔軟な引数処理: 引数の過不足を許容したい場合に使います
- メソッド間のブロック転送: `&block`で受け取って別メソッドに渡します

```ruby

# コールバックパターン

class EventEmitter
  def initialize
    @listeners = Hash.new { |h, k| h[k] = [] }
  end

  def on(event, &block)
    @listeners[event] << block
  end

  def emit(event, *args)
    @listeners[event].each { |callback| callback.call(*args) }
  end
end

```

### Lambdaを使うべき場面

- 引数の厳密なチェックが必要な場合: バグの早期発見につながります
- メソッドのように振る舞わせたい場合: `return`がメソッドを抜けない安全性があります
- 関数型プログラミング: カリー化や高階関数として使います
- Railsのスコープ定義に使います

```ruby

class Article < ApplicationRecord
  scope :published, -> { where(published: true) }
  scope :recent, ->(days = 7) { where("created_at >= ?", days.days.ago) }
end

```

## DSL構築パターン

Railsの多くの機能はBlockを活用したDSL（ドメイン固有言語）で構築されています。

### instance_evalパターン

ブロック内の`self`を変更して、レシーバのコンテキストで実行します。

```ruby

class Configuration
  attr_accessor :host, :port, :timeout

  def initialize(&block)
    @host = "localhost"
    @port = 3000
    @timeout = 30
    instance_eval(&block) if block_given?
  end
end

config = Configuration.new do
  self.host = "production.example.com"
  self.port = 443
  self.timeout = 60
end

```

### yield selfパターン

`instance_eval`より安全な方法です。ブロック引数として設定オブジェクトを渡します。

```ruby

class AppConfig
  attr_accessor :database_url, :redis_url, :secret_key

  def self.configure
    config = new
    yield(config)
    config
  end
end

# Railsのinitializerでよく見るパターン

AppConfig.configure do |config|
  config.database_url = ENV["DATABASE_URL"]
  config.redis_url = ENV["REDIS_URL"]
end

```

### ネストしたDSL

```ruby

class Router
  attr_reader :routes

  def initialize
    @routes = []
  end

  def namespace(prefix, &block)
    nested = Router.new
    nested.instance_eval(&block)
    nested.routes.each do |route|
      @routes << route.merge(path: "/#{prefix}#{route[:path]}")
    end
  end

  def get(path, to:)
    @routes << { method: :get, path: path, controller: to }
  end
end

# Railsのroutes.rbと同じ発想

router = Router.new
router.namespace(:api) do
  get "/users", to: "users#index"
  get "/posts", to: "posts#index"
end

```

## コールバック設計のベストプラクティス

### Railsのコールバックの仕組み

Railsのコールバック（`before_action`, `after_save`など）は内部的にProc/Lambdaを活用しています。

```ruby

class Order < ApplicationRecord
  # シンボル: メソッド名を指定
  before_save :calculate_total

  # Lambda: インラインで条件を指定
  before_save :apply_discount, if: -> { total > 10_000 }

  # Block: 簡潔な処理をインラインで
  after_create do
    NotificationService.notify_new_order(self)
  end

  private

  def calculate_total
    self.total = line_items.sum(&:subtotal)
  end

  def apply_discount
    self.total *= 0.9
  end
end

```

### コールバックチェーンの設計指針

1. シンプルさを保つ: 1つのコールバックに複数の責務を持たせないでください
2. 副作用の制御: コールバック内で外部APIを呼ぶなら`after_commit`を使います
3. テスタビリティ: コールバックのロジックを別メソッド/クラスに切り出します
4. 順序依存の回避: コールバック間で暗黙の実行順序に依存しないでください

```ruby

# 悪い例: 1つのコールバックに複数の責務

after_save do
  update_inventory
  send_notification
  sync_to_external_api
end

# 良い例: 責務を分離

after_save :update_inventory
after_commit :send_notification
after_commit :sync_to_external_api

```

## メモリリーク防止

### クロージャによるメモリリークのメカニズム

クロージャは定義時のスコープ全体への参照を保持します。これにより、意図せず大きなオブジェクトがGC（ガベージコレクション）されない状況が発生します。

```ruby

# 危険なパターン

def create_handler
  large_data = load_huge_dataset  # 巨大なデータ
  small_value = large_data.count

  # このLambdaはlarge_dataへの参照を保持し続ける
  -> { "処理済み: #{small_value}件" }
end

# 安全なパターン

def create_handler
  large_data = load_huge_dataset
  small_value = large_data.count
  large_data = nil  # 明示的に参照を切る

  -> { "処理済み: #{small_value}件" }
end

```

### Railsでの典型的なメモリリークパターン

#### 1. コントローラでのクロージャ保持

```ruby

# 危険: リクエストごとにLambdaが生成され、参照が残る可能性

class ReportsController < ApplicationController
  def index
    @data = HeavyReport.generate  # 巨大なデータ

    # このLambdaが@dataへの参照を保持
    @formatter = ->(row) { format_row(row, @data.metadata) }
  end
end

# 改善: 必要なデータだけを抽出

class ReportsController < ApplicationController
  def index
    data = HeavyReport.generate
    metadata = data.metadata  # 必要な部分だけ取得

    @rows = data.rows
    @formatter = ->(row) { format_row(row, metadata) }
  end
end

```

#### 2. コールバック登録の解除漏れ

```ruby

# 危険: unsubscribeしないとオブジェクトがGCされない

class OrderObserver
  def initialize(event_bus)
    @callback = ->(order) { process(order) }
    event_bus.subscribe(:order_created, @callback)
    # event_busが@callback（とそこから辿れるself）への参照を保持し続ける
  end
end

# 改善: 明示的な解除メカニズムを用意する

class OrderObserver
  def initialize(event_bus)
    @event_bus = event_bus
    @callback = ->(order) { process(order) }
    @event_bus.subscribe(:order_created, @callback)
  end

  def teardown
    @event_bus.unsubscribe(:order_created, @callback)
  end
end

```

#### 3. メモ化とクロージャの組み合わせ

```ruby

# 注意: メモ化された値がクロージャ経由で大きなオブジェクトを保持

class DataProcessor
  def initialize(source)
    @source = source
  end

  def processor
    # @sourceが巨大だと、このProcが保持するbinding経由で
    # @sourceがGCされなくなる
    @processor ||= Proc.new { |item| transform(item, @source.config) }
  end

  # 改善版
  def safe_processor
    config = @source.config  # 必要な部分だけ取り出す
    @safe_processor ||= Proc.new { |item| transform(item, config) }
  end
end

```

## パフォーマンスの考慮

| 呼び出し方法 | 相対速度 | 用途
| ------------- | --------- | ------
| `yield` | 最速 | 単純なブロック呼び出し
| `block.call` | やや遅い | ブロックの保存・転送が必要な場合
| `Proc#call` | `block.call`と同等 | Procオブジェクトの呼び出し
| `Lambda#call` | `Proc#call`と同等 | 厳密な引数チェックが必要な場合
| `method(:name).call` | 最も遅い | メソッドオブジェクト経由の呼び出し

`yield`が最速な理由は、Procオブジェクトの生成を伴わないためです。パフォーマンスが重要な場面（ループ内で大量に呼ばれるメソッドなど）では`yield`を優先しましょう。

## テストの実行

```bash

bundle exec rspec 03_block_proc_lambda/block_proc_lambda_spec.rb

```
