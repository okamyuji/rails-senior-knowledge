# API設計パターン

## API設計の理解が重要な理由

RESTful
APIの設計は、モダンなWebアプリケーション開発において最も重要なスキルの1つです。適切に設計されたAPIは、開発者体験（DX）を向上させ、
システムの保守性とスケーラビリティを大きく改善します。

シニアエンジニアがAPI設計を深く理解すべき理由は以下の通りです。

- 長期的な保守性を確保するためです。バージョニング戦略の選択は、APIの進化と後方互換性に直接影響します
- スケーラビリティを実現するためです。ページネーションやレート制限は、大規模システムの安定運用に不可欠です
- セキュリティを維持するためです。認証・認可の設計ミスは重大なセキュリティインシデントにつながります
- 開発者体験を向上させるためです。一貫したエラーレスポンスとドキュメントは、API利用者の生産性を大きく左右します

## APIバージョニング戦略

APIのバージョニングは、破壊的変更を導入する際にクライアントとの互換性を維持するために不可欠です。

### URLパスベース

最も一般的で直感的なアプローチです。ブラウザやcurlから簡単にテストできます。

```ruby

# config/routes.rb

namespace :api do
  namespace :v1 do
    resources :users, only: [:index, :show, :create]
  end
  namespace :v2 do
    resources :users, only: [:index, :show, :create]
  end
end

# app/controllers/api/v1/users_controller.rb

module Api
  module V1
    class UsersController < ApplicationController
      def index
        users = User.all
        render json: users
      end
    end
  end
end

```

利点として、URLから即座にバージョンが判別でき、キャッシュしやすくなります。

欠点として、URLがバージョン情報で汚染され、リソースのURIが変わります。

### ヘッダベース

URLをクリーンに保ちつつバージョニングを行うアプローチです。

```ruby

# カスタムヘッダ: X-API-Version: 2

# または Accept ヘッダ: application/vnd.myapp.v2+json

# config/routes.rb でコンストレイントを使用します

class ApiVersionConstraint
  def initialize(version:, default: false)
    @version = version
    @default = default
  end

  def matches?(request)
    @default || request.headers['X-API-Version'].to_i == @version
  end
end

Rails.application.routes.draw do
  scope module: :v2, constraints: ApiVersionConstraint.new(version: 2) do
    resources :users
  end

  scope module: :v1, constraints: ApiVersionConstraint.new(version: 1, default: true) do
    resources :users
  end
end

```

利点として、URLがクリーンになり、HTTP仕様に準拠します（Acceptヘッダの場合）。

欠点として、テストが面倒になり、CDNでのキャッシュが難しい場合があります。

### バージョニング戦略の選択基準

| 基準 | URLパス | ヘッダベース | Acceptヘッダ
| ------ | --------- | ------------- | -------------
| 実装の容易さ | 簡単 | 中程度 | やや複雑
| テストの容易さ | 簡単 | 中程度 | やや複雑
| URLの清潔さ | 低い | 高い | 高い
| HTTP仕様準拠 | 低い | 中程度 | 高い
| キャッシュ | 容易 | Vary要 | Vary要

## ページネーション実装

### オフセットベース

最もシンプルですが、大きなオフセットではDBクエリが遅くなります。

```ruby

# コントローラでの実装例

class Api::V1::UsersController < ApplicationController
  def index
    page = params.fetch(:page, 1).to_i
    per_page = [params.fetch(:per_page, 20).to_i, 100].min

    users = User.order(:id)
                .offset((page - 1) * per_page)
                .limit(per_page)

    total = User.count
    total_pages = (total.to_f / per_page).ceil

    # Linkヘッダを設定します（GitHub API方式）
    links = []
    base = api_v1_users_url
    links << "<#{base}?page=#{page + 1}&per_page=#{per_page}>; rel=\"next\"" if page < total_pages
    links << "<#{base}?page=#{page - 1}&per_page=#{per_page}>; rel=\"prev\"" if page > 1
    response.headers['Link'] = links.join(', ')

    render json: {
      data: users,
      meta: { current_page: page, total_pages: total_pages, total_count: total }
    }
  end
end

```

問題点として、`OFFSET 100000`のようなクエリは、DBが最初の100000行をスキャンする必要があるため非常に遅くなります。

### カーソルベース

大量データでも一貫した性能を発揮します。無限スクロールUIとの相性が良いです。

