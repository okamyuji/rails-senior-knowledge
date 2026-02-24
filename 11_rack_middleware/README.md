# Rackミドルウェア

## 概要

RackはRubyのWebサーバーとアプリケーションフレームワーク間の標準インターフェース仕様です。
Rails、Sinatra、Hanamiなど主要なRuby Webフレームワークはすべて Rackの上に構築されています。

シニアRailsエンジニアにとって、Rackの理解はパフォーマンスチューニング、
セキュリティ対策、カスタム機能の実装において不可欠な知識です。

## Rackプロトコルの仕組み

### 基本インターフェース

Rackアプリケーションの唯一の要件は、`call(env)` メソッドを持つオブジェクトであることです。

```ruby

# 最小限のRackアプリケーション

class MyApp
  def call(env)
    # env: リクエスト情報を含むハッシュ
    # 戻り値: [ステータスコード, ヘッダーハッシュ, ボディ]
    [200, { "content-type" => "text/plain" }, ["Hello, World!"]]
  end
end

# Lambda/ProcもRackアプリとして使えます

app = ->(env) { [200, {}, ["OK"]] }

```

### envハッシュの主要キー

| キー | 説明 | 例
| ------ | ------ | -----
| `REQUEST_METHOD` | HTTPメソッド | `"GET"`, `"POST"`
| `PATH_INFO` | リクエストパス | `"/users/1"`
| `QUERY_STRING` | クエリ文字列 | `"page=1&per=20"`
| `HTTP_HOST` | ホスト名 | `"example.com"`
| `HTTP_AUTHORIZATION` | 認証ヘッダー | `"Bearer token123"`
| `rack.input` | リクエストボディIO | `StringIO`オブジェクト
| `rack.url_scheme` | スキーム | `"https"`

### レスポンスの3要素

```ruby

[
  200,                                    # 1. ステータスコード（Integer）
  { "content-type" => "application/json" }, # 2. ヘッダー（Hash）
  ["response body"]                        # 3. ボディ（eachに応答するオブジェクト）
]

```

ボディは `each` メソッドに応答する任意のオブジェクトであれば問題ありません。
配列、カスタムイテレータ、ファイルオブジェクトなどが使用できます。

## ミドルウェアチェーンの実行順序

### ミドルウェアの役割

ミドルウェアはRackアプリケーションをラップするデコレータです。
リクエストの前処理とレスポンスの後処理を行います。

```ruby

class MyMiddleware
  def initialize(app)
    @app = app    # 次のミドルウェア or アプリケーション
  end

  def call(env)
    # 1. リクエスト前処理（beforeフェーズ）
    env["my.custom_data"] = "added by middleware"

    # 2. 次のミドルウェア/アプリに委譲
    status, headers, body = @app.call(env)

    # 3. レスポンス後処理（afterフェーズ）
    headers["x-custom-header"] = "added by middleware"

    [status, headers, body]
  end
end

```

### 実行順序の図解

```text

リクエスト → [Middleware A] → [Middleware B] → [Middleware C] → [App]
                                                                  |
レスポンス ← [Middleware A] ← [Middleware B] ← [Middleware C] ←---+

```

重要なポイントは以下の通りです。

1. リクエストは外側（先にuseした方）から内側へ流れます
2. レスポンスは内側から外側へ流れます（逆順）
3. ミドルウェアは途中で早期リターンできます（ショートサーキット）

### 順序が影響する実例

```text

# パターンA: ログ → 認証 → アプリ

use LoggingMiddleware    # 認証失敗もログに残る
use AuthMiddleware
run MyApp

# パターンB: 認証 → ログ → アプリ

use AuthMiddleware       # 認証失敗するとログが残らない
use LoggingMiddleware
run MyApp

```

認証失敗時にもログを残したい場合はパターンAが正しい選択です。
このようにミドルウェアの順序は機能に直接影響します。

## カスタムミドルウェア作成ガイド

### 基本テンプレート

