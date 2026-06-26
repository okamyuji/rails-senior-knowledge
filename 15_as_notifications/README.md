# ActiveSupport::Notifications - 計装（Instrumentation）システム

## 概要

`ActiveSupport::Notifications`
はRailsに組み込まれたPub/Sub（出版/購読）パターンの計装フレームワークです。アプリケーション内部で発生するイベントを計測・監視し、
パフォーマンスモニタリングやロギングに活用できます。

## 計装（Instrumentation）の仕組み

### 基本的なアーキテクチャ

```text

┌──────────────┐     instrument()     ┌──────────────┐     dispatch     ┌──────────────────┐
│  アプリケーション  │ ──────────────→ │    Fanout     │ ──────────→ │  Subscriber A    │
│  コード         │                   │  (ディスパッチャ) │ ──────────→ │  Subscriber B    │
└──────────────┘                     └──────────────┘             │  Subscriber C    │
                                                                   └──────────────────┘

```

### instrumentとsubscribe

```ruby

# イベントの購読（subscribe）

ActiveSupport::Notifications.subscribe("process_action.action_controller") do |*args|
  event = ActiveSupport::Notifications::Event.new(*args)
  Rails.logger.info "#{event.name} took #{event.duration}ms"
end

# イベントの発行（instrument）

ActiveSupport::Notifications.instrument("custom.event", data: value) do
  # 計測対象の処理
end

```

### Eventオブジェクトの属性

| 属性 | 型 | 説明
| ------ | ------ | ------
| `name` | String | イベント名です（例: "sql.active_record"）
| `time` | Float | イベント開始時刻です（**Float秒**。通常subscribeは壁時計epoch秒、monotonic_subscribeはモノトニック秒。単一引数 `\|event\|` 形式は常にモノトニック秒）
| `end` | Float | イベント終了時刻です（`time`と同じ時計種別・単位）
| `duration` | Float | 所要時間（**ミリ秒**）。`@end - @time`（内部はms保持）
| `transaction_id` | String | ユニークなトランザクションIDです
| `payload` | Hash | イベントに付随する任意のデータです

> 注: `time` と `end` は秒、`duration` はミリ秒です（単位が異なります）。Rails 8.1 / ActiveSupport 8.1 でも内部ストレージはミリ秒ですが、`#time` / `#end` のゲッタが 1000.0 で割って秒として返します（`activesupport/lib/active_support/notifications/instrumenter.rb` の `Event#time`）。

### 通常subscribe vs monotonic subscribe

ActiveSupport::Notifications には2つの計測モードがあり、5引数形式 `|name, start, finish, id, payload|` の `start` / `finish` の型と、内部の時計種別が変わります。**最上位の `subscribe` は `monotonic:` キーワードを受け取りません**（受け取るのは下位の `Fanout#subscribe` と `subscribed(callback, pattern, monotonic:)` のみ）。

```ruby

# 1. 通常モード（壁時計、デフォルト）
# 5引数: start / finish は Time オブジェクト
ActiveSupport::Notifications.subscribe("sql.active_record") do |name, start, finish, id, payload|
  start.class    # => Time
  finish.class   # => Time
end

# 単一引数 |event| 形式は EventObject サブスクライバとなり、内部で
# Process.clock_gettime(MONOTONIC, :float_millisecond) を使うため、`event.time` は
# 常にモノトニック秒（Float）です。
ActiveSupport::Notifications.subscribe("sql.active_record") do |event|
  event.time     # => Float (モノトニック秒)
  event.duration # => Float (ミリ秒)
end

# 2. monotonic_subscribe（モノトニック時計）
# 5引数: start / finish は Float モノトニック秒
ActiveSupport::Notifications.monotonic_subscribe("sql.active_record") do |name, start, finish, id, payload|
  start.class    # => Float
end

# 単一引数 |event| 形式でも当然モノトニック秒が得られます
ActiveSupport::Notifications.monotonic_subscribe("sql.active_record") do |event|
  event.time     # => Float (モノトニック秒)
end

```

`duration` は常にミリ秒で得られます（Event内部はミリ秒で保持されており、getter `#time` / `#end` のみ秒に変換します）。`time` を「実際に起きた絶対時刻」として記録したいログ系では通常モード5引数形式、タイマー類の経過時間記録では `monotonic_subscribe` を選びます。

```ruby

# 参考: 直接モノトニック時計を取得する標準API
Process.clock_gettime(Process::CLOCK_MONOTONIC)

```

## カスタムイベント追加方法