```ruby

class Api::V1::UsersController < ApplicationController
  def index
    limit = [params.fetch(:limit, 20).to_i, 100].min
    after = params[:after] # カーソル値（前ページの最後のID）

    scope = User.order(:id).limit(limit + 1) # +1で次ページの有無を判定します
    scope = scope.where('id > ?', after) if after

    users = scope.to_a
    has_next = users.size > limit
    users = users.first(limit)

    render json: {
      data: users,
      cursors: {
        after: users.last&.id,
        has_next: has_next
      }
    }
  end
end

```

### オフセットとカーソルの選択基準

| 基準 | オフセット | カーソル
| ------ | ---------- | --------
| 任意ページジャンプ | 可能です | 不可です
| 大量データ性能 | 劣化します | 安定しています
| データ追加時の一貫性 | 重複/欠落があります | 一貫しています
| 総件数/総ページ | 取得可能です | 別途計算が必要です
| 無限スクロール | 不向きです | 最適です
| 実装の容易さ | 簡単です | やや複雑です

## レート制限

### トークンバケットアルゴリズム

最も広く使われるレート制限アルゴリズムです。バースト的なトラフィックを許容しつつ、長期的なレートを制限します。

```ruby

# rack-attackを使った実装例

# config/initializers/rack_attack.rb

class Rack::Attack
  # IPアドレスごとに1分間に60リクエストまでに制限します
  throttle('api/ip', limit: 60, period: 1.minute) do |req|
    req.ip if req.path.start_with?('/api/')
  end

  # APIキーごとに1時間に1000リクエストまでに制限します
  throttle('api/key', limit: 1000, period: 1.hour) do |req|
    req.env['HTTP_X_API_KEY'] if req.path.start_with?('/api/')
  end

  # レート制限時のレスポンス
  self.throttled_responder = lambda do |env|
    match_data = env['rack.attack.match_data']
    now = match_data[:epoch_time]
    retry_after = match_data[:period] - (now % match_data[:period])

    headers = {
      'Content-Type' => 'application/json',
      'Retry-After' => retry_after.to_s,
      'X-RateLimit-Limit' => match_data[:limit].to_s,
      'X-RateLimit-Remaining' => '0'
    }

    body = { error: 'レート制限を超過しました', retry_after: retry_after }.to_json
    [429, headers, [body]]
  end
end

```

### レスポンスヘッダ

クライアントにレート制限の状況を通知する標準的なヘッダは以下の通りです。

```text

X-RateLimit-Limit: 1000        # ウィンドウ内の最大リクエスト数
X-RateLimit-Remaining: 950     # 残りリクエスト数
X-RateLimit-Reset: 1620000000  # リセット時刻（Unix timestamp）
Retry-After: 30                # 429レスポンス時、リトライまでの秒数

```

## エラーレスポンス設計

### RFC 7807 (Problem Details for HTTP APIs)

一貫した構造のエラーレスポンスにより、API利用者のデバッグ効率が大きく向上します。

```ruby

# app/controllers/concerns/api_error_handler.rb

module ApiErrorHandler
  extend ActiveSupport::Concern

  included do
    rescue_from ActiveRecord::RecordNotFound do |e|
      render_error(
        type: 'https://api.example.com/errors/not-found',
        title: 'リソースが見つかりません',
        status: 404,
        detail: "#{e.model} (ID: #{e.id}) が見つかりません"
      )
    end

    rescue_from ActiveRecord::RecordInvalid do |e|
      errors = e.record.errors.map do |error|
        { field: error.attribute, message: error.message, code: error.type }
      end

      render_error(
        type: 'https://api.example.com/errors/validation',
        title: 'バリデーションエラー',
        status: 422,
        detail: 'リクエストパラメータに不正な値が含まれています',
        errors: errors
      )
    end

    rescue_from ActionController::ParameterMissing do |e|
      render_error(
        type: 'https://api.example.com/errors/bad-request',
        title: 'パラメータ不足',
        status: 400,
        detail: "必須パラメータ '#{e.param}' がありません"
      )
    end
  end

  private

  def render_error(type:, title:, status:, detail:, errors: nil)
    body = { type: type, title: title, status: status, detail: detail, timestamp: Time.current.iso8601 }
    body[:errors] = errors if errors
    body[:request_id] = request.request_id

    render json: body, status: status, content_type: 'application/problem+json'
  end
end

```

### エラーレスポンスの設計原則