```ruby

class CustomMiddleware
  def initialize(app, options = {})
    @app = app
    @option_value = options.fetch(:key, "default")
  end

  def call(env)
    # 前処理
    status, headers, body = @app.call(env)
    # 後処理
    [status, headers, body]
  end
end

```

### よくあるパターン

#### 1. 計測・ログ（通過型）

リクエストを必ず次に渡し、前後で計測やログを取ります。

```ruby

class TimingMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    status, headers, body = @app.call(env)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    headers["x-runtime"] = format("%.6f", elapsed)
    [status, headers, body]
  end
end

```

#### 2. 認証・認可（ゲート型）

条件を満たさないリクエストを早期リターンで拒否します。

```ruby

class AuthMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    token = env["HTTP_AUTHORIZATION"]&.sub(/\ABearer\s+/, "")
    unless valid_token?(token)
      return [401, { "content-type" => "text/plain" }, ["Unauthorized"]]
    end
    @app.call(env)
  end

  private

  def valid_token?(token)
    token == ENV["API_TOKEN"]
  end
end

```

#### 3. レスポンス変換（変換型）

レスポンスボディを読み取り、変換して返します。

```ruby

class JsonWrapperMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    status, headers, body = @app.call(env)
    parts = []
    body.each { |part| parts << part }
    body.close if body.respond_to?(:close)

    wrapped = JSON.generate({ data: parts.join, status: status })
    headers["content-length"] = wrapped.bytesize.to_s
    headers["content-type"] = "application/json"

    [status, headers, [wrapped]]
  end
end

```

#### 4. CORS（ヘッダー付与型）

レスポンスに追加ヘッダーを付与し、特定リクエストには早期リターンします。

```ruby

class CorsMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    if env["REQUEST_METHOD"] == "OPTIONS"
      return [204, cors_headers, []]
    end

    status, headers, body = @app.call(env)
    cors_headers.each { |k, v| headers[k] = v }
    [status, headers, body]
  end

  private

  def cors_headers
    {
      "access-control-allow-origin" => "*",
      "access-control-allow-methods" => "GET, POST, PUT, DELETE, OPTIONS",
      "access-control-allow-headers" => "Content-Type, Authorization"
    }
  end
end

```

#### 5. レートリミット（状態管理型）

リクエスト間で状態を保持し、制限を超えた場合は拒否します。

```ruby

class RateLimitMiddleware
  def initialize(app, max_requests: 100)
    @app = app
    @max_requests = max_requests
    @store = {}
    @mutex = Mutex.new
  end

  def call(env)
    ip = env["REMOTE_ADDR"]
    @mutex.synchronize do
      @store[ip] ||= { count: 0 }
      @store[ip][:count] += 1
      if @store[ip][:count] > @max_requests
        return [429, {}, ["Too Many Requests"]]
      end
    end
    @app.call(env)
  end
end

```

### Rack::Builderによる構成

```ruby

# config.ru

require_relative "app"

use TimingMiddleware
use CorsMiddleware
use AuthMiddleware, excluded_paths: ["/health"]
run MyApp.new

```

`map` を使ったパスベースのルーティングも可能です。

```ruby

# config.ru

map "/api" do
  use AuthMiddleware
  run ApiApp.new
end

map "/admin" do
  use AdminAuthMiddleware
  run AdminApp.new
end

run ->(env) { [404, {}, ["Not Found"]] }

```

### Rack::RequestとRack::Response

生のenvハッシュを直接扱う代わりに、便利なラッパーを使用できます。

```ruby

class MyApp
  def call(env)
    request = Rack::Request.new(env)

    # リクエスト情報への簡潔なアクセス
    request.get?              # => true / false
    request.path_info         # => "/users"
    request.params            # => { "page" => "1" }
    request.content_type      # => "application/json"
    request.ip                # => "192.168.1.1"

    # Rack::Responseでレスポンスを組み立てます
    response = Rack::Response.new
    response.status = 200
    response["content-type"] = "application/json"
    response.set_cookie("session", { value: "abc", path: "/" })
    response.write('{"message":"ok"}')
    response.finish  # => [status, headers, body]
  end
end

```

