# frozen_string_literal: true

require_relative 'api_design'

RSpec.describe ApiDesign do
  # === APIバージョニング ===

  describe ApiDesign::Versioning::UrlPathRouter do
    let(:router) do
      described_class.new(
        'v1' => :v1_handler,
        'v2' => :v2_handler
      )
    end

    it 'URLパスからバージョンを解決してハンドラを返す' do
      result = router.resolve('/api/v1/users')
      expect(result[:version]).to eq 'v1'
      expect(result[:handler]).to eq :v1_handler
      expect(result[:resource_path]).to eq '/users'
    end

    it 'サポートされていないバージョンではエラーを返す' do
      result = router.resolve('/api/v3/users')
      expect(result[:error]).to include('v3')
      expect(result[:available]).to eq %w[v1 v2]
    end
  end

  describe ApiDesign::Versioning::HeaderVersionResolver do
    let(:resolver) { described_class.new }

    it 'X-API-Versionヘッダからバージョンを解決する' do
      expect(resolver.resolve({ 'X-API-Version' => '2' })).to eq 'v2'
    end

    it 'ヘッダがない場合はデフォルトバージョンを返す' do
      expect(resolver.resolve({})).to eq 'v1'
    end
  end

  describe ApiDesign::Versioning::AcceptHeaderResolver do
    let(:resolver) { described_class.new(vendor: 'myapp') }

    it 'Acceptヘッダからバージョンとメディアタイプを解決する' do
      result = resolver.resolve('application/vnd.myapp.v2+json')
      expect(result[:version]).to eq 'v2'
      expect(result[:media_type]).to eq 'application/vnd.myapp.v2+json'
      expect(result[:vendor]).to eq 'myapp'
    end

    it '不正なAcceptヘッダではデフォルトバージョンを返す' do
      result = resolver.resolve('application/json')
      expect(result[:version]).to eq 'v1'
      expect(result[:default]).to be true
    end
  end

  # === シリアライゼーション ===

  describe ApiDesign::Serialization::BaseSerializer do
    # テスト用のシリアライザ定義
    let(:tag_serializer) do
      Class.new(described_class) do
        fields :id, :name
      end
    end

    let(:user_serializer) do
      tag_klass = tag_serializer
      Class.new(described_class) do
        fields :id, :name, :email

        field(:display_name) { |obj| "#{obj[:name]}様" }

        association :tags, serializer: tag_klass
      end
    end

    it '宣言されたフィールドをシリアライズする' do
      user = { id: 1, name: '田中太郎', email: 'tanaka@example.com', tags: [] }
      result = user_serializer.new(user).serialize

      expect(result[:id]).to eq 1
      expect(result[:name]).to eq '田中太郎'
      expect(result[:email]).to eq 'tanaka@example.com'
    end

    it '計算フィールドがブロックの結果を返す' do
      user = { id: 1, name: '田中太郎', email: 'tanaka@example.com', tags: [] }
      result = user_serializer.new(user).serialize

      expect(result[:display_name]).to eq '田中太郎様'
    end

    it '関連リソースをネストしてシリアライズする' do
      user = {
        id: 1,
        name: '田中太郎',
        email: 'tanaka@example.com',
        tags: [
          { id: 1, name: 'Ruby' },
          { id: 2, name: 'Rails' }
        ]
      }
      result = user_serializer.new(user).serialize

      expect(result[:tags]).to eq [
        { id: 1, name: 'Ruby' },
        { id: 2, name: 'Rails' }
      ]
    end

    it 'JSON文字列として出力できる' do
      user = { id: 1, name: 'テスト', email: 'test@example.com', tags: [] }
      json = user_serializer.new(user).to_json
      parsed = JSON.parse(json)

      expect(parsed['id']).to eq 1
      expect(parsed['name']).to eq 'テスト'
    end
  end

  describe ApiDesign::Serialization::CollectionSerializer do
    let(:serializer_class) do
      Class.new(ApiDesign::Serialization::BaseSerializer) do
        fields :id, :name
      end
    end

    it 'コレクション全体をシリアライズする' do
      items = [
        { id: 1, name: '項目1' },
        { id: 2, name: '項目2' },
        { id: 3, name: '項目3' }
      ]

      result = described_class.new(items, serializer: serializer_class).serialize

      expect(result.size).to eq 3
      expect(result.first[:id]).to eq 1
      expect(result.last[:name]).to eq '項目3'
    end
  end

  # === ページネーション ===

  describe ApiDesign::Pagination::OffsetPaginator do
    let(:collection) { (1..55).to_a }

    it '指定ページのデータとメタ情報を返す' do
      paginator = described_class.new(collection, page: 2, per_page: 20)
      result = paginator.paginate

      expect(result[:data]).to eq (21..40).to_a
      expect(result[:meta][:current_page]).to eq 2
      expect(result[:meta][:per_page]).to eq 20
      expect(result[:meta][:total_count]).to eq 55
      expect(result[:meta][:total_pages]).to eq 3
      expect(result[:meta][:has_next]).to be true
      expect(result[:meta][:has_prev]).to be true
    end

    it '最終ページでhas_nextがfalseになる' do
      paginator = described_class.new(collection, page: 3, per_page: 20)
      result = paginator.paginate

      expect(result[:data]).to eq (41..55).to_a
      expect(result[:meta][:has_next]).to be false
      expect(result[:meta][:has_prev]).to be true
    end

    it 'RFC 8288準拠のLinkヘッダを生成する' do
      paginator = described_class.new(collection, page: 2, per_page: 20)
      header = paginator.link_header('https://api.example.com/users')

      expect(header).to include('rel="next"')
      expect(header).to include('rel="prev"')
      expect(header).to include('rel="first"')
      expect(header).to include('rel="last"')
      expect(header).to include('page=3')
      expect(header).to include('page=1')
    end

    it 'per_pageがMAX_PER_PAGEを超えないように制限される' do
      paginator = described_class.new(collection, page: 1, per_page: 500)
      result = paginator.paginate

      expect(result[:meta][:per_page]).to eq 100
    end
  end

  describe ApiDesign::Pagination::CursorPaginator do
    let(:collection) do
      (1..10).map { |i| { id: i, name: "項目#{i}" } }
    end

    it 'カーソルなしで先頭からデータを返す' do
      paginator = described_class.new(collection, limit: 3)
      result = paginator.paginate

      expect(result[:data].size).to eq 3
      expect(result[:data].first[:id]).to eq 1
      expect(result[:cursors][:has_next]).to be true
      expect(result[:cursors][:after]).to eq 3
    end

    it 'カーソル指定で続きのデータを返す' do
      paginator = described_class.new(collection, cursor: 3, limit: 3)
      result = paginator.paginate

      expect(result[:data].first[:id]).to eq 4
      expect(result[:data].last[:id]).to eq 6
      expect(result[:cursors][:has_next]).to be true
    end

    it '最後のページでhas_nextがfalseになる' do
      paginator = described_class.new(collection, cursor: 7, limit: 5)
      result = paginator.paginate

      expect(result[:data].size).to eq 3
      expect(result[:cursors][:has_next]).to be false
      expect(result[:cursors][:after]).to be_nil
    end

    it 'カーソルのエンコード・デコードが往復可能である' do
      encoded = described_class.encode_cursor(42)
      decoded = described_class.decode_cursor(encoded)

      expect(decoded).to eq '42'
    end
  end

  # === レート制限 ===

  describe ApiDesign::RateLimiting::TokenBucket do
    it 'トークンがある間はリクエストを許可する' do
      bucket = described_class.new(capacity: 3, refill_rate: 1.0)

      result1 = bucket.allow_request?
      expect(result1[:allowed]).to be true
      expect(result1[:remaining]).to eq 2

      result2 = bucket.allow_request?
      expect(result2[:allowed]).to be true
      expect(result2[:remaining]).to eq 1
    end

    it 'トークンが枯渇するとリクエストを拒否する' do
      bucket = described_class.new(capacity: 2, refill_rate: 0.001)

      bucket.allow_request?
      bucket.allow_request?
      result = bucket.allow_request?

      expect(result[:allowed]).to be false
      expect(result[:remaining]).to eq 0
      expect(result[:retry_after]).to be_a(Float)
    end

    it 'レート制限ヘッダを正しく生成する' do
      bucket = described_class.new(capacity: 100, refill_rate: 10.0)
      result = bucket.allow_request?
      headers = described_class.rate_limit_headers(result)

      expect(headers['X-RateLimit-Limit']).to eq '100'
      expect(headers['X-RateLimit-Remaining']).to eq '99'
      expect(headers['X-RateLimit-Reset']).to match(/\A\d+\z/)
      expect(headers).not_to have_key('Retry-After')
    end

    it '拒否時にRetry-Afterヘッダを含める' do
      bucket = described_class.new(capacity: 1, refill_rate: 0.001)
      bucket.allow_request?
      result = bucket.allow_request?
      headers = described_class.rate_limit_headers(result)

      expect(headers).to have_key('Retry-After')
    end
  end

  describe ApiDesign::RateLimiting::SlidingWindowCounter do
    it 'ウィンドウ内のリクエスト上限まで許可する' do
      counter = described_class.new(max_requests: 3, window_seconds: 60)

      result1 = counter.allow_request?('client_1')
      expect(result1[:allowed]).to be true
      expect(result1[:remaining]).to eq 2

      counter.allow_request?('client_1')
      result3 = counter.allow_request?('client_1')
      expect(result3[:allowed]).to be true
      expect(result3[:remaining]).to eq 0
    end

    it '上限を超えるとリクエストを拒否する' do
      counter = described_class.new(max_requests: 2, window_seconds: 60)

      counter.allow_request?('client_1')
      counter.allow_request?('client_1')
      result = counter.allow_request?('client_1')

      expect(result[:allowed]).to be false
      expect(result[:remaining]).to eq 0
    end

    it 'クライアントごとに独立してカウントする' do
      counter = described_class.new(max_requests: 1, window_seconds: 60)

      counter.allow_request?('client_1')
      result = counter.allow_request?('client_2')

      expect(result[:allowed]).to be true
    end
  end

  # === エラーレスポンス ===

  describe ApiDesign::ErrorResponse::ErrorBuilder do
    it 'バリデーションエラーをRFC 7807準拠の形式で生成する' do
      error = described_class.validation_error(
        errors: [
          { field: 'email', message: 'は不正な形式です', code: 'invalid_format' },
          { field: 'name', message: 'は必須です', code: 'required' }
        ]
      )

      result = error.to_h
      expect(result[:type]).to eq 'https://api.example.com/errors/validation'
      expect(result[:title]).to eq 'バリデーションエラー'
      expect(result[:status]).to eq 422
      expect(result[:errors].size).to eq 2
      expect(result[:timestamp]).to be_a(String)
    end

    it '404エラーにリソース情報を含める' do
      error = described_class.not_found(
        detail: '指定されたユーザーが見つかりません',
        resource_type: 'User',
        resource_id: 123
      )

      result = error.to_h
      expect(result[:status]).to eq 404
      expect(result[:resource_type]).to eq 'User'
      expect(result[:resource_id]).to eq 123
    end

    it '認証エラーを生成する' do
      error = described_class.unauthorized
      expect(error.status).to eq 401
      expect(error.to_h[:detail]).to eq '認証が必要です'
    end

    it 'レート制限エラーにretry_afterを含める' do
      error = described_class.rate_limited(retry_after: 30)

      result = error.to_h
      expect(result[:status]).to eq 429
      expect(result[:retry_after]).to eq 30
      expect(result[:detail]).to include('30秒後')
    end

    it 'サーバー内部エラーにrequest_idを含める' do
      error = described_class.internal_error(request_id: 'req_abc123')

      result = error.to_h
      expect(result[:status]).to eq 500
      expect(result[:request_id]).to eq 'req_abc123'
      expect(result[:detail]).not_to include('スタックトレース')
    end

    it 'JSON文字列として出力できる' do
      error = described_class.unauthorized
      json = error.to_json
      parsed = JSON.parse(json)

      expect(parsed['status']).to eq 401
      expect(parsed['type']).to include('unauthorized')
    end
  end

  # === 認証 ===

  describe ApiDesign::Authentication::ApiKeyManager do
    let(:manager) { described_class.new }

    it 'APIキーを生成し認証できる' do
      key_info = manager.generate_key(name: 'テストアプリ', scopes: %w[read write])
      raw_key = key_info[:key]

      result = manager.authenticate(raw_key)
      expect(result[:authenticated]).to be true
      expect(result[:name]).to eq 'テストアプリ'
      expect(result[:scopes]).to eq %w[read write]
    end

    it '無効なキーで認証が失敗する' do
      result = manager.authenticate('sk_invalid_key')
      expect(result[:authenticated]).to be false
      expect(result[:error]).to include('無効')
    end

    it 'スコープ制限付きで認証を検証できる' do
      key_info = manager.generate_key(name: '読み取り専用', scopes: ['read'])
      raw_key = key_info[:key]

      read_result = manager.authenticate(raw_key, required_scope: 'read')
      expect(read_result[:authenticated]).to be true

      write_result = manager.authenticate(raw_key, required_scope: 'write')
      expect(write_result[:authenticated]).to be false
      expect(write_result[:error]).to include('write')
    end

    it 'キーを無効化できる' do
      key_info = manager.generate_key(name: '一時キー')
      raw_key = key_info[:key]

      expect(manager.revoke_key(raw_key)).to be true

      result = manager.authenticate(raw_key)
      expect(result[:authenticated]).to be false
    end
  end

  describe ApiDesign::Authentication::BearerTokenExtractor do
    it '有効なBearerトークンを抽出する' do
      result = described_class.extract('Bearer eyJhbGciOiJIUzI1NiJ9.test')
      expect(result[:valid]).to be true
      expect(result[:token]).to eq 'eyJhbGciOiJIUzI1NiJ9.test'
    end

    it 'Authorizationヘッダがない場合にエラーを返す' do
      result = described_class.extract(nil)
      expect(result[:valid]).to be false
      expect(result[:error]).to include('Authorizationヘッダ')
    end

    it 'Bearer以外の認証スキームでエラーを返す' do
      result = described_class.extract('Basic dXNlcjpwYXNz')
      expect(result[:valid]).to be false
      expect(result[:error]).to include('Bearer')
    end
  end

  # === HATEOAS ===

  describe ApiDesign::Hateoas::ResourceLinker do
    it '単一リソースにCRUDリンクを付与する' do
      resource = { id: 1, name: '田中太郎' }
      result = described_class.for_resource(
        resource: resource,
        type: 'users',
        id: 1,
        base_url: 'https://api.example.com/v1'
      )

      expect(result[:_links]['self'][:href]).to eq 'https://api.example.com/v1/users/1'
      expect(result[:_links]['collection'][:href]).to eq 'https://api.example.com/v1/users'
      expect(result[:_links]['update'][:method]).to eq 'PATCH'
      expect(result[:_links]['delete'][:method]).to eq 'DELETE'
      expect(result[:name]).to eq '田中太郎'
    end

    it 'コレクションにページネーションリンクを付与する' do
      items = [{ id: 1 }, { id: 2 }]
      result = described_class.for_collection(
        collection: items,
        type: 'users',
        base_url: 'https://api.example.com/v1',
        page: 2,
        total_pages: 5
      )

      expect(result[:_links]['self'][:href]).to include('page=2')
      expect(result[:_links]['next'][:href]).to include('page=3')
      expect(result[:_links]['prev'][:href]).to include('page=1')
      expect(result[:_links]['first'][:href]).to include('page=1')
      expect(result[:_links]['last'][:href]).to include('page=5')
      expect(result[:_embedded][:users]).to eq items
    end
  end

  # === 冪等性キー ===

  describe ApiDesign::Idempotency::IdempotencyKeyStore do
    let(:store) { described_class.new(ttl: 3600) }

    it '初回リクエストでブロックを実行しレスポンスを返す' do
      result = store.execute('key_001') { { payment_id: 'pay_123', amount: 1000 } }

      expect(result[:idempotent]).to be false
      expect(result[:response][:payment_id]).to eq 'pay_123'
    end

    it '同じキーの再リクエストでキャッシュされたレスポンスを返す' do
      store.execute('key_002') { { payment_id: 'pay_456' } }
      result = store.execute('key_002') { raise '二重実行されるべきではない' }

      expect(result[:idempotent]).to be true
      expect(result[:conflict]).to be false
      expect(result[:cached_response][:payment_id]).to eq 'pay_456'
    end

    it 'エラー発生時はキーを削除してリトライ可能にする' do
      expect do
        store.execute('key_003') { raise StandardError, '処理エラー' }
      end.to raise_error(StandardError, '処理エラー')

      # キーが削除されているので再実行可能
      result = store.execute('key_003') { { payment_id: 'pay_retry' } }
      expect(result[:idempotent]).to be false
      expect(result[:response][:payment_id]).to eq 'pay_retry'
    end

    it '保存されているキーの数を正しく返す' do
      store.execute('key_a') { :result_a }
      store.execute('key_b') { :result_b }

      expect(store.size).to eq 2
    end
  end
end
