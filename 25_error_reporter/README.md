# 25. Rails Error Reporter API - エラー報告の統一インターフェース

## 概要

Rails Error ReporterはRails 7.0で導入されたエラー報告の統一APIです。
`Rails.error.handle`、`Rails.error.record`、`Rails.error.report`の3つのメソッドを通じて、
アプリケーション内のエラーを外部監視サービス（Sentry、Bugsnag、Honeybadgerなど）に
一貫した方法で報告できます。

## なぜError Reporterの理解が重要か

シニアRailsエンジニアがError Reporterを深く理解すべき理由は以下の通りです。

- エラー処理戦略の標準化: handle / record / reportの使い分けにより、チーム内でエラー処理の方針を統一できます
- 監視サービスの抽象化: サブスクライバパターンにより、SentryからBugsnagへの移行などが容易になります
- コンテキスト情報の一元管理: ユーザーID、リクエストIDなどの情報をエラーレポートに自動的に付与できます
- マルチサービス対応: 複数の監視サービスを同時に利用できるため、サービスの評価や移行期間にも対応できます

## handle / record / reportの使い分け

### handle - 例外を握りつぶして報告する

ブロック内で発生した例外を捕捉し、サブスクライバに報告した上で`nil`（またはフォールバック値）を返します。
処理は中断されません。デフォルトのseverityは`:warning`です。

```ruby

# 基本形: 失敗してもnilを返して処理を継続します

Rails.error.handle do
  ExternalApi.fetch_data
end

# フォールバック値を指定します

recommendations = Rails.error.handle(fallback: []) do
  RecommendEngine.fetch(user)
end

# => 例外時は[]が返ります

# 特定の例外クラスのみキャッチします

Rails.error.handle(Timeout::Error, fallback: cached_result) do
  SlowService.call
end

```

適切な使用場面は以下の通りです。

- レコメンドやサイドバーなど、失敗しても主要機能に影響しない処理
- キャッシュの更新やプリフェッチ
- 通知メールの送信（失敗しても注文処理は完了させたい場合）
- 外部API連携で、フォールバック値で代替できる場合

### record - 例外を報告してから再送出する

ブロック内で発生した例外をサブスクライバに報告した後、同じ例外を再度`raise`します。
デフォルトのseverityは`:error`です。

```ruby

# 報告した後、例外は呼び出し元に伝播します

Rails.error.record do
  PaymentService.charge!(order)
end

# コンテキスト付きで記録します

Rails.error.record(context: { order_id: order.id }) do
  CriticalService.process!(data)
end

```

適切な使用場面は以下の通りです。

- 決済処理やデータ書き込みなど、失敗を無視できない致命的な処理
- トランザクション境界でのエラー記録
- ミドルウェアでのエラーロギング
- 呼び出し元にも例外を伝播させたい場合

### report - 例外オブジェクトを直接報告する

既に`rescue`で捕捉済みの例外を、ブロックなしで直接報告します。Rails 7.1で追加されました。

```ruby

begin
  risky_operation
rescue SpecificError => e
  # 独自のハンドリングを行いつつ、報告もします
  log_locally(e)
  Rails.error.report(e, handled: true, severity: :warning)
  use_fallback_value
end

```

適切な使用場面は以下の通りです。

- 独自のrescueロジックと組み合わせたい場合
- 条件付きでエラーを報告したい場合
- 複数のrescue節で異なるseverityで報告したい場合

### 使い分けフローチャート

```text

例外が発生した場合、処理を継続できるか？
├── はい → handleを使用します（severity: :warning）
│         └── フォールバック値が必要か？ → fallback:を指定します
└── いいえ → 例外を呼び出し元に伝播させたいか？
              ├── はい → recordを使用します（severity: :error）
              └── いいえ（独自にrescue済み） → reportを使用します

```

## サブスクライバインターフェース

### 基本インターフェース

Error Reporterのサブスクライバは`report`メソッドを実装する必要があります。

```ruby

class MyErrorSubscriber
  def report(error, handled:, severity:, context:, source: "application")
    # error    : 例外オブジェクト（StandardErrorのサブクラス）
    # handled  : handleで捕捉された場合true、recordの場合false
    # severity : :error, :warning, :infoのいずれか
    # context  : ユーザー情報やリクエスト情報などのHash
    # source   : エラーの発生源を示す文字列
  end
end

```

### 監視サービスとの統合例

#### Sentry

```ruby

class SentrySubscriber
  def report(error, handled:, severity:, context:, source: "application")
    Sentry.with_scope do |scope|
      scope.set_tags(handled: handled.to_s, source: source)
      scope.set_context("rails_error_reporter", context)

      case severity
      when :error
        Sentry.capture_exception(error)
      when :warning
        scope.set_level(:warning)
        Sentry.capture_exception(error)
      when :info
        scope.set_level(:info)
        Sentry.capture_message(error.message)
      end
    end
  end
end

```

#### Bugsnag

```ruby

class BugsnagSubscriber
  def report(error, handled:, severity:, context:, source: "application")
    Bugsnag.notify(error) do |event|
      event.severity = severity.to_s
      event.add_metadata(:context, context)
      event.add_metadata(:rails, { handled: handled, source: source })
      event.unhandled = !handled
    end
  end
end

```

#### Honeybadger

```ruby

class HoneybadgerSubscriber
  def report(error, handled:, severity:, context:, source: "application")
    Honeybadger.notify(error, {
      context: context.merge(handled: handled, source: source),
      tags: severity.to_s
    })
  end
end

```

### 登録方法

```ruby

# config/initializers/error_reporting.rb

Rails.error.subscribe(SentrySubscriber.new)
Rails.error.subscribe(DatadogSubscriber.new)  # 複数サービスの同時利用が可能です

```

