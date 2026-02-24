# Railsルーティング内部構造（Journeyエンジン）

## ルーティングの内部構造の理解が重要な理由

Railsのルーティングは単なるURLとコントローラーのマッピングではなく、高度に最適化されたパターンマッチングエンジンです。
シニアエンジニアがルーティングの内部構造を理解すべき理由は以下の通りです。

- パフォーマンスの最適化が可能になります。ルートの定義順序や制約の設計がアプリケーション全体のレスポンス速度に影響します
- 複雑なルーティング設計に対応できます。マルチテナント、APIバージョニング、サブドメインルーティングなどの高度な設計に必要です
- デバッグ能力が向上します。ルーティングエラーの原因を内部動作から特定できます
- エンジン設計に役立ちます。再利用可能なRailsエンジンのルーティング設計に不可欠です

## Journeyエンジンの仕組み（NFA）

### 概要

JourneyはRailsのルーティングエンジンであり、`ActionDispatch::Journey`
名前空間に実装されています。その核心はNFA（Non-deterministic Finite Automaton:
非決定性有限オートマトン）を用いたパスのパターンマッチングです。

### 処理の流れ

```text

1. ルート定義
   get "/users/:id", to: "users#show"
        ↓
2. パスパターンのパース（AST生成）
   Cat(Slash, Literal("users"), Slash, Symbol(:id))
        ↓
3. NFAの構築
   各ASTノードから状態遷移テーブルを生成します
        ↓
4. ルート認識（受信リクエスト時）
   "/users/42" → NFAシミュレーション → マッチしたルートを特定します
        ↓
5. パラメータ抽出
   :id → "42" をパラメータハッシュに格納します

```

### AST（抽象構文木）の構造

パスパターンは以下のノードタイプで表現されます。

| ノードタイプ | 説明 | 例
| ------------ | ------ | -----
| `Literal` | 固定文字列です | `"users"`
| `Symbol` | 動的セグメントです | `:id`
| `Slash` | パス区切りです | `/`
| `Star` | ワイルドカードです | `*path`
| `Group` | オプショナルセグメントです | `(.:format)`
| `Cat` | 連結（複数ノードの結合）です | 上記の組み合わせ

### NFAによるマッチングの利点

従来の単純な線形探索（各ルートを順番にチェック）と比較して、NFAベースのマッチングには以下の利点があります。

1. 共通プレフィックスを共有できます。`/users/:id` と `/users/:id/edit` は `/users` の部分を共有します
2. 早期の不一致検出が可能です。パスの先頭セグメントでマッチしないルートを即座に除外できます
3. 並列的な候補探索ができます。複数のルート候補を同時に追跡できます

```ruby

# 例：以下の3つのルートはNFAで効率的に処理されます

# GET /users          → users#index

# GET /users/:id      → users#show

# GET /users/:id/edit → users#edit

#

# "/users/42/edit" のマッチングの過程を以下に示します

#   1. "/" → 3つのルート全てが候補

#   2. "users" → 3つのルート全てが候補

#   3. "/" → users#index は脱落、2つが候補

#   4. "42" → :id にマッチ、2つが候補

#   5. "/" → users#show は脱落

#   6. "edit" → users#edit がマッチ

```

## ルート設計のベストプラクティス

### 1. ルートの定義順序を意識する

Railsはルートを定義順に評価します。より具体的なルートを先に定義し、汎用的なルートを後に配置します。

```ruby

Rails.application.routes.draw do
  # 具体的なルートを先に定義します
  get "/users/search", to: "users#search"
  get "/users/export", to: "users#export"

  # 汎用的なルートを後に定義します
  get "/users/:id", to: "users#show"

  # NG: この順序だと /users/search が :id = "search" として解釈されます
  # get "/users/:id", to: "users#show"
  # get "/users/search", to: "users#search"  # 到達不可能になります
end

```

### 2. RESTfulリソースを基本とする

`resources` と `resource` を活用し、カスタムルートは必要最小限にします。

```ruby

Rails.application.routes.draw do
  resources :users do
    # コレクションルート（/users/search）
    collection do
      get :search
      post :import
    end

    # メンバールート（/users/:id/activate）
    member do
      patch :activate
      patch :deactivate
    end

    # ネストされたリソース（浅いネスト推奨）
    resources :posts, shallow: true
  end
end

```

### 3. 名前空間とscopeを使い分ける

```ruby

Rails.application.routes.draw do
  # namespace: URLパス、コントローラー名前空間、ヘルパー名の全てにプレフィックスを付加します
  namespace :admin do
    resources :users  # Admin::UsersController, admin_users_path, /admin/users
  end

  # scope: URLパスのみにプレフィックスを付加します（コントローラーは変えない場合）
  scope "/api/v1" do
    resources :users  # UsersController, users_path, /api/v1/users
  end

  # scope module: コントローラーの名前空間のみ変更します
  scope module: :v2 do
    resources :users  # V2::UsersController, users_path, /users
  end
end

```

### 4. 制約を活用してルートの衝突を防ぐ

```ruby

Rails.application.routes.draw do
  # セグメント制約で明確にします
  get "/users/:id", to: "users#show", constraints: { id: /\d+/ }
  get "/users/:username", to: "users#profile", constraints: { username: /[a-z]+/ }

  # リクエスト制約でサブドメインルーティングを行います
  constraints subdomain: "api" do
    namespace :api do
      resources :users
    end
  end

  # カスタム制約クラスの例
  # class AuthenticatedConstraint
  #   def matches?(request)
  #     request.session[:user_id].present?
  #   end
  # end
  #
  # constraints AuthenticatedConstraint.new do
  #   resources :admin_settings
  # end
end

```