### 命名規則

Railsのイベントは `"動作.コンポーネント"` の形式で命名されます。カスタムイベントも同じ規則に従うことを推奨します。

```ruby

# 推奨: 動作.名前空間

"search.my_app"
"checkout.payment_service"
"sync.external_api"

# 非推奨: 名前空間なし

"search"
"checkout"

```

### 実装パターン

```ruby

# サービスオブジェクトに計装を追加する例

class UserSearchService
  def search(query)
    ActiveSupport::Notifications.instrument("search.user_service", query: query) do |payload|
      results = User.where("name LIKE ?", "%#{query}%").to_a
      payload[:result_count] = results.size
      payload[:status] = :success
      results
    end
  rescue => e
    ActiveSupport::Notifications.instrument("error.user_service",
      error_class: e.class.name,
      message: e.message
    )
    raise
  end
end

```

### ペイロードの動的変更

`instrument` のブロック引数としてペイロードハッシュが渡されます。処理結果に基づいて追加情報を記録できます。

```ruby

ActiveSupport::Notifications.instrument("process.my_app", input: data) do |payload|
  result = expensive_operation(data)
  payload[:output_size] = result.size
  payload[:cached] = false
  result
end

```

## パフォーマンスモニタリング

### Rails組み込みイベント一覧

#### Action Controller

- `process_action.action_controller` - コントローラーアクションを実行します
- `start_processing.action_controller` - アクション処理を開始します
- `redirect_to.action_controller` - リダイレクトを実行します
- `halted_callback.action_controller` - コールバックで処理を中断します

#### Active Record

- `sql.active_record` - SQLクエリを実行します（クエリ文字列、バインド値を含みます）
- `instantiation.active_record` - ARオブジェクトをインスタンス化します

#### Action View

- `render_template.action_view` - テンプレートをレンダリングします
- `render_partial.action_view` - パーシャルをレンダリングします
- `render_collection.action_view` - コレクションをレンダリングします

#### Active Support

- `cache_read.active_support` - キャッシュを読み取ります
- `cache_write.active_support` - キャッシュに書き込みます

#### Active Job

- `enqueue.active_job` - ジョブをキューイングします
- `perform.active_job` - ジョブを実行します

### パターンマッチング購読

正規表現を使って複数のイベントを一括購読できます。

```ruby

# 全Active Recordイベントを購読します

ActiveSupport::Notifications.subscribe(/\.active_record$/) do |*args|
  event = ActiveSupport::Notifications::Event.new(*args)
  SlowQueryLogger.log(event) if event.duration > 100
end

# アプリケーション固有のイベントをすべて購読します

ActiveSupport::Notifications.subscribe(/^app\./) do |*args|
  event = ActiveSupport::Notifications::Event.new(*args)
  MetricsCollector.record(event)
end

```

### LogSubscriberによる構造化ロギング

```ruby

# カスタムLogSubscriberの実装

class PaymentLogSubscriber < ActiveSupport::LogSubscriber
  def process(event)
    info do
      "Payment processed in #{event.duration.round(1)}ms " \
        "[#{event.payload[:gateway]}] " \
        "amount=#{event.payload[:amount]}"
    end
  end

  def error(event)
    error do
      "Payment failed: #{event.payload[:error_message]} " \
        "[#{event.payload[:gateway]}]"
    end
  end
end

# サブスクライバーをアタッチします

PaymentLogSubscriber.attach_to :payment_service

```

## APMツール統合

### APM（Application Performance Monitoring）ツールとの連携

RailsのNotificationsシステムは、APMツールが自動的に購読する仕組みを提供しています。

#### New Relic

```ruby

# New Relic Agentは自動的に以下のイベントを購読します

# - process_action.action_controller

# - sql.active_record

# - render_template.action_view

# カスタムイベントの追加は以下のようにします

ActiveSupport::Notifications.subscribe("custom.event") do |*args|
  event = ActiveSupport::Notifications::Event.new(*args)
  NewRelic::Agent.record_custom_event("CustomEvent",
    duration: event.duration,
    **event.payload
  )
end

```

#### Datadog

```ruby

# Datadogはdd-trace-rb gemで自動計装を提供します

# カスタムスパンの追加は以下のようにします

ActiveSupport::Notifications.subscribe("app.heavy_process") do |*args|
  event = ActiveSupport::Notifications::Event.new(*args)
  Datadog::Tracing.trace("app.heavy_process") do |span|
    span.set_tag("duration_ms", event.duration)
    span.set_tag("result_count", event.payload[:result_count])
  end
end

```

