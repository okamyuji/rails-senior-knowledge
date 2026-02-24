# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'digest'
require 'time'

# Rails API設計パターンを解説するモジュール
#
# RESTful APIの設計において、シニアエンジニアが知るべき
# バージョニング、シリアライゼーション、ページネーション、
# レート制限、エラーレスポンス、認証、HATEOAS、冪等性キーの
# 各パターンを実装例を通じて学ぶ。
module ApiDesign
  # =====================================================
  # APIバージョニング戦略
  # =====================================================
  #
  # APIのバージョニングには主に3つのアプローチがある：
  # 1. URLパスベース: /api/v1/users（最も一般的）
  # 2. HTTPヘッダベース: X-API-Version: 1
  # 3. Acceptヘッダベース: Accept: application/vnd.myapp.v1+json
  #
  # それぞれトレードオフがあり、プロジェクトの要件に応じて選択する。
  module Versioning
    # URLパスベースのバージョニングルーター
    #
    # 最も直感的で、ブラウザやcurlからも簡単にテストできる。
    # 欠点: URLがバージョン情報で汚染される。
    #
    # Railsでの実装例:
    #   namespace :api do
    #     namespace :v1 do
    #       resources :users
    #     end
    #     namespace :v2 do
    #       resources :users
    #     end
    #   end
    class UrlPathRouter
      # @param versions [Hash<String, Object>] バージョン名とハンドラのマッピング
      def initialize(versions = {})
        @versions = versions
      end

      # パスからバージョンを解決してハンドラを返す
      # @param path [String] リクエストパス（例: "/api/v1/users"）
      # @return [Hash] バージョン情報とハンドラ
      def resolve(path)
        version = extract_version(path)
        handler = @versions[version]

        if handler
          { version: version, handler: handler, resource_path: strip_version(path) }
        else
          { error: "サポートされていないAPIバージョン: #{version}", available: @versions.keys }
        end
      end

      private

      def extract_version(path)
        match = path.match(%r{/api/(v\d+)/})
        match ? match[1] : nil
      end

      def strip_version(path)
        path.sub(%r{/api/v\d+}, '')
      end
    end

    # HTTPヘッダベースのバージョニング
    #
    # URLをクリーンに保てるが、テストがやや面倒。
    # カスタムヘッダ X-API-Version を使用する。
    #
    # Railsでの実装例:
    #   class ApiConstraint
    #     def initialize(version:)
    #       @version = version
    #     end
    #
    #     def matches?(request)
    #       request.headers['X-API-Version'].to_i == @version
    #     end
    #   end
    class HeaderVersionResolver
      DEFAULT_VERSION = 'v1'

      # @param headers [Hash] HTTPヘッダ
      # @return [String] 解決されたバージョン文字列
      def resolve(headers)
        version = headers['X-API-Version'] || headers['x-api-version']
        version ? "v#{version}" : DEFAULT_VERSION
      end
    end

    # Acceptヘッダベースのバージョニング（コンテントネゴシエーション）
    #
    # HTTP仕様に最も準拠したアプローチ。
    # GitHub APIがこの方式を採用している。
    #
    # 例: Accept: application/vnd.myapp.v2+json
    class AcceptHeaderResolver
      # @param vendor [String] ベンダー名（例: "myapp"）
      def initialize(vendor: 'myapp')
        @vendor = vendor
        @pattern = %r{application/vnd\.#{Regexp.escape(vendor)}\.v(\d+)\+json}
      end

      # Acceptヘッダからバージョンを抽出する
      # @param accept_header [String] Acceptヘッダの値
      # @return [Hash] バージョン情報とメディアタイプ
      def resolve(accept_header)
        match = accept_header&.match(@pattern)
        if match
          version_num = match[1].to_i
          {
            version: "v#{version_num}",
            media_type: "application/vnd.#{@vendor}.v#{version_num}+json",
            vendor: @vendor
          }
        else
          { version: 'v1', media_type: 'application/json', vendor: @vendor, default: true }
        end
      end
    end
  end

  # =====================================================
  # シリアライゼーションパターン
  # =====================================================
  #
  # APIレスポンスのシリアライゼーションは、内部のドメインモデルを
  # クライアント向けのJSON表現に変換する重要な責務である。
  #
  # 主なGem:
  # - jbuilder: テンプレートベース（Railsデフォルト）
  # - blueprinter: 宣言的なDSL
  # - alba: 高速で柔軟なシリアライザ
  # - jsonapi-serializer: JSON:API仕様準拠
  module Serialization
    # 基本シリアライザパターン
    #
    # blueprinter/alba風の宣言的DSLをシンプルに再現する。
    # フィールドの選択、関連の展開、条件付きフィールドを実装。
    class BaseSerializer
      class << self
        # シリアライズするフィールドを宣言する
        # @param names [Array<Symbol>] フィールド名の一覧
        def fields(*names)
          @fields ||= []
          @fields.concat(names)
        end

        # 計算フィールドを宣言する（ブロックで値を生成）
        # @param name [Symbol] フィールド名
        # @param block [Proc] 値を計算するブロック
        def field(name, &block)
          @computed_fields ||= {}
          @computed_fields[name] = block
        end

        # 関連リソースのシリアライゼーションを宣言する
        # @param name [Symbol] 関連名
        # @param serializer [Class] 使用するシリアライザクラス
        def association(name, serializer:)
          @associations ||= {}
          @associations[name] = serializer
        end

        attr_reader :associations

        # 宣言されたフィールド一覧を返す（継承対応）
        def declared_fields
          parent_fields = superclass.respond_to?(:declared_fields) ? superclass.declared_fields : []
          parent_fields + (@fields || [])
        end

        # 宣言された計算フィールド一覧を返す
        def computed_fields
          parent_computed = superclass.respond_to?(:computed_fields) ? superclass.computed_fields : {}
          (parent_computed || {}).merge(@computed_fields || {})
        end

        # 宣言された関連一覧を返す
        def declared_associations
          parent_assoc = superclass.respond_to?(:declared_associations) ? superclass.declared_associations : {}
          (parent_assoc || {}).merge(@associations || {})
        end
      end

      # @param object [Object] シリアライズ対象のオブジェクト
      # @param options [Hash] オプション（コンテキスト情報など）
      def initialize(object, options = {})
        @object = object
        @options = options
      end

      # オブジェクトをハッシュにシリアライズする
      # @return [Hash] シリアライズされたハッシュ
      def serialize
        result = {}

        # 通常のフィールド
        self.class.declared_fields.each do |field_name|
          result[field_name] = extract_value(field_name)
        end

        # 計算フィールド
        self.class.computed_fields.each do |field_name, block|
          result[field_name] = instance_exec(@object, &block)
        end

        # 関連リソース
        self.class.declared_associations.each do |assoc_name, serializer_class|
          associated = extract_value(assoc_name)
          result[assoc_name] = if associated.is_a?(Array)
                                 associated.map { |item| serializer_class.new(item, @options).serialize }
                               elsif associated
                                 serializer_class.new(associated, @options).serialize
                               end
        end

        result
      end

      # JSON文字列として出力する
      # @return [String] JSON文字列
      def to_json(*_args)
        JSON.generate(serialize)
      end

      private

      def extract_value(field_name)
        if @object.is_a?(Hash)
          @object[field_name] || @object[field_name.to_s]
        elsif @object.respond_to?(field_name)
          @object.public_send(field_name)
        end
      end
    end

    # コレクションシリアライザ
    #
    # 配列やActiveRecord::Relationなどのコレクションをシリアライズする。
    class CollectionSerializer
      # @param collection [Enumerable] シリアライズ対象のコレクション
      # @param serializer [Class] 個別要素に使うシリアライザクラス
      # @param options [Hash] オプション
      def initialize(collection, serializer:, options: {})
        @collection = collection
        @serializer = serializer
        @options = options
      end

      # コレクション全体をシリアライズする
      # @return [Array<Hash>] シリアライズされたハッシュの配列
      def serialize
        @collection.map { |item| @serializer.new(item, @options).serialize }
      end

      def to_json(*_args)
        JSON.generate(serialize)
      end
    end
  end

  # =====================================================
  # ページネーションパターン
  # =====================================================
  #
  # 大量のデータを返すAPIでは、ページネーションが必須である。
  # 主に2つのアプローチがある：
  #
  # 1. オフセットベース: page=2&per_page=20（シンプルだが大量データで遅い）
  # 2. カーソルベース: after=cursor_value（高速で一貫性がある）
  #
  # Linkヘッダパターンを使うことで、クライアントに次/前ページの
  # URLを伝えることができる（GitHub API方式）。
  module Pagination
    # オフセットベースのページネーション
    #
    # 最もシンプルだが、大きなオフセットでは OFFSET クエリが遅くなる。
    # 総件数の計算も COUNT(*) が必要になるため、大規模テーブルでは注意。
    #
    # ActiveRecordでの典型的な使い方:
    #   User.order(:id).offset((page - 1) * per_page).limit(per_page)
    class OffsetPaginator
      DEFAULT_PER_PAGE = 20
      MAX_PER_PAGE = 100

      # @param collection [Array] ページネーション対象のコレクション
      # @param page [Integer] ページ番号（1始まり）
      # @param per_page [Integer] 1ページあたりの件数
      def initialize(collection, page: 1, per_page: DEFAULT_PER_PAGE)
        @collection = collection
        @page = [page.to_i, 1].max
        @per_page = per_page.to_i.clamp(1, MAX_PER_PAGE)
      end

      # 現在のページのデータを返す
      # @return [Hash] ページネーション結果とメタ情報
      def paginate
        total = @collection.size
        total_pages = (total.to_f / @per_page).ceil
        offset = (@page - 1) * @per_page
        items = @collection[offset, @per_page] || []

        {
          data: items,
          meta: {
            current_page: @page,
            per_page: @per_page,
            total_count: total,
            total_pages: total_pages,
            has_next: @page < total_pages,
            has_prev: @page > 1
          }
        }
      end

      # RFC 8288準拠のLinkヘッダを生成する
      # @param base_url [String] ベースURL
      # @return [String] Linkヘッダの値
      def link_header(base_url)
        result = paginate
        meta = result[:meta]
        links = []

        links << "<#{base_url}?page=#{@page + 1}&per_page=#{@per_page}>; rel=\"next\"" if meta[:has_next]

        links << "<#{base_url}?page=#{@page - 1}&per_page=#{@per_page}>; rel=\"prev\"" if meta[:has_prev]

        links << "<#{base_url}?page=1&per_page=#{@per_page}>; rel=\"first\""
        links << "<#{base_url}?page=#{meta[:total_pages]}&per_page=#{@per_page}>; rel=\"last\""

        links.join(', ')
      end
    end

    # カーソルベースのページネーション
    #
    # オフセットの問題を解決する。カーソル（通常はIDやタイムスタンプ）を
    # 起点として次のN件を取得する。
    #
    # 利点:
    # - ページ間でデータの追加/削除があっても一貫性がある
    # - OFFSET不要で大量データでも高速
    # - 無限スクロールUIとの相性が良い
    #
    # 欠点:
    # - 任意のページへのジャンプができない
    # - 総ページ数が不明
    #
    # ActiveRecordでの典型的な使い方:
    #   User.where('id > ?', cursor).order(:id).limit(limit + 1)
    class CursorPaginator
      DEFAULT_LIMIT = 20

      # @param collection [Array] ソート済みコレクション
      # @param cursor [Object, nil] カーソル値（前ページの最後の要素のID等）
      # @param limit [Integer] 取得件数
      # @param cursor_field [Symbol] カーソルに使うフィールド名
      def initialize(collection, cursor: nil, limit: DEFAULT_LIMIT, cursor_field: :id)
        @collection = collection
        @cursor = cursor
        @limit = limit
        @cursor_field = cursor_field
      end

      # カーソル位置以降のデータを返す
      # @return [Hash] ページネーション結果とカーソル情報
      def paginate
        # カーソル位置以降のデータをフィルタ
        filtered = if @cursor
                     @collection.select do |item|
                       value = item.is_a?(Hash) ? item[@cursor_field] : item.public_send(@cursor_field)
                       value > @cursor
                     end
                   else
                     @collection
                   end

        # limit + 1 件取得して次ページの有無を判定
        items = filtered.first(@limit + 1)
        has_next = items.size > @limit
        items = items.first(@limit) if has_next

        # 次のカーソル値を生成
        next_cursor = if has_next && items.last
                        last_item = items.last
                        last_item.is_a?(Hash) ? last_item[@cursor_field] : last_item.public_send(@cursor_field)
                      end

        {
          data: items,
          cursors: {
            after: next_cursor,
            has_next: has_next
          }
        }
      end

      # Base64エンコードされたカーソルを生成する（opaque cursor）
      #
      # カーソル値を直接公開するのではなく、Base64エンコードすることで
      # クライアントがカーソルの内部構造に依存するのを防ぐ。
      # @param value [Object] カーソル値
      # @return [String] エンコードされたカーソル文字列
      def self.encode_cursor(value)
        require 'base64'
        Base64.urlsafe_encode64(value.to_s, padding: false)
      end

      # Base64エンコードされたカーソルをデコードする
      # @param encoded [String] エンコードされたカーソル文字列
      # @return [String] デコードされたカーソル値
      def self.decode_cursor(encoded)
        require 'base64'
        Base64.urlsafe_decode64(encoded)
      end
    end
  end

  # =====================================================
  # レート制限
  # =====================================================
  #
  # APIの乱用を防ぎ、サービスの安定性を保つために
  # レート制限は不可欠である。
  #
  # 主なアルゴリズム:
  # 1. トークンバケット: トークンが一定レートで補充される
  # 2. スライディングウィンドウ: 直近N秒間のリクエスト数を計数
  # 3. 固定ウィンドウ: 時間枠ごとにカウンタをリセット
  #
  # レスポンスヘッダでクライアントに制限状況を通知する:
  #   X-RateLimit-Limit: 100
  #   X-RateLimit-Remaining: 95
  #   X-RateLimit-Reset: 1620000000
  module RateLimiting
    # トークンバケットアルゴリズム
    #
    # バケットにトークンが一定レートで補充され、リクエストごとに
    # トークンを1つ消費する。バケットが空ならリクエストを拒否する。
    #
    # 利点:
    # - バースト的なトラフィックを許容できる
    # - 実装がシンプル
    # - Redisとの相性が良い
    #
    # 本番環境ではRedisを使って分散環境でも一貫した制限を行う:
    #   rack-throttle, rack-attack などのGemが利用可能
    class TokenBucket
      # @param capacity [Integer] バケットの最大トークン数
      # @param refill_rate [Float] 1秒あたりのトークン補充数
      def initialize(capacity:, refill_rate:)
        @capacity = capacity
        @refill_rate = refill_rate
        @tokens = capacity.to_f
        @last_refill = Time.now
      end

      # リクエストを許可するかどうか判定し、トークンを消費する
      # @return [Hash] 許可/拒否の結果と残りトークン数
      def allow_request?
        refill_tokens

        if @tokens >= 1.0
          @tokens -= 1.0
          {
            allowed: true,
            remaining: @tokens.floor,
            limit: @capacity,
            reset_at: calculate_reset_time
          }
        else
          {
            allowed: false,
            remaining: 0,
            limit: @capacity,
            retry_after: calculate_retry_after,
            reset_at: calculate_reset_time
          }
        end
      end

      # レート制限のレスポンスヘッダを生成する
      # @param result [Hash] allow_request? の戻り値
      # @return [Hash] HTTPヘッダのハッシュ
      def self.rate_limit_headers(result)
        headers = {
          'X-RateLimit-Limit' => result[:limit].to_s,
          'X-RateLimit-Remaining' => result[:remaining].to_s,
          'X-RateLimit-Reset' => result[:reset_at].to_i.to_s
        }
        headers['Retry-After'] = result[:retry_after].ceil.to_s unless result[:allowed]
        headers
      end

      private

      # 経過時間に基づいてトークンを補充する
      def refill_tokens
        now = Time.now
        elapsed = now - @last_refill
        @tokens = [@tokens + (elapsed * @refill_rate), @capacity.to_f].min
        @last_refill = now
      end

      # バケットが満杯になる時刻を計算する
      def calculate_reset_time
        tokens_needed = @capacity - @tokens
        seconds_to_full = tokens_needed / @refill_rate
        Time.now + seconds_to_full
      end

      # 次のトークンが利用可能になるまでの秒数
      def calculate_retry_after
        (1.0 - @tokens) / @refill_rate
      end
    end

    # スライディングウィンドウカウンター
    #
    # 直近N秒間のリクエスト数を正確に計数する。
    # 固定ウィンドウの境界問題（ウィンドウ切り替え時にバーストが発生）を解決する。
    #
    # 本番ではRedisのSorted Setで実装することが多い:
    #   ZADD key timestamp timestamp
    #   ZREMRANGEBYSCORE key 0 (now - window)
    #   ZCARD key
    class SlidingWindowCounter
      # @param max_requests [Integer] ウィンドウ内の最大リクエスト数
      # @param window_seconds [Integer] ウィンドウサイズ（秒）
      def initialize(max_requests:, window_seconds:)
        @max_requests = max_requests
        @window_seconds = window_seconds
        @requests = {} # client_id => [timestamp, ...]
      end

      # クライアントのリクエストを記録し、制限を判定する
      # @param client_id [String] クライアント識別子
      # @return [Hash] 制限判定結果
      def allow_request?(client_id)
        now = Time.now
        cleanup_old_requests(client_id, now)

        @requests[client_id] ||= []
        current_count = @requests[client_id].size

        if current_count < @max_requests
          @requests[client_id] << now
          {
            allowed: true,
            remaining: @max_requests - current_count - 1,
            limit: @max_requests,
            window_seconds: @window_seconds
          }
        else
          oldest = @requests[client_id].first
          retry_after = oldest ? (oldest + @window_seconds - now) : @window_seconds
          {
            allowed: false,
            remaining: 0,
            limit: @max_requests,
            retry_after: [retry_after, 0].max,
            window_seconds: @window_seconds
          }
        end
      end

      private

      # ウィンドウ外の古いリクエスト記録を削除する
      def cleanup_old_requests(client_id, now)
        return unless @requests[client_id]

        cutoff = now - @window_seconds
        @requests[client_id].reject! { |timestamp| timestamp < cutoff }
      end
    end
  end

  # =====================================================
  # エラーレスポンス設計
  # =====================================================
  #
  # 一貫した構造のエラーレスポンスは、API利用者の開発体験を大きく向上させる。
  #
  # 良いエラーレスポンスの要件:
  # 1. HTTPステータスコードが適切
  # 2. マシンリーダブルなエラーコード
  # 3. 人間が読めるメッセージ
  # 4. デバッグに役立つ詳細情報
  # 5. ドキュメントへのリンク
  #
  # RFC 7807 (Problem Details for HTTP APIs) に準拠した形式を推奨:
  #   {
  #     "type": "https://api.example.com/errors/validation",
  #     "title": "Validation Error",
  #     "status": 422,
  #     "detail": "リクエストパラメータが不正です",
  #     "errors": [...]
  #   }
  module ErrorResponse
    # 構造化エラーレスポンスビルダー
    #
    # RFC 7807準拠のエラーレスポンスを構築する。
    # Railsの rescue_from と組み合わせて使用する。
    #
    # 使用例（Railsコントローラ内）:
    #   rescue_from ActiveRecord::RecordNotFound do |e|
    #     error = ApiDesign::ErrorResponse::ErrorBuilder.not_found(
    #       detail: "#{e.model}が見つかりません",
    #       id: e.id
    #     )
    #     render json: error.to_h, status: error.status
    #   end
    class ErrorBuilder
      attr_reader :status

      # @param type [String] エラータイプURI
      # @param title [String] エラータイトル
      # @param status [Integer] HTTPステータスコード
      # @param detail [String] 詳細メッセージ
      # @param errors [Array, nil] バリデーションエラーの配列
      # @param meta [Hash] 追加のメタ情報
      def initialize(type:, title:, status:, detail:, errors: nil, meta: {})
        @type = type
        @title = title
        @status = status
        @detail = detail
        @errors = errors
        @meta = meta
      end

      # エラーレスポンスをハッシュに変換する
      # @return [Hash] RFC 7807準拠のエラーハッシュ
      def to_h
        response = {
          type: @type,
          title: @title,
          status: @status,
          detail: @detail,
          timestamp: Time.now.iso8601
        }
        response[:errors] = @errors if @errors
        response.merge!(@meta) unless @meta.empty?
        response
      end

      def to_json(*_args)
        JSON.generate(to_h)
      end

      # バリデーションエラー（422 Unprocessable Entity）
      # @param errors [Array<Hash>] フィールドごとのエラー詳細
      # @return [ErrorBuilder]
      def self.validation_error(errors:)
        new(
          type: 'https://api.example.com/errors/validation',
          title: 'バリデーションエラー',
          status: 422,
          detail: 'リクエストパラメータに不正な値が含まれています',
          errors: errors
        )
      end

      # リソース未検出エラー（404 Not Found）
      # @param detail [String] 詳細メッセージ
      # @param resource_type [String] リソースタイプ名
      # @param resource_id [Object] リソースID
      # @return [ErrorBuilder]
      def self.not_found(detail:, resource_type: nil, resource_id: nil)
        meta = {}
        meta[:resource_type] = resource_type if resource_type
        meta[:resource_id] = resource_id if resource_id

        new(
          type: 'https://api.example.com/errors/not-found',
          title: 'リソースが見つかりません',
          status: 404,
          detail: detail,
          meta: meta
        )
      end

      # 認証エラー（401 Unauthorized）
      # @param detail [String] 詳細メッセージ
      # @return [ErrorBuilder]
      def self.unauthorized(detail: '認証が必要です')
        new(
          type: 'https://api.example.com/errors/unauthorized',
          title: '認証エラー',
          status: 401,
          detail: detail
        )
      end

      # レート制限超過エラー（429 Too Many Requests）
      # @param retry_after [Integer] リトライまでの秒数
      # @return [ErrorBuilder]
      def self.rate_limited(retry_after:)
        new(
          type: 'https://api.example.com/errors/rate-limited',
          title: 'レート制限超過',
          status: 429,
          detail: "リクエスト数が上限を超えました。#{retry_after}秒後に再試行してください",
          meta: { retry_after: retry_after }
        )
      end

      # サーバー内部エラー（500 Internal Server Error）
      #
      # 本番環境ではスタックトレースなどの内部情報を含めてはならない。
      # @param request_id [String] リクエストID（問い合わせ用）
      # @return [ErrorBuilder]
      def self.internal_error(request_id: nil)
        meta = {}
        meta[:request_id] = request_id if request_id

        new(
          type: 'https://api.example.com/errors/internal',
          title: 'サーバー内部エラー',
          status: 500,
          detail: '予期しないエラーが発生しました。問題が継続する場合はサポートにお問い合わせください',
          meta: meta
        )
      end
    end
  end

  # =====================================================
  # 認証パターン
  # =====================================================
  #
  # API認証には主に以下のアプローチがある:
  # 1. APIキー: シンプルだがセキュリティは限定的
  # 2. Bearer Token (JWT): ステートレスで拡張性が高い
  # 3. OAuth 2.0: サードパーティ連携に最適
  #
  # いずれの場合も、HTTPS必須、トークンの有効期限設定、
  # 適切なスコープ管理が重要である。
  module Authentication
    # APIキー管理
    #
    # APIキーは最もシンプルな認証方式。
    # サーバーサイドのみ（B2B API等）で使用する場合に適している。
    #
    # セキュリティ上の注意:
    # - キーはハッシュ化して保存する（平文で保存しない）
    # - キーにはスコープ（権限）を設定する
    # - キーのローテーション機能を提供する
    # - レート制限をキーごとに設定する
    class ApiKeyManager
      # @param keys [Hash] APIキーとメタ情報のマッピング
      def initialize(keys = {})
        @keys = keys # { hashed_key => { name:, scopes:, expires_at: } }
      end

      # 新しいAPIキーを生成し登録する
      # @param name [String] キーの名前（識別用）
      # @param scopes [Array<String>] 許可するスコープ
      # @param expires_in [Integer, nil] 有効期限（秒、nilで無期限）
      # @return [Hash] 生成されたキー情報（平文キーはこの時だけ返す）
      def generate_key(name:, scopes: ['read'], expires_in: nil)
        raw_key = "sk_#{SecureRandom.hex(24)}"
        hashed = hash_key(raw_key)
        expires_at = expires_in ? Time.now + expires_in : nil

        @keys[hashed] = {
          name: name,
          scopes: scopes,
          created_at: Time.now,
          expires_at: expires_at
        }

        {
          key: raw_key,
          name: name,
          scopes: scopes,
          expires_at: expires_at,
          warning: 'このキーは再表示できません。安全に保管してください。'
        }
      end

      # APIキーを検証する
      # @param raw_key [String] 検証するAPIキー（平文）
      # @param required_scope [String, nil] 必要なスコープ
      # @return [Hash] 検証結果
      def authenticate(raw_key, required_scope: nil)
        hashed = hash_key(raw_key)
        key_info = @keys[hashed]

        return { authenticated: false, error: '無効なAPIキーです' } unless key_info

        if key_info[:expires_at] && Time.now > key_info[:expires_at]
          return { authenticated: false, error: 'APIキーの有効期限が切れています' }
        end

        if required_scope && !key_info[:scopes].include?(required_scope)
          return { authenticated: false, error: "スコープ '#{required_scope}' が許可されていません" }
        end

        { authenticated: true, name: key_info[:name], scopes: key_info[:scopes] }
      end

      # APIキーを無効化する
      # @param raw_key [String] 無効化するAPIキー
      # @return [Boolean] 無効化に成功したかどうか
      def revoke_key(raw_key)
        hashed = hash_key(raw_key)
        !!@keys.delete(hashed)
      end

      private

      # APIキーをSHA256でハッシュ化する
      def hash_key(raw_key)
        Digest::SHA256.hexdigest(raw_key)
      end
    end

    # Bearerトークン認証ヘルパー
    #
    # Authorizationヘッダからトークンを抽出する。
    # 実際のJWT検証は専用のGem（ruby-jwt等）を使う。
    #
    # Railsでの使用例:
    #   class ApplicationController < ActionController::API
    #     before_action :authenticate_token!
    #
    #     private
    #
    #     def authenticate_token!
    #       result = BearerTokenExtractor.extract(request.headers['Authorization'])
    #       unless result[:valid]
    #         render json: { error: result[:error] }, status: :unauthorized
    #       end
    #     end
    #   end
    class BearerTokenExtractor
      BEARER_PATTERN = /\ABearer\s+(.+)\z/i

      # Authorizationヘッダからトークンを抽出する
      # @param authorization_header [String, nil] Authorizationヘッダの値
      # @return [Hash] 抽出結果
      def self.extract(authorization_header)
        return { valid: false, error: 'Authorizationヘッダがありません' } unless authorization_header

        match = authorization_header.match(BEARER_PATTERN)
        return { valid: false, error: 'Bearer トークン形式が不正です' } unless match

        token = match[1]
        return { valid: false, error: 'トークンが空です' } if token.strip.empty?

        { valid: true, token: token }
      end
    end
  end

  # =====================================================
  # HATEOASパターン
  # =====================================================
  #
  # HATEOAS (Hypermedia As The Engine Of Application State) は
  # RESTの成熟度モデルにおけるLevel 3に相当する。
  #
  # レスポンスにハイパーメディアリンクを含めることで、
  # クライアントがAPIのナビゲーションを動的に行えるようにする。
  #
  # 完全なHATEOAS実装は稀だが、関連リソースへのリンクを含めることは
  # API利用者の利便性を大きく向上させる。
  module Hateoas
    # HATEOASリンクビルダー
    #
    # APIレスポンスにハイパーメディアリンクを追加する。
    # HAL (Hypertext Application Language) 形式に近い構造を採用。
    class LinkBuilder
      # @param base_url [String] APIのベースURL
      def initialize(base_url)
        @base_url = base_url
        @links = {}
      end

      # リンクを追加する
      # @param rel [String] リンク関係（self, next, prev, related 等）
      # @param path [String] リソースパス
      # @param method [String] HTTPメソッド
      # @param title [String, nil] リンクの説明
      # @return [self]
      def add(rel:, path:, method: 'GET', title: nil)
        link = { href: "#{@base_url}#{path}", method: method }
        link[:title] = title if title
        @links[rel] = link
        self
      end

      # 構築されたリンクハッシュを返す
      # @return [Hash] リンクのハッシュ
      def build
        @links.dup
      end

      # リソースレスポンスにリンクをマージする
      # @param resource [Hash] リソースのハッシュ
      # @return [Hash] リンクが追加されたリソースハッシュ
      def wrap(resource)
        resource.merge(_links: build)
      end
    end

    # リソースにHATEOASリンクを付与するヘルパー
    #
    # 典型的な使用パターン:
    #   user_data = UserSerializer.new(user).serialize
    #   response = ResourceLinker.for_resource(
    #     resource: user_data,
    #     type: 'users',
    #     id: user.id,
    #     base_url: 'https://api.example.com/v1'
    #   )
    module ResourceLinker
      module_function

      # 単一リソースにCRUDリンクを付与する
      # @param resource [Hash] リソースデータ
      # @param type [String] リソースタイプ（例: "users"）
      # @param id [Object] リソースID
      # @param base_url [String] ベースURL
      # @return [Hash] リンク付きリソース
      def for_resource(resource:, type:, id:, base_url:)
        builder = LinkBuilder.new(base_url)
        builder
          .add(rel: 'self', path: "/#{type}/#{id}", title: 'このリソース')
          .add(rel: 'collection', path: "/#{type}", title: "#{type}一覧")
          .add(rel: 'update', path: "/#{type}/#{id}", method: 'PATCH', title: '更新')
          .add(rel: 'delete', path: "/#{type}/#{id}", method: 'DELETE', title: '削除')

        builder.wrap(resource)
      end

      # コレクションにページネーションリンクを付与する
      # @param collection [Array] コレクションデータ
      # @param type [String] リソースタイプ
      # @param base_url [String] ベースURL
      # @param page [Integer] 現在のページ
      # @param total_pages [Integer] 総ページ数
      # @return [Hash] リンク付きコレクション
      def for_collection(collection:, type:, base_url:, page:, total_pages:)
        builder = LinkBuilder.new(base_url)
        builder.add(rel: 'self', path: "/#{type}?page=#{page}")

        builder.add(rel: 'next', path: "/#{type}?page=#{page + 1}") if page < total_pages

        builder.add(rel: 'prev', path: "/#{type}?page=#{page - 1}") if page > 1

        builder.add(rel: 'first', path: "/#{type}?page=1")
        builder.add(rel: 'last', path: "/#{type}?page=#{total_pages}")

        {
          _links: builder.build,
          _embedded: { type.to_sym => collection },
          total_pages: total_pages,
          current_page: page
        }
      end
    end
  end

  # =====================================================
  # 冪等性キーパターン
  # =====================================================
  #
  # POST、PATCHなどの非冪等なリクエストにおいて、
  # ネットワーク障害等による重複実行を防ぐためのパターン。
  #
  # クライアントがリクエストに一意なキーを付与し、
  # サーバーがそのキーに対応するレスポンスをキャッシュする。
  # 同じキーで再度リクエストが来た場合、キャッシュされたレスポンスを返す。
  #
  # Stripe API がこのパターンの代表的な実装例:
  #   Idempotency-Key: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  module Idempotency
    # 冪等性キーストア
    #
    # 冪等性キーとレスポンスの対応を管理する。
    # 本番環境ではRedisなどの分散キャッシュを使用する。
    #
    # Railsでの使用例:
    #   class PaymentsController < ApplicationController
    #     before_action :check_idempotency_key, only: [:create]
    #
    #     def create
    #       result = PaymentService.charge(params)
    #       store_idempotent_response(result)
    #       render json: result
    #     end
    #   end
    class IdempotencyKeyStore
      # @param ttl [Integer] キーの有効期限（秒）
      # デフォルト24時間
      def initialize(ttl: 86_400)
        @store = {}
        @ttl = ttl
      end

      # 冪等性キーを処理する
      #
      # キーが既に存在する場合:
      # - 処理中なら競合エラーを返す
      # - 完了済みならキャッシュされたレスポンスを返す
      #
      # キーが存在しない場合:
      # - "processing" として登録し、ブロックを実行する
      # - 実行結果をキャッシュして返す
      #
      # @param key [String] 冪等性キー
      # @yield 実際の処理ブロック
      # @return [Hash] 処理結果
      def execute(key, &block)
        cleanup_expired

        if @store.key?(key)
          entry = @store[key]
          if entry[:status] == 'processing'
            return {
              idempotent: true,
              conflict: true,
              error: 'このリクエストは現在処理中です。しばらく待ってから再試行してください'
            }
          end

          return {
            idempotent: true,
            conflict: false,
            cached_response: entry[:response],
            original_created_at: entry[:created_at]
          }
        end

        # 処理中として登録
        @store[key] = { status: 'processing', created_at: Time.now }

        begin
          response = block.call
          @store[key] = {
            status: 'completed',
            response: response,
            created_at: @store[key][:created_at],
            completed_at: Time.now
          }
          { idempotent: false, response: response }
        rescue StandardError => e
          # エラー時はキーを削除してリトライ可能にする
          @store.delete(key)
          raise e
        end
      end

      # 保存されているキーの数を返す
      # @return [Integer] キー数
      def size
        cleanup_expired
        @store.size
      end

      private

      # 有効期限切れのエントリを削除する
      def cleanup_expired
        cutoff = Time.now - @ttl
        @store.reject! { |_key, entry| entry[:created_at] < cutoff }
      end
    end
  end
end
