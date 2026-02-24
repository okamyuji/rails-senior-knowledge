# frozen_string_literal: true

require_relative 'rack_middleware'
require 'rack'
require 'rack/test'

RSpec.describe RackMiddleware do
  describe '.demonstrate_rack_interface' do
    let(:result) { described_class.demonstrate_rack_interface }

    it 'SimpleApp が正しい Rack レスポンス形式を返すことを確認する' do
      expect(result[:status]).to eq 200
      expect(result[:content_type]).to eq 'text/plain'
      expect(result[:body]).to eq 'Hello from SimpleApp'
    end

    it 'Lambda も Rack アプリとして動作することを確認する' do
      expect(result[:lambda_status]).to eq 200
      expect(result[:lambda_body]).to eq 'Hello from Lambda'
    end

    it 'Rack アプリが call メソッドに応答することを確認する' do
      expect(result[:app_responds_to_call]).to be true
      expect(result[:lambda_responds_to_call]).to be true
    end
  end

  describe '.demonstrate_middleware_wrapping' do
    let(:result) { described_class.demonstrate_middleware_wrapping }

    it 'ミドルウェアがレスポンスヘッダーに処理時間を追加することを確認する' do
      expect(result[:status]).to eq 200
      expect(result[:body]).to eq 'Inner App Response'
      expect(result[:has_runtime_header]).to be true
      expect(result[:runtime]).to match(/\A\d+\.\d+\z/)
    end
  end

  describe '.demonstrate_authentication' do
    let(:result) { described_class.demonstrate_authentication }

    it '正しいトークンで認証が成功することを確認する' do
      expect(result[:success_status]).to eq 200
      expect(result[:success_body]).to eq 'Authenticated: yes'
    end

    it '不正なトークンで 401 が返ることを確認する' do
      expect(result[:fail_status]).to eq 401
      expect(result[:fail_body]).to include('Unauthorized')
    end

    it '除外パスでは認証がスキップされることを確認する' do
      expect(result[:excluded_status]).to eq 200
    end
  end

  describe '.demonstrate_execution_order' do
    let(:result) { described_class.demonstrate_execution_order }

    it 'ミドルウェアが外側から内側へリクエストを処理することを確認する' do
      expected_order = %w[Outer:before Inner:before app Inner:after Outer:after]
      expect(result[:execution_order]).to eq expected_order
    end

    it 'リクエスト処理順序が Outer → Inner → App であることを確認する' do
      expect(result[:request_order]).to eq %w[Outer:before Inner:before app]
    end

    it 'レスポンス処理順序が Inner → Outer であることを確認する' do
      expect(result[:response_order]).to eq %w[Inner:after Outer:after]
    end
  end

  describe '.demonstrate_stack_building' do
    let(:result) { described_class.demonstrate_stack_building }

    it 'Rack::Builder で構築したスタックが正しく動作することを確認する' do
      expect(result[:status]).to eq 200
      expect(result[:body]).to eq 'Built with Rack::Builder'
      expect(result[:has_timing]).to be true
    end
  end

  describe '.demonstrate_request_response' do
    let(:result) { described_class.demonstrate_request_response }

    it 'Rack::Request がリクエスト情報を正しくパースすることを確認する' do
      expect(result[:status]).to eq 200
      expect(result[:content_type]).to eq 'application/json'
      expect(result[:method]).to eq 'GET'
      expect(result[:path]).to eq '/users'
      expect(result[:params]).to include('page' => '1', 'per' => '20')
    end

    it 'Rack::Response が Cookie ヘッダーを設定することを確認する' do
      expect(result[:has_cookie_header]).to be true
    end

    it 'User-Agent ヘッダーが正しく取得できることを確認する' do
      expect(result[:user_agent]).to eq 'TestAgent/1.0'
    end
  end

  describe '.demonstrate_streaming' do
    let(:result) { described_class.demonstrate_streaming }

    it 'ストリーミングボディがチャンクを逐次返すことを確認する' do
      expect(result[:status]).to eq 200
      expect(result[:chunk_count]).to eq 3
      expect(result[:chunks]).to eq %W[chunk-1\n chunk-2\n chunk-3\n]
      expect(result[:body_responds_to_each]).to be true
    end
  end

  describe '.demonstrate_response_transform' do
    let(:result) { described_class.demonstrate_response_transform }

    it 'レスポンスボディが変換されることを確認する' do
      expect(result[:status]).to eq 200
      expect(result[:body]).to eq 'HELLO WORLD'
    end

    it 'Content-Length が変換後のサイズに再計算されることを確認する' do
      expect(result[:length_matches]).to be true
      expect(result[:content_length].to_i).to eq 'HELLO WORLD'.bytesize
    end
  end

  # === ミドルウェアの直接テスト ===
  #
  # モジュールメソッド経由ではなく、ミドルウェアクラスを直接テストする。
  # Rack::MockRequest と lambda アプリを使用する。

  describe RackMiddleware::CorsMiddleware do
    let(:inner_app) { ->(_env) { [200, { 'content-type' => 'text/plain' }, ['OK']] } }
    let(:cors_app) { described_class.new(inner_app) }

    it 'OPTIONS プリフライトリクエストに 204 を返すことを確認する' do
      env = Rack::MockRequest.env_for('/api', method: 'OPTIONS')
      status, headers, _body = cors_app.call(env)

      expect(status).to eq 204
      expect(headers['access-control-allow-methods']).to include('GET', 'POST')
      expect(headers['access-control-allow-headers']).to include('Authorization')
    end

    it '通常リクエストに CORS ヘッダーを付与することを確認する' do
      env = Rack::MockRequest.env_for('/api', method: 'GET')
      status, headers, _body = cors_app.call(env)

      expect(status).to eq 200
      expect(headers['access-control-allow-origin']).to eq '*'
    end

    it '許可されたオリジンを正しく処理することを確認する' do
      restricted_app = described_class.new(inner_app, allowed_origins: ['https://example.com'])
      env = Rack::MockRequest.env_for('/api', method: 'GET')
      env['HTTP_ORIGIN'] = 'https://example.com'
      _status, headers, _body = restricted_app.call(env)

      expect(headers['access-control-allow-origin']).to eq 'https://example.com'
    end
  end

  describe RackMiddleware::RateLimitMiddleware do
    let(:inner_app) { ->(_env) { [200, { 'content-type' => 'text/plain' }, ['OK']] } }

    it '制限内のリクエストが成功し、ヘッダーにリミット情報が含まれることを確認する' do
      rate_app = described_class.new(inner_app, max_requests: 5, window_seconds: 60)
      env = Rack::MockRequest.env_for('/api')
      env['REMOTE_ADDR'] = '192.168.1.1'

      status, headers, _body = rate_app.call(env)

      expect(status).to eq 200
      expect(headers['x-ratelimit-limit']).to eq '5'
      expect(headers['x-ratelimit-remaining'].to_i).to be >= 0
    end

    it '制限を超えたリクエストが 429 を返すことを確認する' do
      rate_app = described_class.new(inner_app, max_requests: 2, window_seconds: 60)

      3.times do
        env = Rack::MockRequest.env_for('/api')
        env['REMOTE_ADDR'] = '10.0.0.1'
        status, headers, body = rate_app.call(env)

        next unless status == 429

        expect(headers['retry-after']).not_to be_nil
        body_str = +''
        body.each { |part| body_str << part }
        expect(body_str).to include('Too Many Requests')
      end

      # 3回目は必ず 429 になる
      env = Rack::MockRequest.env_for('/api')
      env['REMOTE_ADDR'] = '10.0.0.1'
      status, _headers, _body = rate_app.call(env)
      expect(status).to eq 429
    end
  end

  describe RackMiddleware::ConditionalMiddleware do
    let(:inner_app) { ->(_env) { [200, { 'content-type' => 'text/plain' }, ['OK']] } }

    it '条件に合致する場合にのみミドルウェアが適用されることを確認する' do
      # /api パスの場合のみ適用
      conditional_app = described_class.new(inner_app) do |env|
        env['PATH_INFO'].start_with?('/api')
      end

      # /api パスには適用される
      api_env = Rack::MockRequest.env_for('/api/users')
      _status, api_headers, _body = conditional_app.call(api_env)
      expect(api_headers['x-conditional']).to eq 'applied'

      # /health パスには適用されない
      health_env = Rack::MockRequest.env_for('/health')
      _status, health_headers, _body = conditional_app.call(health_env)
      expect(health_headers).not_to have_key('x-conditional')
    end
  end

  describe RackMiddleware::StackBuilder do
    describe '.build_mapped_stack' do
      let(:app) { described_class.build_mapped_stack }

      it 'map で定義したパスにルーティングされることを確認する' do
        # /health パスへのアクセス
        health_env = Rack::MockRequest.env_for('/health')
        status, _headers, body = app.call(health_env)
        body_str = +''
        body.each { |part| body_str << part }
        expect(status).to eq 200
        expect(body_str).to eq 'OK'
      end

      it '定義されていないパスに 404 が返ることを確認する' do
        env = Rack::MockRequest.env_for('/unknown')
        status, _headers, body = app.call(env)
        body_str = +''
        body.each { |part| body_str << part }
        expect(status).to eq 404
        expect(body_str).to eq 'Not Found'
      end
    end
  end
end
