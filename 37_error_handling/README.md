# エラーハンドリング設計パターン

## エラーハンドリング設計が重要な理由

本番アプリケーションの品質は、正常系のコードよりも異常系の設計で決まることが多いです。適切なエラーハンドリングは以下を実現します。

- 障害の影響範囲を限定します。一部の機能障害がシステム全体をダウンさせないようにします
- 迅速な問題特定を可能にします。構造化されたエラー情報により、原因調査の時間を短縮します
- ユーザー体験を維持します。内部エラーを適切なメッセージに変換して返します
- 運用の自動化を促進します。エラーの種類に応じたアラートや自動復旧を実現します

## 例外設計の原則

### カスタム例外階層の構築

アプリケーション固有の例外階層を設計することで、`rescue`節の粒度を柔軟に制御できます。

```ruby

# 基底例外クラス（すべてのアプリケーション例外の親）

class ApplicationError < StandardError
  attr_reader :error_code, :http_status, :metadata

  def initialize(message = nil, error_code: "APP_ERROR", http_status: 500, metadata: {})
    @error_code = error_code
    @http_status = http_status
    @metadata = metadata
    super(message)
  end
end

# ビジネスロジック上のエラー（ユーザーの操作に起因します）

class BusinessError < ApplicationError; end
class ValidationError < BusinessError; end
class AuthorizationError < BusinessError; end

# システムエラー（インフラ/外部サービスに起因します）

class SystemError < ApplicationError; end
class ExternalServiceError < SystemError; end
class DatabaseError < SystemError; end

```

この設計により、以下のような柔軟な`rescue`が可能になります。

```ruby

begin
  process_order(params)
rescue ValidationError => e
  # バリデーションエラーのみキャッチします（422を返します）
  render json: { error: e.message }, status: :unprocessable_entity
rescue BusinessError => e
  # ビジネスロジックエラー全般をキャッチします
  render json: { error: e.message }, status: e.http_status
rescue ApplicationError => e
  # すべてのアプリケーション例外をキャッチします（最終防衛線）
  ErrorReporter.report(e)
  render json: { error: "内部エラー" }, status: :internal_server_error
end

```

### ExceptionとStandardErrorの違い

Rubyの例外階層を正しく理解することは極めて重要です。

```text

Exception
├── NoMemoryError          ← rescueでは捕捉すべきではありません
├── ScriptError            ← rescueでは捕捉すべきではありません
├── SecurityError          ← rescueでは捕捉すべきではありません
├── SignalException        ← Ctrl+C (Interrupt) を含みます
├── SystemExit             ← exit 呼び出し
└── StandardError          ← rescueのデフォルトターゲットです
    ├── RuntimeError
    ├── TypeError
    ├── ArgumentError
    └── ...（カスタム例外はここに配置します）

```

`rescue Exception => e`は絶対に使ってはいけません。これを書くと以下の問題が発生します。

- `Ctrl+C`（Interrupt）が効かなくなります
- `exit`が無効になります（プロセスを停止できなくなります）
- メモリ枯渇時の`NoMemoryError`を握り潰してしまいます

```ruby

# 危険: 絶対にやってはいけません

begin
  do_something
rescue Exception => e  # ← すべての例外をキャッチします
  log(e)               # Ctrl+CもSystemExitもここに来ます
end

# 正しい: StandardError（またはより具体的なクラス）を使います

begin
  do_something
rescue StandardError => e  # ← 通常のエラーのみキャッチします
  log(e)
end

```

### rescue_fromパターン

Railsの`ActionController::Base`が提供する`rescue_from`は、
コントローラ全体でエラーを統一的にハンドリングする仕組みです。

```ruby

class ApplicationController < ActionController::Base
  # 後に登録したものが先にマッチします（具体的なエラーを後に書きます）
  rescue_from ApplicationError do |e|
    render json: { error: e.error_code, message: e.message }, status: e.http_status
  end

  rescue_from ValidationError do |e|
    render json: {
      error: "VALIDATION_ERROR",
      field: e.field,
      details: e.errors
    }, status: :unprocessable_entity
  end

  rescue_from ActiveRecord::RecordNotFound do |e|
    render json: { error: "NOT_FOUND", message: e.message }, status: :not_found
  end
end

```

注意点として、以下を守ってください。

- 登録順序が重要です。後に登録したハンドラが先にマッチします
- 具体的な例外クラスのハンドラを後に（下に）書いてください
- `rescue_from`はコントローラ層のみで使用してください（サービス層では使いません）

