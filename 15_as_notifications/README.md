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
| `time` | Float | イベント開始時刻です（ActiveSupport 8.xではモノトニック時計の値）
| `end` | Float | イベント終了時刻です（ActiveSupport 8.xではモノトニック時計の値）
| `duration` | Float | 所要時間をミリ秒で表します
| `transaction_id` | String | ユニークなトランザクションIDです
| `payload` | Hash | イベントに付随する任意のデータです

### モノトニック時計による正確な計測

Railsはイベントのduration計測にモノトニック時計（`Process::CLOCK_MONOTONIC`）を使用します。壁時計（`Time.now`）
と異なり、NTPによる時刻補正の影響を受けず、常に単調増加するため、正確な経過時間の計測に適しています。

```ruby

# 壁時計: NTP補正で巻き戻る可能性があります

Time.now

# モノトニック時計: 常に単調増加します（Rails内部で使用されています）

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
