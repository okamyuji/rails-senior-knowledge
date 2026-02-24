# frozen_string_literal: true

# Railsルーティングエンジン（Journey）の内部構造を解説するモジュール
#
# Railsのルーティングは ActionDispatch::Routing によって実装されており、
# 内部的には Journey と呼ばれるエンジンがルートの認識（recognition）と
# 生成（generation）を担当する。
#
# このモジュールでは、シニアエンジニアが知るべきルーティングの内部動作を
# ActionDispatch::Routing::RouteSet を直接操作して学ぶ。
#
# Journey エンジンの概要:
#   1. ルート定義 DSL (get, post, resources) → Route オブジェクト生成
#   2. 各ルートのパスパターンを AST（抽象構文木）にパース
#   3. AST から NFA（非決定性有限オートマトン）を構築
#   4. NFA をシミュレーションして受信パスをマッチング
#   5. マッチしたルートのパラメータを抽出

require 'action_dispatch'
require 'action_dispatch/routing'
require 'action_dispatch/routing/inspector'
require 'action_controller'

module RoutingInternals
  module_function

  # === ルート定義 DSL の内部動作 ===
  #
  # Rails の get, post, resources などの DSL メソッドは、内部的に
  # ActionDispatch::Routing::Mapper を通じて Route オブジェクトを生成する。
  #
  # 各 Route オブジェクトは以下の情報を保持する:
  #   - path: パスパターン（例: "/users/:id"）
  #   - conditions: HTTP メソッド、ホスト制約など
  #   - defaults: デフォルトパラメータ（controller, action など）
  #   - required_defaults: URL 生成時に必要なパラメータ
  #
  # resources :users は内部で以下の7つのルートに展開される:
  #   GET    /users          → users#index
  #   POST   /users          → users#create
  #   GET    /users/new      → users#new
  #   GET    /users/:id/edit → users#edit
  #   GET    /users/:id      → users#show
  #   PATCH  /users/:id      → users#update
  #   DELETE /users/:id      → users#destroy
  def demonstrate_route_definition_dsl
    routes = ActionDispatch::Routing::RouteSet.new

    # ダミーコントローラーを定義（ルーティングの解決に必要）
    stub_controller('users')
    stub_controller('posts')
    stub_controller('admin/dashboard')

    routes.draw do
      # 基本的な HTTP メソッド対応ルート
      get '/hello', to: 'users#index', as: :hello

      # 動的セグメント付きルート
      get '/users/:id', to: 'users#show', as: :user

      # POST ルート
      post '/users', to: 'users#create'

      # 名前空間付きルート
      namespace :admin do
        get '/dashboard', to: 'dashboard#index'
      end
    end

    # ルートテーブルの内部構造を確認
    route_entries = routes.routes.map do |route|
      {
        path: route.path.spec.to_s,
        verb: route.verb,
        controller: route.defaults[:controller],
        action: route.defaults[:action],
        name: route.name
      }
    end

    {
      # 定義されたルートの一覧
      route_count: routes.routes.size,
      route_entries: route_entries,
      # ルートオブジェクトの内部クラス
      route_class: routes.routes.first.class.name,
      # Journey::Routes コレクションのクラス
      routes_collection_class: routes.routes.class.name
    }
  end

  # === Journey NFA（非決定性有限オートマトン）の概念 ===
  #
  # Journey エンジンはルートマッチングに NFA（Non-deterministic Finite Automaton）
  # を使用する。これにより、数百〜数千のルートが定義されていても
  # 効率的にマッチングが行える。
  #
  # 処理の流れ:
  #   1. パスパターン "/users/:id" を AST にパース
  #      → Cat(Slash, Literal("users"), Slash, Symbol(:id))
  #   2. AST から NFA の状態遷移を構築
  #   3. 受信パス "/users/42" に対して NFA をシミュレーション
  #   4. 受理状態に到達したルートが候補として返される
  #
  # この方式により、単純な線形探索 O(n) よりも効率的に
  # マッチするルートを発見できる（ただし最悪ケースは同等）。
  def demonstrate_journey_nfa_concepts
    routes = ActionDispatch::Routing::RouteSet.new
    stub_controller('users')
    stub_controller('posts')

    routes.draw do
      get '/users', to: 'users#index'
      get '/users/:id', to: 'users#show'
      get '/posts/:post_id/comments', to: 'posts#comments'
    end

    # Journey の内部構造を確認
    journey_routes = routes.routes

    # 各ルートの AST（抽象構文木）を確認
    ast_info = journey_routes.map do |route|
      {
        path: route.path.spec.to_s,
        # パスパターンの AST ノードタイプ
        ast_class: route.path.spec.class.name,
        # AST の文字列表現
        ast_string: route.path.spec.to_s
      }
    end

    # Journey::Router の内部シミュレーターを確認
    router = routes.router

    {
      # Journey::Router がルートマッチングを担当
      router_class: router.class.name,
      # ルートの AST 情報
      ast_info: ast_info,
      # Journey::Routes コレクションのサイズ
      journey_routes_count: journey_routes.size,
      # ルーターがルートの集合を保持していることを確認
      router_has_routes: router.respond_to?(:routes)
    }
  end

  # === ルート認識（Route Recognition） ===
  #
  # ルート認識は、受信した HTTP リクエストのパスと HTTP メソッドから
  # 対応するルートとパラメータを特定するプロセスである。
  #
  # 内部的な処理:
  #   1. REQUEST_METHOD と PATH_INFO を Rack 環境から取得
  #   2. Journey::Router#serve がルートテーブルを検索
  #   3. NFA シミュレーションでマッチするルートを特定
  #   4. 動的セグメント（:id など）からパラメータを抽出
  #   5. 制約条件（constraints）をチェック
  #   6. マッチしたルートの controller#action にディスパッチ
  def demonstrate_route_recognition
    routes = ActionDispatch::Routing::RouteSet.new
    stub_controller('users')
    stub_controller('posts')
    stub_controller('articles')

    routes.draw do
      get '/users', to: 'users#index'
      get '/users/:id', to: 'users#show'
      post '/users', to: 'users#create'
      get '/posts/:year/:month', to: 'posts#archive'
      get '/articles/*path', to: 'articles#show'
    end

    # recognize_path でパスからルートパラメータを認識
    # これは Journey エンジンの recognize メソッドを内部的に呼び出す
    result_index = routes.recognize_path('/users', method: :get)
    result_show = routes.recognize_path('/users/42', method: :get)
    result_create = routes.recognize_path('/users', method: :post)
    result_archive = routes.recognize_path('/posts/2024/12', method: :get)
    result_glob = routes.recognize_path('/articles/tech/ruby/rails', method: :get)

    # 存在しないパスの認識は例外を発生させる
    unrecognized_error = begin
      routes.recognize_path('/nonexistent', method: :get)
      nil
    rescue ActionController::RoutingError => e
      e.message
    end

    {
      # 基本的なルート認識
      index_params: result_index,
      # 動的セグメントからのパラメータ抽出
      show_params: result_show,
      show_id: result_show[:id],
      # HTTP メソッドによる分岐
      create_params: result_create,
      # 複数の動的セグメント
      archive_params: result_archive,
      archive_year: result_archive[:year],
      archive_month: result_archive[:month],
      # ワイルドカードセグメント（glob）
      glob_params: result_glob,
      glob_path: result_glob[:path],
      # 認識エラー
      unrecognized_error: unrecognized_error
    }
  end

  # === ルート生成（Route Generation） ===
  #
  # ルート生成は、コントローラ名・アクション名・パラメータから
  # URL パスを生成するプロセスである。
  #
  # url_for や名前付きルートヘルパー（users_path など）は
  # 内部的に Journey::Router#generate を呼び出す。
  #
  # 生成の流れ:
  #   1. controller, action, その他のパラメータから候補ルートを特定
  #   2. 必須パラメータ（:id など）が揃っているか確認
  #   3. パスパターンのプレースホルダーを実際の値で置換
  #   4. 余剰パラメータはクエリ文字列として付加
  def demonstrate_route_generation
    routes = ActionDispatch::Routing::RouteSet.new
    stub_controller('users')
    stub_controller('posts')

    routes.draw do
      get '/users', to: 'users#index', as: :users
      get '/users/:id', to: 'users#show', as: :user
      get '/users/:id/edit', to: 'users#edit', as: :edit_user
      get '/posts/:year/:month', to: 'posts#archive', as: :posts_archive
    end

    # url_helpers モジュールを取得してパスヘルパーを使用
    url_helpers = routes.url_helpers

    # パス生成の各パターン
    # 名前付きルートヘルパーを使用したパス生成
    users_path = url_helpers.users_path
    user_path = url_helpers.user_path(id: 42)
    edit_user_path = url_helpers.edit_user_path(id: 42)
    archive_path = url_helpers.posts_archive_path(year: 2024, month: 12)

    # 余剰パラメータはクエリ文字列になる
    user_path_with_query = url_helpers.user_path(id: 42, format: :json, extra: 'value')

    {
      # 基本的なパス生成
      users_path: users_path,
      user_path: user_path,
      edit_user_path: edit_user_path,
      # 複数パラメータのパス生成
      archive_path: archive_path,
      # 余剰パラメータがクエリ文字列になる
      user_path_with_query: user_path_with_query
    }
  end

  # === ルート制約（Route Constraints） ===
  #
  # ルート制約は、パスがマッチするかどうかの追加条件を定義する。
  # 制約には以下の種類がある:
  #
  # 1. セグメント制約: 動的セグメントの値を正規表現で制限
  #    get "/users/:id", constraints: { id: /\d+/ }
  #
  # 2. リクエスト制約: リクエストオブジェクトの属性で制限
  #    get "/admin", constraints: { subdomain: "admin" }
  #
  # 3. Lambda 制約: Proc/Lambda でリクエスト全体を検査
  #    get "/api", constraints: ->(req) { req.headers["X-API-Key"].present? }
  #
  # 4. クラス制約: matches? メソッドを持つクラスで制約
  #    class AdminConstraint
  #      def matches?(request)
  #        request.remote_ip == "127.0.0.1"
  #      end
  #    end
  def demonstrate_route_constraints
    routes = ActionDispatch::Routing::RouteSet.new
    stub_controller('users')
    stub_controller('posts')
    stub_controller('api/v1/users')
    stub_controller('admin/dashboard')
    stub_controller('legacy')

    routes.draw do
      # セグメント制約: id は数字のみ
      get '/users/:id', to: 'users#show', as: :user_constrained,
                        constraints: { id: /\d+/ }

      # セグメント制約: year と month のフォーマット制限
      get '/posts/:year/:month', to: 'posts#archive', as: :posts_archive_constrained,
                                 constraints: { year: /\d{4}/, month: /\d{1,2}/ }

      # Lambda 制約を使ったルート（リクエストベース）
      # ※ recognize_path では Lambda 制約はスキップされる場合がある
      get '/api/v1/users', to: 'api/v1/users#index', as: :api_users

      # 制約付きの名前空間
      namespace :admin do
        get '/dashboard', to: 'dashboard#index'
      end

      # 制約なしの汎用ルート（フォールバック）
      get '/legacy/:path', to: 'legacy#show', as: :legacy_show
    end

    # セグメント制約のテスト
    # 数字の ID はマッチする
    numeric_id_result = routes.recognize_path('/users/42', method: :get)

    # 数字以外の ID はマッチしない（制約に引っかかる）
    non_numeric_error = begin
      routes.recognize_path('/users/abc', method: :get)
      nil
    rescue ActionController::RoutingError => e
      e.message
    end

    # 年月制約のテスト
    valid_archive = routes.recognize_path('/posts/2024/12', method: :get)
    invalid_archive = begin
      routes.recognize_path('/posts/24/123', method: :get)
      nil
    rescue ActionController::RoutingError => e
      e.message
    end

    {
      # セグメント制約: 数字IDは通過
      numeric_id_result: numeric_id_result,
      numeric_id_matched: numeric_id_result[:id] == '42',
      # セグメント制約: 非数字IDは拒否
      non_numeric_error: non_numeric_error,
      # 年月制約: 有効なフォーマットは通過
      valid_archive: valid_archive,
      # 年月制約: 無効なフォーマットは拒否
      invalid_archive_error: invalid_archive,
      # ルート制約の内部構造
      route_constraints_present: routes.routes.any? { |r| r.path.spec.to_s.include?(':id') }
    }
  end

  # === ルートグロビング（Wildcard Segments） ===
  #
  # グロブルート（*param）は、スラッシュを含む任意のパスセグメントに
  # マッチするワイルドカードセグメントを定義する。
  #
  # 用途:
  #   - CMS のページパス: get "/pages/*path", to: "pages#show"
  #   - ファイルブラウザ: get "/files/*filepath", to: "files#download"
  #   - フォールバックルート: get "/*path", to: "errors#not_found"
  #
  # オプショナルセグメント:
  #   get "/users/:id(.:format)", to: "users#show"
  #   → /users/42 と /users/42.json の両方にマッチ
  def demonstrate_route_globbing
    routes = ActionDispatch::Routing::RouteSet.new
    stub_controller('pages')
    stub_controller('files')
    stub_controller('docs')

    routes.draw do
      # グロブルート: 任意の深さのパスにマッチ
      get '/pages/*path', to: 'pages#show', as: :page

      # グロブルート + サフィックス
      get '/files/*filepath/download', to: 'files#download', as: :file_download

      # フォーマット付きルート（オプショナル）
      get '/docs/:id', to: 'docs#show', as: :doc
    end

    # グロブルートのマッチング
    page_result = routes.recognize_path('/pages/about', method: :get)
    deep_page_result = routes.recognize_path('/pages/tech/ruby/rails', method: :get)

    # グロブ + サフィックスのマッチング
    file_result = routes.recognize_path('/files/documents/report.pdf/download', method: :get)

    # フォーマット付きルート
    doc_result = routes.recognize_path('/docs/42', method: :get)
    doc_json_result = routes.recognize_path('/docs/42.json', method: :get)

    # パスヘルパーでのグロブルート生成
    url_helpers = routes.url_helpers
    generated_page_path = url_helpers.page_path(path: 'tech/ruby/rails')
    generated_file_path = url_helpers.file_download_path(filepath: 'docs/report.pdf')

    {
      # 単一セグメントのグロブ
      page_path: page_result[:path],
      # 複数セグメントのグロブ（スラッシュを含む）
      deep_page_path: deep_page_result[:path],
      # グロブ + サフィックス
      file_path: file_result[:filepath],
      # フォーマット制御
      doc_params: doc_result,
      doc_json_params: doc_json_result,
      # パス生成
      generated_page_path: generated_page_path,
      generated_file_path: generated_file_path
    }
  end

  # === マウントされたエンジン ===
  #
  # Rails エンジンは独立したルーティングテーブルを持ち、
  # ホストアプリケーションのルーティングにマウントされる。
  #
  # マウントの仕組み:
  #   1. エンジンの RouteSet が独立して定義される
  #   2. mount メソッドでホストアプリの特定のパスにマウント
  #   3. マウントポイント配下のリクエストはエンジンにディスパッチ
  #   4. エンジン内ではマウントポイントが SCRIPT_NAME として設定される
  #
  # これにより、エンジンのルートはホストアプリから分離され、
  # 名前空間の衝突を防ぐことができる。
  def demonstrate_mounted_engines
    # エンジン用の RouteSet を作成（擬似エンジン）
    engine_routes = ActionDispatch::Routing::RouteSet.new
    stub_controller('blog/posts')
    stub_controller('blog/comments')

    engine_routes.draw do
      get '/posts', to: 'blog/posts#index', as: :posts
      get '/posts/:id', to: 'blog/posts#show', as: :post
      get '/posts/:post_id/comments', to: 'blog/comments#index', as: :post_comments
    end

    # ホストアプリの RouteSet を作成
    host_routes = ActionDispatch::Routing::RouteSet.new
    stub_controller('home')

    # エンジンの Rack アプリとしてのマウント（簡易版）
    engine_app = engine_routes
    host_routes.draw do
      get '/', to: 'home#index', as: :root
      mount engine_app, at: '/blog'
    end

    # エンジン内のルートを確認
    engine_route_info = engine_routes.routes.map do |route|
      {
        path: route.path.spec.to_s,
        controller: route.defaults[:controller],
        action: route.defaults[:action]
      }
    end

    # ホストアプリのルートを確認
    host_route_info = host_routes.routes.map do |route|
      {
        path: route.path.spec.to_s,
        name: route.name
      }
    end

    # エンジン内のルート認識
    engine_post = engine_routes.recognize_path('/posts/5', method: :get)
    engine_comments = engine_routes.recognize_path('/posts/5/comments', method: :get)

    {
      # エンジンのルート定義
      engine_route_count: engine_routes.routes.size,
      engine_routes: engine_route_info,
      # ホストアプリのルート定義（マウントポイントを含む）
      host_route_count: host_routes.routes.size,
      host_routes: host_route_info,
      # エンジン内のルート認識
      engine_post_params: engine_post,
      engine_comments_params: engine_comments,
      # エンジンのルートセットは独立したオブジェクト
      separate_route_sets: !engine_routes.equal?(host_routes)
    }
  end

  # === ルートテーブルのプログラム的検査 ===
  #
  # 本番環境でのデバッグやモニタリングのために、
  # ルートテーブルをプログラム的に検査する方法を解説する。
  #
  # 主な検査方法:
  #   1. Rails.application.routes.routes でルート一覧を取得
  #   2. 各ルートの path, verb, defaults を確認
  #   3. ActionDispatch::Routing::Inspector で人間が読める形式に変換
  #   4. recognize_path で特定パスのルーティング先を確認
  #
  # rails routes コマンドは内部的に Inspector を使用している。
  def demonstrate_route_inspection
    routes = ActionDispatch::Routing::RouteSet.new
    stub_controller('users')
    stub_controller('posts')
    stub_controller('admin/settings')

    routes.draw do
      get '/users', to: 'users#index', as: :users
      get '/users/:id', to: 'users#show', as: :user
      post '/users', to: 'users#create'
      patch '/users/:id', to: 'users#update'
      delete '/users/:id', to: 'users#destroy'
      get '/posts', to: 'posts#index', as: :posts
      namespace :admin do
        get '/settings', to: 'settings#index', as: :settings
      end
    end

    # ルート一覧の詳細情報を取得
    route_details = routes.routes.map do |route|
      {
        name: route.name,
        verb: route.verb,
        path: route.path.spec.to_s,
        controller: route.defaults[:controller],
        action: route.defaults[:action],
        # 制約情報
        constraints: route.constraints.to_h,
        # 必須パラメータ
        required_parts: route.required_parts,
        # オプショナルパラメータ
        parts: route.parts
      }
    end

    # ActionDispatch::Routing::Inspector で整形された出力を取得
    inspector = ActionDispatch::Routing::RoutesInspector.new(routes.routes)
    formatted_routes = inspector.format(ActionDispatch::Routing::ConsoleFormatter::Sheet.new)

    # 特定のコントローラーのルートだけをフィルタリング
    users_routes = route_details.select { |r| r[:controller] == 'users' }

    # 名前付きルートの一覧
    named_routes = routes.named_routes.to_h.transform_values do |route|
      {
        path: route.path.spec.to_s,
        verb: route.verb
      }
    end

    {
      # 全ルート数
      total_routes: routes.routes.size,
      # ルートの詳細情報
      route_details: route_details,
      # コントローラーごとのフィルタリング
      users_route_count: users_routes.size,
      # 名前付きルートの一覧
      named_routes: named_routes,
      # rails routes コマンド相当の出力
      formatted_output: formatted_routes,
      # ルート検査に使えるメソッド群
      inspection_methods: {
        routes_method: routes.respond_to?(:routes),
        named_routes_method: routes.respond_to?(:named_routes),
        recognize_path_method: routes.respond_to?(:recognize_path)
      }
    }
  end

  # --- ヘルパーメソッド ---

  # テスト用のダミーコントローラーを動的に定義する
  # ActionDispatch のルーティングはコントローラークラスの存在を確認するため、
  # 最低限のコントローラークラスを生成する必要がある。
  def stub_controller(controller_path)
    parts = controller_path.split('/')
    class_name = parts.map { |p| p.split('_').map(&:capitalize).join }.join('::') + 'Controller'

    # すでに定義済みなら何もしない
    return if Object.const_defined?(class_name)

    # 名前空間モジュールを順次作成
    current = Object
    parts[0...-1].each do |part|
      mod_name = part.split('_').map(&:capitalize).join
      current.const_set(mod_name, Module.new) unless current.const_defined?(mod_name, false)
      current = current.const_get(mod_name)
    end

    # コントローラークラスを作成
    controller_class_name = "#{parts.last.split('_').map(&:capitalize).join}Controller"
    return if current.const_defined?(controller_class_name, false)

    controller_klass = Class.new(ActionController::Base)
    current.const_set(controller_class_name, controller_klass)
  end
end