## Circuit Breakerパターン

外部サービスの障害がアプリケーション全体に連鎖するのを防ぐパターンです。

### 3つの状態

```text

         失敗が閾値に達する
  ┌─────────────────────────────┐
  │                             ▼
[Closed] ◄───────────── [Half-Open] ───────────► [Open]
  正常動作     成功        試験的実行    失敗      遮断状態
                                                    │
                                                    │ タイムアウト経過
                                                    ▼
                                                [Half-Open]

```

- Closed（閉）は正常状態です。リクエストをそのまま通し、失敗回数をカウントします
- Open（開）は遮断状態です。外部サービスを呼ばず即座にエラーを返します。一定時間経過後にHalf-Openに遷移します
- Half-Open（半開）は試験的にリクエストを通す状態です。成功ならClosedに、失敗ならOpenに戻ります

### 実装のポイント

```ruby

class CircuitBreaker
  def initialize(failure_threshold: 5, recovery_timeout: 30, success_threshold: 2)
    @failure_threshold = failure_threshold
    @recovery_timeout = recovery_timeout
    @success_threshold = success_threshold
    @state = :closed
    @failure_count = 0
  end

  def call
    case @state
    when :closed
      begin
        result = yield
        record_success
        result
      rescue StandardError => e
        record_failure
        raise e
      end
    when :open
      if recovery_timeout_elapsed?
        @state = :half_open
        call { yield }
      else
        raise ExternalServiceError, "Circuit breaker is open"
      end
    when :half_open
      begin
        result = yield
        record_success
        @state = :closed if @success_count >= @success_threshold
        result
      rescue StandardError => e
        @state = :open
        raise e
      end
    end
  end
end

```

### 使用場面

- 外部API呼び出し（決済、メール送信、外部認証）
- データベースのレプリカ接続
- キャッシュサーバー（Redis）への接続
- マイクロサービス間通信

## リトライ戦略

### 指数バックオフとジッター

一時的な障害に対して再試行する際は、固定間隔ではなく指数関数的にバックオフします。さらにジッター（ランダム遅延）を加えてthundering
herd問題を防ぎます。

```text

リトライ回数:  1回目    2回目    3回目    4回目
固定間隔:      1s       1s       1s       1s       ← 全クライアントが同時にリトライします
指数バックオフ: 1s       2s       4s       8s       ← 間隔が徐々に広がります
+ジッター:     1.2s     2.4s     3.8s     8.5s     ← ランダム性で分散します

```

### リトライすべきエラーの判断

| エラーの種類 | リトライ | 理由
| ------------ | --------- | ------
| ネットワークタイムアウト | します | 一時的な接続問題の可能性があります
| HTTP 503 Service Unavailable | します | サーバーが一時的に過負荷の可能性があります
| HTTP 429 Too Many Requests | します | レート制限に達しただけです（Retry-Afterヘッダを確認します）
| HTTP 500 Internal Server Error | 慎重に判断します | 冪等な操作のみリトライできます
| HTTP 400 Bad Request | しません | リクエスト自体が不正です（再試行しても同じ結果です）
| HTTP 401 Unauthorized | しません | 認証情報が不正です（再試行しても同じ結果です）
| HTTP 404 Not Found | しません | リソースが存在しません

### 冪等性の確保

リトライを安全に行うには、操作が冪等（同じ操作を複数回実行しても結果が同じ）であることが前提となります。

```ruby

# 冪等な操作（リトライ可能）

def update_user_status(user_id, status)
  User.where(id: user_id).update_all(status: status)
end

# 冪等でない操作（リトライ危険）

def charge_customer(customer_id, amount)
  # 冪等キーを使って二重課金を防ぎます
  PaymentService.charge(
    customer_id: customer_id,
    amount: amount,
    idempotency_key: "charge_#{customer_id}_#{Date.today}"
  )
end

```

## エラーラッピングとcauseチェーン

### 低レベルエラーのドメイン変換

低レベルの例外（TCPエラー、SQLエラーなど）をそのまま上位層に伝播させると、抽象化が漏れてしまいます。ドメイン固有の例外にラップすることで、
各層が適切な抽象レベルでエラーを扱えるようになります。