## コンテキスト情報の活用

### set_contextによるスレッドコンテキスト

```ruby

# ApplicationControllerのbefore_actionで設定します

class ApplicationController < ActionController::Base
  before_action :set_error_context

  private

  def set_error_context
    Rails.error.set_context(
      user_id: current_user&.id,
      request_id: request.uuid,
      ip_address: request.remote_ip,
      user_agent: request.user_agent
    )
  end
end

```

### メソッド呼び出し時のコンテキスト

```ruby

# handle / record / reportのcontext引数でアクション固有の情報を追加します

Rails.error.handle(context: { action: "checkout", cart_id: cart.id }) do
  InventoryService.reserve!(cart.items)
end

```

### コンテキストの注意点

- 個人情報に注意してください: パスワードやクレジットカード番号をコンテキストに含めてはなりません
- サイズの制限があります: 巨大なオブジェクトをコンテキストに入れると、監視サービスのペイロード制限に抵触します
- シリアライズ可能性を確認してください: コンテキストの値はJSONシリアライズ可能な型に限定するのが安全です

## severityレベルの設計指針

| severity | 意味 | 使用場面 | アラート設定の目安
| ---------- | ------ | ---------- | -------------------
| `:error` | 致命的エラーです | 決済失敗、データ不整合、認証エラー | 即時通知（PagerDuty、Slack）
| `:warning` | 注意レベルです | 外部APIフォールバック、キャッシュミス、レート制限 | 閾値超過時に通知します
| `:info` | 情報提供です | 非推奨機能の使用、設定値の自動補正、リトライ成功 | 日次レポートで確認します

## sourceパラメータの活用

```ruby

# Rails内部で使われるsourceの例

"application"       # アプリケーションコード（デフォルト）
"action_controller" # コントローラ層からのエラー
"active_record"     # データベース関連のエラー
"active_job"        # バックグラウンドジョブのエラー
"action_mailer"     # メール送信のエラー

# カスタムsourceの定義

Rails.error.handle(source: "payment_gateway") do
  StripeService.charge!(amount)
end

```

sourceを活用することで、監視ダッシュボードでエラーの発生源別にフィルタリングや集計が可能になります。

## エラー報告のベストプラクティス

### 1. エラー処理の階層設計

```ruby

# レイヤーごとに適切なエラー処理を行います

class OrdersController < ApplicationController
  def create
    # コントローラ層: 非致命的なエラーはhandleで処理します
    Rails.error.handle(context: { order_id: params[:id] }) do
      NotificationService.send_confirmation(order)
    end

    # 致命的なエラーはrecordで報告して伝播させます
    Rails.error.record(context: { order_id: params[:id] }) do
      PaymentService.charge!(order)
    end
  end
end

```

### 2. カスタム例外クラスとの組み合わせ

```ruby

# 例外の分類を明確にします

module Errors
  class Retryable < StandardError; end
  class Fatal < StandardError; end
  class ExternalServiceError < StandardError; end
end

# 例外の種類に応じてseverityを変えます

Rails.error.handle(Errors::Retryable, severity: :warning) do
  api_call_with_retry
end

Rails.error.record(Errors::Fatal, severity: :error) do
  critical_operation
end

```

### 3. テスト環境でのError Reporterの活用

```ruby

# テストでError Reporterの挙動を検証します

RSpec.describe OrderService do
  it "在庫不足時にエラーが報告される" do
    subscriber = ActiveSupport::ErrorReporter::TestHelper
    # Rails 7.1+のassert_error_reported相当
    expect {
      OrderService.create!(out_of_stock_item)
    }.to have_reported_error(InventoryError)
  end
end

```

### 4. 避けるべきアンチパターン

```ruby

# NG: すべての例外をhandleで握りつぶしています

Rails.error.handle do
  dangerous_operation  # 致命的エラーも見逃してしまいます
end

# OK: 特定の例外クラスを指定します

Rails.error.handle(Timeout::Error, fallback: cached_data) do
  external_api_call
end

# NG: コンテキストなしで報告しています（デバッグが困難になります）

Rails.error.handle do
  process_something
end

# OK: 十分なコンテキストを付与します

Rails.error.handle(context: { user_id: user.id, action: "import" }) do
  process_something
end

```

## ファイル構成

```text

25_error_reporter/
├── README.md                # このファイル
├── error_reporter.rb        # Error Reporterの教育用実装
└── error_reporter_spec.rb   # テストコード

```

## 実行方法

```bash

# テストの実行

bundle exec rspec 25_error_reporter/error_reporter_spec.rb

# 特定のテストグループのみ実行します

bundle exec rspec 25_error_reporter/error_reporter_spec.rb -e "handle"
bundle exec rspec 25_error_reporter/error_reporter_spec.rb -e "severity"

# 個別のメソッドを試す

ruby -r ./25_error_reporter/error_reporter -e "pp ErrorReporterDemo.demonstrate_handle"
ruby -r ./25_error_reporter/error_reporter -e "pp ErrorReporterDemo.demonstrate_multiple_subscribers"

```

## 参考資料

- [Railsガイド - Error
  Reporting](https://guides.rubyonrails.org/error_reporting.html)
- [Rails API -
  ActiveSupport::ErrorReporter](https://api.rubyonrails.org/classes/ActiveSupport/ErrorReporter.html)
- [Rails 7.0リリースノート - Error
  Reporter](https://edgeguides.rubyonrails.org/7_0_release_notes.html)
- [Rails 7.1リリースノート -
  ErrorReporter#report](https://edgeguides.rubyonrails.org/7_1_release_notes.html)