## カスタム制約

### Lambda制約

最もシンプルな制約方法です。リクエストオブジェクトを引数に取るProc/Lambdaを使用します。

```ruby

# ヘッダーベースの制約

api_constraint = ->(request) { request.headers["Accept"]&.include?("application/json") }

Rails.application.routes.draw do
  constraints api_constraint do
    get "/data", to: "api#data"
  end
end

```

### クラス制約

複雑なロジックや再利用性が必要な場合はクラスを使用します。`matches?` メソッドを実装する必要があります。

```ruby

class IpWhitelistConstraint
  ALLOWED_IPS = %w[192.168.1.0/24 10.0.0.0/8].freeze

  def matches?(request)
    ALLOWED_IPS.any? do |range|
      IPAddr.new(range).include?(request.remote_ip)
    end
  end
end

class SubdomainConstraint
  def initialize(subdomain)
    @subdomain = subdomain
  end

  def matches?(request)
    request.subdomain == @subdomain
  end
end

Rails.application.routes.draw do
  # IPホワイトリスト制約
  constraints IpWhitelistConstraint.new do
    namespace :internal do
      resources :metrics
    end
  end

  # サブドメイン制約
  constraints SubdomainConstraint.new("api") do
    scope module: :api do
      resources :users
    end
  end
end

```

### セグメント制約と正規表現

動的セグメントの値を正規表現で制限します。

```ruby

Rails.application.routes.draw do
  # 数値のみ
  get "/users/:id", to: "users#show", constraints: { id: /\d+/ }

  # UUID形式
  get "/items/:uuid", to: "items#show",
      constraints: { uuid: /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/ }

  # 日付形式
  get "/archive/:year/:month/:day", to: "archive#show",
      constraints: { year: /\d{4}/, month: /\d{1,2}/, day: /\d{1,2}/ }

  # 列挙値
  get "/status/:type", to: "status#show",
      constraints: { type: /active|inactive|pending/ }
end

```

## パフォーマンス考慮事項

### 1. ルート数の影響

ルート数が多いほどマッチングに時間がかかります。NFAによる最適化があるとはいえ、数千のルートがある場合はパフォーマンスに影響する可能性があります。

```ruby

# NG: 動的にルートを大量生成します

# 数千のルートを定義するとルーティング時間が増大します

100.times do |i|
  get "/feature_#{i}", to: "features#show_#{i}"
end

# OK: パラメータで処理を分岐します

get "/features/:name", to: "features#show", constraints: { name: /feature_\d+/ }

```

### 2. グロブルートの配置

グロブルート（`*path`）は最後に配置します。先に配置すると、後続のルートに到達できなくなります。

```ruby

Rails.application.routes.draw do
  resources :users
  resources :posts

  # グロブルートは必ず最後に配置します
  get "/*path", to: "errors#not_found"
end

```

### 3. 制約によるマッチングの効率化

制約を適切に設定することで、不要なルートの評価をスキップできます。

```ruby

# 制約なし: すべてのパスが :id にマッチし得ます

get "/users/:id", to: "users#show"

# 制約あり: 数字以外は即座にスキップされます

get "/users/:id", to: "users#show", constraints: { id: /\d+/ }

```

### 4. ルートキャッシュ

Railsはルートの認識結果をキャッシュしないため、リクエストごとにルートマッチングが実行されます。ただし、
NFAの構築自体はアプリケーション起動時に1回だけ行われます。

### 5. ルートヘルパーの生成コスト

名前付きルートを定義するたびに、対応するヘルパーメソッド（`*_path` と
`*_url`）が動的に生成されます。大量の名前付きルートがある場合、メモリ使用量に影響する可能性があります。

```ruby

# 名前付きルートの数を確認します

Rails.application.routes.named_routes.length

# 特定のルートのヘルパーが定義されているか確認します

Rails.application.routes.url_helpers.method_defined?(:users_path)

```

## ルーティングのデバッグ方法

### コマンドラインツール

```bash

# 全ルートの一覧を表示します

bin/rails routes

# コントローラーでフィルタリングします

bin/rails routes -c users

# 特定のパスがどのルートにマッチするか確認します

bin/rails routes -g /users/42

# 未使用ルートを検出します（Rails 8.0+）

bin/rails routes --unused

```

### プログラムからの検査

```ruby

# Railsコンソールでルートを確認します

Rails.application.routes.recognize_path("/users/42", method: :get)

# => { controller: "users", action: "show", id: "42" }

# ルートテーブルの詳細を表示します

Rails.application.routes.routes.each do |route|
  puts "#{route.verb.ljust(8)} #{route.path.spec.to_s.ljust(40)} #{route.defaults}"
end

# 名前付きルートの一覧を表示します

Rails.application.routes.named_routes.each do |name, route|
  puts "#{name}: #{route.path.spec}"
end

```

## 実行方法

```bash

# テストの実行

bundle exec rspec 16_routing_internals/routing_internals_spec.rb

# 個別のメソッドを試します

ruby -r ./16_routing_internals/routing_internals -e "pp RoutingInternals.demonstrate_route_definition_dsl"
ruby -r ./16_routing_internals/routing_internals -e "pp RoutingInternals.demonstrate_route_recognition"
ruby -r ./16_routing_internals/routing_internals -e "pp RoutingInternals.demonstrate_route_generation"

```