```ruby

class PaymentService
  def charge(amount)
    gateway.process(amount)
  rescue Errno::ECONNREFUSED => e
    # 低レベルエラーをドメインエラーにラップします
    # Ruby 2.1+ではcauseが自動的にチェーンされます
    raise ExternalServiceError.new(
      "決済サービスに接続できません",
      service_name: "PaymentGateway",
      original_error: e
    )
  rescue Timeout::Error => e
    raise ExternalServiceError.new(
      "決済サービスがタイムアウトしました",
      service_name: "PaymentGateway",
      original_error: e
    )
  end
end

```

### causeチェーンの活用

```ruby

begin
  PaymentService.new.charge(1000)
rescue ExternalServiceError => e
  puts e.message         # => "決済サービスに接続できません"
  puts e.cause.class     # => Errno::ECONNREFUSED
  puts e.cause.message   # => "Connection refused"

  # 根本原因を辿ります
  root = e
  root = root.cause while root.cause
  puts root.class        # => Errno::ECONNREFUSED
end

```

## Fail-fastと縮退運転

### Fail-fast（即座にクラッシュ）

以下の場合は即座にエラーを発生させるべきです。

- 起動時の設定検証として、必須環境変数が不足している場合
- データ不整合のリスクとして、不正な状態で処理を続行すると被害が拡大する場合
- セキュリティ上の問題として、認証・認可の失敗が発生した場合

```ruby

class Application
  def initialize
    # 起動時に必須設定を検証します（不足していればクラッシュします）
    %w[DATABASE_URL SECRET_KEY_BASE REDIS_URL].each do |key|
      raise "必須環境変数 #{key} が設定されていません" if ENV[key].nil?
    end
  end
end

```

### Resilient（縮退運転）

以下の場合は機能を縮退させて動き続けるべきです。

- キャッシュ障害の場合、RedisがダウンしてもDBから取得できます
- 通知サービス障害の場合、メール送信失敗でもメイン処理は完了させます
- 推薦エンジン障害の場合、デフォルトのコンテンツを表示します

```ruby

def fetch_user_profile(user_id)
  # プライマリ: キャッシュから取得します
  Rails.cache.fetch("user:#{user_id}") do
    User.find(user_id).profile
  end
rescue Redis::ConnectionError => e
  # フォールバック: DBから直接取得します（遅いですが動作します）
  Rails.error.report(e, severity: :warning)
  User.find(user_id).profile
end

```

## エラー報告と監視

### Rails 7.1+のErrorReporter

Rails 7.1以降では`Rails.error`を使ってアプリケーション全体で統一的にエラーを報告できます。

```ruby

# handle: エラーを報告しつつ処理を続行します（非致命的エラー向け）

result = Rails.error.handle(fallback: default_value) do
  risky_operation
end

# record: エラーを報告しつつ例外を再raiseします（致命的エラー向け）

Rails.error.record do
  critical_operation
end

# report: 明示的にエラーを報告します

begin
  external_api_call
rescue ExternalServiceError => e
  Rails.error.report(e, severity: :error, context: {
    service: "PaymentGateway",
    user_id: current_user.id,
    request_id: request.request_id
  })
  raise
end

```

### 構造化されたエラーデータ

監視サービスに送るエラーデータは構造化すべきです。これにより、ダッシュボードでの集計やアラートルールの設定が容易になります。

```ruby

class ApplicationError < StandardError
  def to_error_report
    {
      error_class: self.class.name,
      error_code: @error_code,
      message: message,
      http_status: @http_status,
      metadata: @metadata,
      backtrace_head: backtrace&.first(5),
      timestamp: Time.current.iso8601
    }
  end
end

```

### 監視のベストプラクティス

| 項目 | 推奨事項
| ------ | ---------
| アラート粒度 | エラーコード別にアラートを設定します
| 閾値設定 | エラー率（割合）で判断します（絶対数ではありません）
| コンテキスト | request_id、user_id、操作内容を必ず含めます
| 重要度分類 | critical/error/warning/infoの4段階で分類します
| ノイズ削減 | 既知のエラーはグループ化して重複通知を防ぎます

## 実行方法

```bash

# テストの実行

bundle exec rspec 37_error_handling/error_handling_spec.rb

# 個別のメソッドを試す

ruby -r ./37_error_handling/error_handling -e "pp ErrorHandling.demonstrate_exception_hierarchy"
ruby -r ./37_error_handling/error_handling -e "pp ErrorHandling.demonstrate_circuit_breaker"
ruby -r ./37_error_handling/error_handling -e "pp ErrorHandling.demonstrate_retry_with_backoff"

```
