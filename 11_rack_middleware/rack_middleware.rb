# frozen_string_literal: true

require 'rack'
require 'json'

# Rackミドルウェアチェーンとリクエストライフサイクルを解説するモジュール
#
# Rackは Ruby の Web サーバーとアプリケーションフレームワーク間の
# 最小インターフェース仕様である。すべての Rails アプリケーションは
# Rack アプリケーションであり、ミドルウェアスタックを通じてリクエストを処理する。
#
# このモジュールでは、シニアエンジニアが知るべき Rack の内部動作と
# ミドルウェアパターンを実例を通じて学ぶ。
module RackMiddleware
  # ==========================================================================
  # Rack インターフェース: 基本的な Rack アプリ
  # ==========================================================================
  #
  # Rack アプリケーションの最小要件:
  # - call(env) メソッドを持つオブジェクト
  # - [status, headers, body] の3要素配列を返す
  # - body は each に応答するオブジェクト
  #
  # env はリクエスト情報を含むハッシュで、CGI ライクなキーを持つ:
  #   REQUEST_METHOD, PATH_INFO, QUERY_STRING, HTTP_* ヘッダーなど

  # 最もシンプルな Rack アプリケーション
  # call(env) を持つ任意のオブジェクトが Rack アプリになれる
  class SimpleApp
    def call(_env)
      [
        200,
        { 'content-type' => 'text/plain' },
        ['Hello from SimpleApp']
      ]
    end
  end

  # Proc/Lambda も Rack アプリとして使える
  # テストやプロトタイピングで頻繁に使われるパターン
  LAMBDA_APP = lambda { |_env|
    [200, { 'content-type' => 'text/plain' }, ['Hello from Lambda']]
  }

  # ==========================================================================
  # ミドルウェアパターン: before/after 処理
  # ==========================================================================
  #
  # ミドルウェアはアプリケーションをラップし、リクエストの前処理と
  # レスポンスの後処理を行う。デコレータパターンの一種である。
  #
  # 典型的なミドルウェアの構造:
  #   1. initialize(app) で次のアプリ/ミドルウェアを受け取る
  #   2. call(env) で処理を行う
  #   3. @app.call(env) で次に委譲する
  #   4. レスポンスを加工して返す

  # リクエストの処理時間を計測するミドルウェア
  # before/after パターンの典型例
  class TimingMiddleware
    def initialize(app)
      @app = app
    end

    def call(env)
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # 次のミドルウェア/アプリに委譲（before → app → after）
      status, headers, body = @app.call(env)

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
      headers['x-runtime'] = format('%.6f', elapsed)

      [status, headers, body]
    end
  end

  # リクエスト/レスポンスをログに記録するミドルウェア
  # 実際の Rack::CommonLogger に近いパターン
  class LoggingMiddleware
    attr_reader :logs

    def initialize(app)
      @app = app
      @logs = []
    end

    def call(env)
      request_method = env['REQUEST_METHOD']
      path = env['PATH_INFO']

      status, headers, body = @app.call(env)

      @logs << {
        method: request_method,
        path: path,
        status: status,
        timestamp: Time.now.iso8601
      }

      [status, headers, body]
    end
  end

  # ==========================================================================
  # 認証ミドルウェア: 早期リターン（ショートサーキット）
  # ==========================================================================
  #
  # ミドルウェアは条件によってリクエストを次に渡さず、
  # 直接レスポンスを返すことができる（早期リターン）。
  # 認証失敗時の 401 レスポンスがその典型例。

  class AuthenticationMiddleware
    # 教育用のデモ値。本番では ENV.fetch('API_TOKEN') や
    # Rails.application.credentials.api_token を使用すること
    VALID_TOKEN = 'secret-token-123'

    def initialize(app, options = {})
      @app = app
      @excluded_paths = options.fetch(:excluded_paths, [])
    end

    def call(env)
      path = env['PATH_INFO']

      # 除外パスはスキップ（例: ヘルスチェック、ログイン）
      return @app.call(env) if @excluded_paths.include?(path)

      token = extract_token(env)

      if token == VALID_TOKEN
        # 認証成功: 認証情報を env に追加して次へ委譲
        env['rack.authenticated'] = true
        env['rack.auth_token'] = token
        @app.call(env)
      else
        # 認証失敗: 早期リターンで 401 を返す（次へ委譲しない）
        [
          401,
          { 'content-type' => 'application/json' },
          [JSON.generate({ error: 'Unauthorized' })]
        ]
      end
    end

    private

    def extract_token(env)
      auth_header = env['HTTP_AUTHORIZATION'] || ''
      auth_header.sub(/\ABearer\s+/, '')
    end
  end

  # ==========================================================================
  # CORS ミドルウェア: レスポンスヘッダーの付与
  # ==========================================================================
  #
  # Cross-Origin Resource Sharing (CORS) ヘッダーを付与するミドルウェア。
  # OPTIONS プリフライトリクエストへの応答も処理する。

  class CorsMiddleware
    DEFAULT_HEADERS = {
      'access-control-allow-origin' => '*',
      'access-control-allow-methods' => 'GET, POST, PUT, DELETE, OPTIONS',
      'access-control-allow-headers' => 'Content-Type, Authorization',
      'access-control-max-age' => '86400'
    }.freeze

    def initialize(app, options = {})
      @app = app
      @allowed_origins = options.fetch(:allowed_origins, ['*'])
    end

    def call(env)
      # OPTIONS プリフライトリクエストは早期リターン
      return [204, cors_headers(env), []] if env['REQUEST_METHOD'] == 'OPTIONS'

      status, headers, body = @app.call(env)

      # 通常リクエストにも CORS ヘッダーを付与
      cors_headers(env).each { |key, value| headers[key] = value }

      [status, headers, body]
    end

    private

    def cors_headers(env)
      origin = env['HTTP_ORIGIN'] || '*'
      allowed = if @allowed_origins.include?('*')
                  '*'
                elsif @allowed_origins.include?(origin)
                  origin
                else
                  @allowed_origins.first
                end

      DEFAULT_HEADERS.merge('access-control-allow-origin' => allowed)
    end
  end

  # ==========================================================================
  # レートリミットミドルウェア: 状態管理とカウンター
  # ==========================================================================
  #
  # リクエスト頻度を制限するミドルウェア。
  # IP アドレスごとにリクエスト数を追跡し、制限を超えた場合は 429 を返す。
  # 注意: 本番環境では Redis 等の外部ストアを使用すること。

  class RateLimitMiddleware
    def initialize(app, options = {})
      @app = app
      @max_requests = options.fetch(:max_requests, 100)
      @window_seconds = options.fetch(:window_seconds, 3600)
      @store = {}
      @mutex = Mutex.new
    end

    def call(env)
      client_ip = env['REMOTE_ADDR'] || '127.0.0.1'

      @mutex.synchronize do
        cleanup_expired_entries
        record = @store[client_ip] ||= { count: 0, window_start: current_time }

        # ウィンドウが期限切れなら新しいウィンドウを開始
        if current_time - record[:window_start] > @window_seconds
          record[:count] = 0
          record[:window_start] = current_time
        end

        record[:count] += 1

        if record[:count] > @max_requests
          remaining = @window_seconds - (current_time - record[:window_start])
          return [
            429,
            {
              'content-type' => 'application/json',
              'retry-after' => remaining.ceil.to_s,
              'x-ratelimit-limit' => @max_requests.to_s,
              'x-ratelimit-remaining' => '0'
            },
            [JSON.generate({ error: 'Too Many Requests' })]
          ]
        end
      end

      status, headers, body = @app.call(env)

      # レートリミット情報をレスポンスヘッダーに含める
      remaining = @mutex.synchronize do
        record = @store[client_ip]
        @max_requests - (record ? record[:count] : 0)
      end
      headers['x-ratelimit-limit'] = @max_requests.to_s
      headers['x-ratelimit-remaining'] = [remaining, 0].max.to_s

      [status, headers, body]
    end

    private

    def current_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def cleanup_expired_entries
      now = current_time
      @store.delete_if { |_ip, record| now - record[:window_start] > @window_seconds }
    end
  end

  # ==========================================================================
  # Rack::Request / Rack::Response: 便利ラッパー
  # ==========================================================================
  #
  # 生の env ハッシュを直接操作する代わりに、
  # Rack::Request と Rack::Response で扱いやすいインターフェースを提供する。
  # Rails の ActionDispatch::Request はこれをさらに拡張したもの。

  class RequestInspectorApp
    def call(env)
      request = Rack::Request.new(env)

      info = {
        method: request.request_method,
        path: request.path_info,
        query_string: request.query_string,
        params: request.params,
        content_type: request.content_type,
        user_agent: request.user_agent,
        ip: request.ip,
        scheme: request.scheme,
        host: request.host,
        xhr: request.xhr?
      }

      # Rack::Response を使ってレスポンスを組み立てる
      response = Rack::Response.new
      response.status = 200
      response['content-type'] = 'application/json'
      response.set_cookie('visited', { value: 'true', path: '/' })
      response.write(JSON.generate(info))
      response.finish
    end
  end

  # ==========================================================================
  # ミドルウェアスタックの構築: Rack::Builder
  # ==========================================================================
  #
  # Rack::Builder は DSL でミドルウェアスタックを組み立てる。
  # config.ru で使われる use / run / map がこの DSL のメソッド。
  #
  # 実行順序:
  #   リクエスト → Middleware1 → Middleware2 → App
  #   レスポンス ← Middleware1 ← Middleware2 ← App
  #
  # use で追加した順に外側から内側へラップされる。

  # ミドルウェアスタックを構築するヘルパー
  module StackBuilder
    module_function

    # 基本的なミドルウェアスタックを構築する
    # use でミドルウェアを追加し、run で最終アプリを指定する
    def build_basic_stack(app)
      Rack::Builder.new do
        use RackMiddleware::TimingMiddleware
        use RackMiddleware::LoggingMiddleware
        run app
      end.to_app
    end

    # 認証付きスタックを構築する
    # ミドルウェアの順序が重要: CORS → 認証 → アプリ
    def build_authenticated_stack(app)
      Rack::Builder.new do
        use RackMiddleware::CorsMiddleware
        use RackMiddleware::AuthenticationMiddleware, excluded_paths: ['/health']
        use RackMiddleware::TimingMiddleware
        run app
      end.to_app
    end

    # map を使った URL パスベースのルーティング
    # 異なるパスに異なるアプリを割り当てる
    def build_mapped_stack
      Rack::Builder.new do
        map '/api' do
          use RackMiddleware::AuthenticationMiddleware, excluded_paths: []
          run lambda { |_env|
            [200, { 'content-type' => 'application/json' }, ['{"endpoint":"api"}']]
          }
        end

        map '/health' do
          run lambda { |_env|
            [200, { 'content-type' => 'text/plain' }, ['OK']]
          }
        end

        run lambda { |_env|
          [404, { 'content-type' => 'text/plain' }, ['Not Found']]
        }
      end.to_app
    end
  end

  # ==========================================================================
  # ミドルウェアの実行順序: なぜ順序が重要か
  # ==========================================================================
  #
  # ミドルウェアの順序はアプリケーションの動作に大きく影響する:
  #
  # 1. 外側のミドルウェアほどリクエストを先に受け取る
  # 2. 内側のミドルウェアほどアプリに近い
  # 3. レスポンスは逆順で処理される
  # 4. 早期リターンすると内側のミドルウェアは実行されない
  #
  # 例: ログ → 認証 → アプリ の順の場合
  #   - 認証失敗してもリクエストはログに記録される
  #   - 認証 → ログ → アプリ の順だと、認証失敗時はログが記録されない

  # 実行順序を記録するミドルウェア（デモ用）
  class OrderTrackingMiddleware
    def initialize(app, name:, tracker:)
      @app = app
      @name = name
      @tracker = tracker
    end

    def call(env)
      @tracker << "#{@name}:before"
      status, headers, body = @app.call(env)
      @tracker << "#{@name}:after"
      [status, headers, body]
    end
  end

  # ==========================================================================
  # 条件付きミドルウェア: 特定条件でのみ実行
  # ==========================================================================
  #
  # すべてのリクエストで実行する必要のないミドルウェアは、
  # 条件分岐で選択的に処理をスキップできる。

  class ConditionalMiddleware
    def initialize(app, &condition)
      @app = app
      @condition = condition || ->(_env) { true }
    end

    def call(env)
      if @condition.call(env)
        # 条件に合致: ミドルウェア固有の処理を実行
        env['rack.conditional_applied'] = true
        status, headers, body = @app.call(env)
        headers['x-conditional'] = 'applied'
        [status, headers, body]
      else
        # 条件に合致しない: そのまま次へ委譲
        @app.call(env)
      end
    end
  end

  # ==========================================================================
  # ストリーミングレスポンス: チャンク転送
  # ==========================================================================
  #
  # Rack のボディは each に応答するオブジェクトであればよい。
  # これを利用して、大きなレスポンスをチャンクごとに送信できる。
  #
  # Rack 3 では body が each に応答する通常パターンに加え、
  # rack.hijack によるソケット直接操作もサポートされる。

  # ストリーミング用のボディオブジェクト
  # each でチャンクを逐次 yield する
  class StreamingBody
    def initialize(chunks)
      @chunks = chunks
    end

    def each(&)
      @chunks.each(&)
    end
  end

  # ストリーミングレスポンスを返すアプリ
  class StreamingApp
    def initialize(chunk_count: 5)
      @chunk_count = chunk_count
    end

    def call(_env)
      chunks = (1..@chunk_count).map { |i| "chunk-#{i}\n" }
      body = StreamingBody.new(chunks)

      [
        200,
        { 'content-type' => 'text/plain' },
        body
      ]
    end
  end

  # ==========================================================================
  # レスポンスボディ変換ミドルウェア
  # ==========================================================================
  #
  # レスポンスボディ全体を読み取り、変換して返すパターン。
  # 圧縮、HTML インジェクション、JSON 変換などに使われる。
  # 注意: ボディ全体をメモリに読み込むため、大きなレスポンスには不向き。

  class ResponseTransformMiddleware
    def initialize(app, &transformer)
      @app = app
      @transformer = transformer || ->(body_string) { body_string }
    end

    def call(env)
      status, headers, body = @app.call(env)

      # ボディ全体を文字列として読み取る
      body_parts = body.map { |part| part }
      body.close if body.respond_to?(:close)

      original_body = body_parts.join

      # 変換を適用
      transformed_body = @transformer.call(original_body)

      # Content-Length を再計算（変換で長さが変わる可能性があるため）
      headers['content-length'] = transformed_body.bytesize.to_s

      [status, headers, [transformed_body]]
    end
  end

  # ==========================================================================
  # env ハッシュの主要キー一覧
  # ==========================================================================
  #
  # Rack 仕様で定義されている主要な env キー:
  #
  # REQUEST_METHOD   - HTTP メソッド（GET, POST, etc.）
  # PATH_INFO        - リクエストパス
  # QUERY_STRING     - クエリ文字列
  # SERVER_NAME      - サーバー名
  # SERVER_PORT      - サーバーポート
  # HTTP_*           - HTTP ヘッダー（HTTP_HOST, HTTP_ACCEPT 等）
  # rack.input       - リクエストボディの IO オブジェクト
  # rack.errors      - エラー出力の IO オブジェクト
  # rack.url_scheme  - "http" または "https"
  #
  # Rails が追加する主なキー:
  # action_dispatch.request.parameters - パース済みパラメータ
  # action_dispatch.cookies           - Cookie ハッシュ
  # action_controller.instance        - コントローラーインスタンス

  # ==========================================================================
  # Rails ミドルウェアスタック
  # ==========================================================================
  #
  # Rails は ActionDispatch::MiddlewareStack でミドルウェアを管理する。
  # `rails middleware` コマンドでスタック全体を確認できる。
  #
  # 主な Rails ミドルウェア（実行順）:
  #
  # ActionDispatch::HostAuthorization    - 許可ホストの検証
  # Rack::Sendfile                       - X-Sendfile による静的ファイル配信
  # ActionDispatch::Executor             - リクエストごとのリロード管理
  # ActionDispatch::RequestId            - X-Request-Id ヘッダーの付与
  # ActionDispatch::RemoteIp             - 信頼できるプロキシ経由の IP 取得
  # Rails::Rack::Logger                  - リクエストログの出力
  # ActionDispatch::ShowExceptions       - 例外をエラーページに変換
  # ActionDispatch::Callbacks            - before/after コールバック
  # ActionDispatch::Cookies              - Cookie の読み書き
  # ActionDispatch::Session::CookieStore - セッション管理
  # ActionDispatch::Flash                - flash メッセージ
  # ActionDispatch::ContentSecurityPolicy - CSP ヘッダー
  # Rack::Head                           - HEAD リクエストの body 除去
  # Rack::ConditionalGet                 - ETag/Last-Modified による 304
  # Rack::ETag                           - ETag の自動生成
  #
  # カスタムミドルウェアの追加方法:
  #   config.middleware.use    MyMiddleware        # スタック末尾に追加
  #   config.middleware.insert_before X, MyMiddleware  # X の前に挿入
  #   config.middleware.insert_after  X, MyMiddleware  # X の後に挿入
  #   config.middleware.delete MyMiddleware        # 削除

  module_function

  # === Rack インターフェースのデモ ===
  #
  # 最小限の Rack アプリが正しい形式のレスポンスを返すことを確認する。
  # Rack アプリの唯一の要件は call(env) → [status, headers, body] である。
  def demonstrate_rack_interface
    app = SimpleApp.new
    env = Rack::MockRequest.env_for('/hello', method: 'GET')
    status, headers, body = app.call(env)

    # Lambda も同じインターフェースで動作する
    lambda_status, _, lambda_body = LAMBDA_APP.call(env)

    {
      # SimpleApp のレスポンス
      status: status,
      content_type: headers['content-type'],
      body: body.first,
      # Lambda アプリのレスポンス
      lambda_status: lambda_status,
      lambda_body: lambda_body.first,
      # Rack アプリの要件: call メソッドを持つこと
      app_responds_to_call: app.respond_to?(:call),
      lambda_responds_to_call: LAMBDA_APP.respond_to?(:call)
    }
  end

  # === ミドルウェアの前後処理デモ ===
  #
  # TimingMiddleware がレスポンスヘッダーに処理時間を追加する様子を確認する。
  def demonstrate_middleware_wrapping
    inner_app = lambda { |_env|
      [200, { 'content-type' => 'text/plain' }, ['Inner App Response']]
    }

    # TimingMiddleware が inner_app をラップ
    timed_app = TimingMiddleware.new(inner_app)
    env = Rack::MockRequest.env_for('/test')
    status, headers, body = timed_app.call(env)

    {
      status: status,
      body: body.first,
      # x-runtime ヘッダーが追加されている
      has_runtime_header: headers.key?('x-runtime'),
      runtime: headers['x-runtime']
    }
  end

  # === 認証ミドルウェアのデモ ===
  #
  # 認証成功/失敗/除外パスのそれぞれのケースを確認する。
  def demonstrate_authentication
    inner_app = lambda { |env|
      authenticated = env['rack.authenticated'] ? 'yes' : 'no'
      [200, { 'content-type' => 'text/plain' }, ["Authenticated: #{authenticated}"]]
    }

    auth_app = AuthenticationMiddleware.new(inner_app, excluded_paths: ['/health'])

    # 認証成功
    env_valid = Rack::MockRequest.env_for('/api/data')
    env_valid['HTTP_AUTHORIZATION'] = "Bearer #{AuthenticationMiddleware::VALID_TOKEN}"
    success_status, _success_headers, success_body = auth_app.call(env_valid)

    # 認証失敗
    env_invalid = Rack::MockRequest.env_for('/api/data')
    env_invalid['HTTP_AUTHORIZATION'] = 'Bearer wrong-token'
    fail_status, _fail_headers, fail_body = auth_app.call(env_invalid)

    # 除外パス
    env_excluded = Rack::MockRequest.env_for('/health')
    excluded_status, _excluded_headers, _excluded_body = auth_app.call(env_excluded)

    {
      success_status: success_status,
      success_body: success_body.first,
      fail_status: fail_status,
      fail_body: fail_body.first,
      excluded_status: excluded_status
    }
  end

  # === ミドルウェア実行順序のデモ ===
  #
  # OrderTrackingMiddleware で before/after の実行順序を可視化する。
  def demonstrate_execution_order
    tracker = []

    inner_app = lambda { |_env|
      tracker << 'app'
      [200, { 'content-type' => 'text/plain' }, ['OK']]
    }

    # 外側から Outer → Inner → App の順にラップ
    app = OrderTrackingMiddleware.new(
      OrderTrackingMiddleware.new(
        inner_app,
        name: 'Inner', tracker: tracker
      ),
      name: 'Outer', tracker: tracker
    )

    env = Rack::MockRequest.env_for('/test')
    app.call(env)

    {
      # 実行順序: Outer:before → Inner:before → app → Inner:after → Outer:after
      execution_order: tracker,
      # リクエストは外側から内側へ、レスポンスは内側から外側へ
      request_order: tracker.select { |e| e.include?('before') || e == 'app' },
      response_order: tracker.select { |e| e.include?('after') }
    }
  end

  # === Rack::Builder によるスタック構築のデモ ===
  #
  # use / run / map を使ったミドルウェアスタックの構築を確認する。
  def demonstrate_stack_building
    simple_app = lambda { |_env|
      [200, { 'content-type' => 'text/plain' }, ['Built with Rack::Builder']]
    }

    # 基本スタック
    stack = StackBuilder.build_basic_stack(simple_app)
    env = Rack::MockRequest.env_for('/test')
    status, headers, body = stack.call(env)

    {
      status: status,
      body: body.first,
      has_timing: headers.key?('x-runtime')
    }
  end

  # === Rack::Request / Rack::Response のデモ ===
  #
  # 生 env ハッシュを Rack::Request でラップすると、
  # params, content_type, ip などに簡潔にアクセスできる。
  def demonstrate_request_response
    app = RequestInspectorApp.new
    env = Rack::MockRequest.env_for(
      '/users?page=1&per=20',
      method: 'GET',
      'HTTP_USER_AGENT' => 'TestAgent/1.0'
    )

    status, headers, body = app.call(env)
    body_string = +''
    body.each { |part| body_string << part }
    parsed = JSON.parse(body_string)

    {
      status: status,
      content_type: headers['content-type'],
      method: parsed['method'],
      path: parsed['path'],
      params: parsed['params'],
      user_agent: parsed['user_agent'],
      has_cookie_header: headers.key?('set-cookie')
    }
  end

  # === ストリーミングレスポンスのデモ ===
  #
  # StreamingBody が each でチャンクを逐次返す様子を確認する。
  def demonstrate_streaming
    app = StreamingApp.new(chunk_count: 3)
    env = Rack::MockRequest.env_for('/stream')
    status, _, body = app.call(env)

    chunks = []
    body.each { |chunk| chunks << chunk } # rubocop:disable Style/MapIntoArray

    {
      status: status,
      chunk_count: chunks.size,
      chunks: chunks,
      # ストリーミングボディは each に応答する
      body_responds_to_each: body.respond_to?(:each)
    }
  end

  # === レスポンス変換ミドルウェアのデモ ===
  #
  # ResponseTransformMiddleware がボディを変換し、
  # Content-Length を再計算する様子を確認する。
  def demonstrate_response_transform
    inner_app = lambda { |_env|
      [200, { 'content-type' => 'text/plain' }, ['hello world']]
    }

    # ボディを大文字に変換するミドルウェア
    transformer = ResponseTransformMiddleware.new(inner_app, &:upcase)

    env = Rack::MockRequest.env_for('/transform')
    status, headers, body = transformer.call(env)

    {
      status: status,
      body: body.first,
      content_length: headers['content-length'],
      # 変換後の Content-Length が正しいことを確認
      length_matches: headers['content-length'].to_i == body.first.bytesize
    }
  end
end