1. 一貫性を保ちます。すべてのエラーで同じ構造を使用します
2. 情報量を確保します。開発者がデバッグに必要な情報を含めます
3. セキュリティに配慮します。本番環境でスタックトレースや内部情報を露出しません
4. ドキュメント参照を提供します。`type`フィールドにエラー詳細ページのURLを設定します
5. リクエストIDを含めます。サポート問い合わせ時の追跡に使える一意なIDを含めます

### HTTPステータスコードの使い分け

| コード | 用途 | 例
| -------- | ------ | -----
| 400 | リクエスト形式が不正 | JSONパースエラー、必須パラメータ不足
| 401 | 認証が必要 | トークン未送信、トークン無効
| 403 | 認可されていない | 権限不足
| 404 | リソースが存在しない | 存在しないID
| 409 | 競合 | 楽観的ロック失敗、冪等性キー競合
| 422 | バリデーションエラー | 不正な値、ビジネスルール違反
| 429 | レート制限超過 | リクエスト数上限
| 500 | サーバー内部エラー | 予期しない例外

## 認証パターン

### APIキー認証

B2B APIなど、サーバーサイド間通信に適しています。

```ruby

# app/controllers/concerns/api_key_authenticatable.rb

module ApiKeyAuthenticatable
  extend ActiveSupport::Concern

  private

  def authenticate_api_key!
    raw_key = request.headers['X-API-Key']
    unless raw_key
      render_error(status: 401, detail: 'APIキーが必要です')
      return
    end

    hashed = Digest::SHA256.hexdigest(raw_key)
    @api_key = ApiKey.find_by(key_digest: hashed, active: true)

    unless @api_key
      render_error(status: 401, detail: '無効なAPIキーです')
      return
    end

    if @api_key.expired?
      render_error(status: 401, detail: 'APIキーの有効期限が切れています')
    end
  end
end

```

### Bearer Token (JWT) 認証

ステートレスな認証です。モバイルアプリやSPAとの連携に適しています。

```ruby

# Authorizationヘッダ: Bearer eyJhbGciOiJIUzI1NiJ9...

class Api::V1::AuthController < ApplicationController
  def login
    user = User.find_by(email: params[:email])
    if user&.authenticate(params[:password])
      token = generate_jwt(user)
      render json: { token: token, expires_in: 3600 }
    else
      render_error(status: 401, detail: 'メールアドレスまたはパスワードが不正です')
    end
  end
end

```

## HATEOAS (Hypermedia As The Engine Of Application State)

APIレスポンスにハイパーメディアリンクを含めることで、クライアントがAPIのナビゲーションを動的に行えるようになります。

```json

{
  "id": 1,
  "name": "田中太郎",
  "email": "tanaka@example.com",
  "_links": {
    "self": { "href": "/api/v1/users/1", "method": "GET" },
    "update": { "href": "/api/v1/users/1", "method": "PATCH" },
    "posts": { "href": "/api/v1/users/1/posts", "method": "GET" },
    "organization": { "href": "/api/v1/organizations/5", "method": "GET" }
  }
}

```

## 冪等性キー

ネットワーク障害によるリクエストの重複実行を防止します。決済APIなど、副作用のある操作に不可欠です。

```ruby

# Idempotency-Keyヘッダをチェックするミドルウェア

class IdempotencyMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    request = Rack::Request.new(env)
    key = request.get_header('HTTP_IDEMPOTENCY_KEY')

    # GETやDELETEは元々冪等なのでスキップします
    return @app.call(env) unless %w[POST PATCH].include?(request.request_method)
    return @app.call(env) unless key

    cached = IdempotencyCache.get(key)
    return cached if cached

    response = @app.call(env)
    IdempotencyCache.set(key, response, ttl: 24.hours)
    response
  end
end

```

## 実行方法

```bash

# テストの実行

bundle exec rspec 35_api_design/api_design_spec.rb

# 個別のパターンを試す

ruby -r ./35_api_design/api_design -e "
  # バージョニング
  router = ApiDesign::Versioning::UrlPathRouter.new('v1' => :handler_v1, 'v2' => :handler_v2)
  pp router.resolve('/api/v1/users')

  # レート制限
  bucket = ApiDesign::RateLimiting::TokenBucket.new(capacity: 10, refill_rate: 1.0)
  pp bucket.allow_request?

  # エラーレスポンス
  error = ApiDesign::ErrorResponse::ErrorBuilder.validation_error(
    errors: [{ field: 'email', message: 'は不正な形式です' }]
  )
  pp error.to_h
"

```