#### Sentry

```ruby

# Sentryはパフォーマンストランザクションに計装データを含めます

# カスタムスパンの追加は以下のようにします

ActiveSupport::Notifications.subscribe("app.external_api") do |*args|
  event = ActiveSupport::Notifications::Event.new(*args)
  Sentry.with_scope do |scope|
    scope.set_context("instrumentation", {
      event_name: event.name,
      duration_ms: event.duration,
      payload: event.payload
    })
  end
end

```

### パフォーマンスに関する注意事項

1. サブスクライバーなしのオーバーヘッドについて: `instrument` はサブスクライバーがなければ極めて低コストです
2. 同期実行について: サブスクライバーは同期的に実行されるため、重い処理は非同期キューに委譲します
3. 正規表現購読のコストについて: 文字列マッチングより若干コストが高いですが、通常は無視できるレベルです
4. メモリリーク防止について: 不要なサブスクライバーは `unsubscribe` で必ず解除します

```ruby

# 悪い例: サブスクライバーが蓄積します

class SomeController < ApplicationController
  before_action :setup_monitoring

  def setup_monitoring
    # リクエストのたびにサブスクライバーが追加されます（メモリリーク）
    ActiveSupport::Notifications.subscribe("sql.active_record") { |*args| ... }
  end
end

# 良い例: イニシャライザで一度だけ登録します

# config/initializers/notifications.rb

ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
  event = ActiveSupport::Notifications::Event.new(*args)
  SlowQueryMonitor.check(event) if event.duration > 100
end

```

## Rails 8.1 新機能: 構造化イベントレポーター（Rails.event）

Rails 8.1では `ActiveSupport::Notifications` とは別に、機械可読な構造化イベントを発行するための新APIとして
`ActiveSupport::EventReporter` が導入されました。`Rails.event` 経由でアクセスでき、
ログ（人間向け）と分離した「機械向けイベント」を統一的に発行する用途を目指しています。

```ruby

# 構造化イベントの発行
Rails.event.notify("user.signup", user_id: 123, email: "alice@example.com")

# タグ付け（イベントに共通コンテキストを付与）
Rails.event.tagged("graphql") do
  Rails.event.notify("query.executed", duration_ms: 12.3)
end

# コンテキストの設定（Fiber-localで保持）
Rails.event.set_context(request_id: "abc-123")

```

サブスクライバーは `#emit(event)` を実装したオブジェクトを登録します。Rails 8.1の `ActiveSupport::EventReporter` は `event` を **Hashとしてサブスクライバーに渡します**（メソッド呼び出しではなくキーアクセスを使用）。Hashのキーは `:name` `:payload` `:tags` `:context` `:timestamp` `:source_location` です。

```ruby

class JsonEventSubscriber
  def emit(event)
    payload = {
      name: event[:name],
      payload: event[:payload],
      tags: event[:tags],
      context: event[:context],
      timestamp: event[:timestamp],
      source_location: event[:source_location]
    }
    Rails.logger.info(payload.to_json)
  end
end

Rails.event.subscribe(JsonEventSubscriber.new)

```

`ActiveSupport::Notifications` との使い分けは以下の通りです。

| 用途 | 推奨API
| ------ | ------
| パフォーマンス計装（duration計測） | `ActiveSupport::Notifications.instrument`
| 構造化イベントの発行（ビジネスイベント、監査） | `Rails.event.notify`
| APMやログ収集ツールへの統合 | 両方が併用可能

設定は `config.active_support.event_reporter_context_store` で
コンテキストストア（デフォルトは `ActiveSupport::EventContext`、Fiber-local）を切り替えられます。

詳細は [Rails 8.1 リリースノート](https://guides.rubyonrails.org/8_1_release_notes.html#structured-event-reporting)
を参照してください。

## 実行方法

```bash

# テストの実行

bundle exec rspec 15_as_notifications/as_notifications_spec.rb

# 特定のテストのみ実行します

bundle exec rspec 15_as_notifications/as_notifications_spec.rb -e "subscribe"

```

## 参考資料

- [Active Support Instrumentation (Rails
  Guides)](https://guides.rubyonrails.org/active_support_instrumentation.html)
- [ActiveSupport::Notifications
  API](https://api.rubyonrails.org/classes/ActiveSupport/Notifications.html)
- [ActiveSupport::LogSubscriber
  API](https://api.rubyonrails.org/classes/ActiveSupport/LogSubscriber.html)