## Rails内部でのRack活用

### RailsアプリケーションはRackアプリケーションです

Railsアプリケーション自体が巨大なRackアプリケーションです。
`Rails.application` は `call(env)` に応答します。

```ruby

# Railsアプリケーションを直接呼び出す

env = Rack::MockRequest.env_for("/users")
status, headers, body = Rails.application.call(env)

```

### Railsミドルウェアスタックの確認

```bash

# Railsのミドルウェアスタック一覧を表示します

$ bin/rails middleware

```

典型的な出力（実行順）は以下の通りです。

```text

use ActionDispatch::HostAuthorization
use Rack::Sendfile
use ActionDispatch::Executor
use ActionDispatch::RequestId
use ActionDispatch::RemoteIp
use Rails::Rack::Logger
use ActionDispatch::ShowExceptions
use ActionDispatch::DebugExceptions
use ActionDispatch::Callbacks
use ActionDispatch::Cookies
use ActionDispatch::Session::CookieStore
use ActionDispatch::Flash
use ActionDispatch::ContentSecurityPolicy::Middleware
use Rack::Head
use Rack::ConditionalGet
use Rack::ETag
use Rack::TempfileReaper
run MyApp::Application.routes

```

### カスタムミドルウェアをRailsに追加する方法

```ruby

# config/application.rb

class Application < Rails::Application
  # スタック末尾に追加します
  config.middleware.use MyCustomMiddleware

  # 特定のミドルウェアの前に挿入します
  config.middleware.insert_before ActionDispatch::Cookies, MyEarlyMiddleware

  # 特定のミドルウェアの後に挿入します
  config.middleware.insert_after Rails::Rack::Logger, MyLogEnhancer

  # ミドルウェアを削除します
  config.middleware.delete ActionDispatch::Flash

  # ミドルウェアを入れ替えます
  config.middleware.swap ActionDispatch::ShowExceptions, MyExceptionHandler
end

```

### ストリーミングレスポンス

Rackのボディが `each` に応答する任意のオブジェクトであることを利用して、
大きなレスポンスをチャンクごとに送信できます。

```ruby

class StreamingBody
  def each
    1000.times do |i|
      yield "data: #{i}\n\n"
    end
  end
end

# Railsコントローラーでのストリーミング

class EventsController < ApplicationController
  include ActionController::Live

  def stream
    response.headers["Content-Type"] = "text/event-stream"
    100.times do |i|
      response.stream.write "data: #{i}\n\n"
      sleep 0.1
    end
  ensure
    response.stream.close
  end
end

```

## テスト手法

### Rack::MockRequestを使ったテスト

```ruby

# envハッシュを生成します

env = Rack::MockRequest.env_for("/path", method: "POST",
  input: '{"key":"value"}',
  "CONTENT_TYPE" => "application/json",
  "HTTP_AUTHORIZATION" => "Bearer token")

status, headers, body = app.call(env)

```

### rack-test gemを使ったテスト

```ruby

require "rack/test"

RSpec.describe MyApp do
  include Rack::Test::Methods

  def app
    MyApp.new
  end

  it "returns 200" do
    get "/hello"
    expect(last_response.status).to eq 200
    expect(last_response.body).to include("Hello")
  end
end

```

## まとめ

| 概念 | 説明
| ------ | ------
| Rackインターフェース | `call(env)` → `[status, headers, body]`
| ミドルウェア | アプリをラップするデコレータで、before/afterパターンで動作します
| 実行順序 | リクエストは外から内、レスポンスは内から外へ流れます
| 早期リターン | 条件不成立時に `@app.call` を呼ばず直接レスポンスを返します
| Rack::Builder | `use` / `run` / `map` でスタックを宣言的に構成します
| Railsとの関係 | RailsアプリはRackアプリであり、ミドルウェアスタックで拡張します
| ストリーミング | `each` でyieldするカスタムボディオブジェクトを使用します
