# Rails 8 認証（Authentication）

## なぜRails 8認証ジェネレータの理解が重要か

Rails 8では`bin/rails generate
authentication`コマンドにより、Deviseなどの外部gemに依存しない認証機能のスキャフォールドが生成されるようになりました。
これはDHHが提唱する「Railsが必要なものはすべてRailsが提供する」という哲学の具現化です。

シニアエンジニアが認証の内部動作を深く理解すべき理由は以下の通りです。

- セキュリティリスクの理解:
  パスワードハッシュ化、トークン管理、タイミング攻撃対策など、認証におけるセキュリティの基本原理を理解していなければ、脆弱性を見逃す可能性があります
- カスタマイズ能力: Rails 8の認証は生成されたコードを直接編集する設計であり、コードの意図を理解していなければ安全にカスタマイズできません
- トラブルシューティング: セッション消失、パスワードリセット失敗、レート制限誤動作などの問題を素早く特定するには内部動作の理解が不可欠です
- Deviseからの移行判断: 既存プロジェクトでDeviseを使っている場合、Rails 8組み込み認証への移行が適切かどうかを判断できます

## Rails 8認証ジェネレータの仕組み

### 生成されるファイル構成

`bin/rails generate authentication`を実行すると、以下のファイルが生成されます。

```text

app/
├── models/
│   ├── user.rb              # has_secure_passwordを使用
│   ├── session.rb           # セッショントークン管理
│   └── current.rb           # CurrentAttributesパターン
├── controllers/
│   ├── sessions_controller.rb     # ログイン/ログアウト
│   ├── passwords_controller.rb    # パスワードリセット
│   └── concerns/
│       └── authentication.rb      # 認証concern
├── views/
│   ├── sessions/
│   │   └── new.html.erb     # ログインフォーム
│   └── passwords/
│       ├── new.html.erb     # パスワードリセット要求
│       └── edit.html.erb    # 新パスワード設定
├── mailers/
│   └── passwords_mailer.rb  # パスワードリセットメール
db/
└── migrate/
    ├── xxx_create_users.rb
    └── xxx_create_sessions.rb

```

### 認証フローの全体像

```text

ログインフロー:
  ブラウザ → SessionsController#create
    → User.find_by(email_address:)
    → user.authenticate(password)    # BCryptで検証
    → Session.create!(user:)         # セッションレコード作成
    → cookies.signed[:session_token] = session.token  # Cookie設定
    → リダイレクト

リクエスト認証:
  ブラウザ → ApplicationController (before_action)
    → cookies.signed[:session_token]を取得
    → Session.find_by(token:)        # DBからセッション検索
    → Current.session = session       # Currentに設定
    → Current.userで参照可能

ログアウト:
  ブラウザ → SessionsController#destroy
    → Current.session.destroy         # DBからセッション削除
    → cookies.delete(:session_token)  # Cookie削除

```

## BCryptとパスワードハッシュ化

### BCryptハッシュの構造

```text

$2a$12$LJ3m4ys3L7gFpE3Rk5dMRuXMEJqDvsmBWFHGV2BIfM8Cg7YFlJYJm
|  |  |
|  | +--- ソルト（22文字）+ ハッシュ本体（31文字）
 |  +------ コストファクター（2^12 = 4096回の繰り返し）
 +--------- アルゴリズムバージョン（2a = BCrypt）

```

### has_secure_passwordの内部動作

```ruby

class User < ApplicationRecord
  has_secure_password
  # 上記マクロは以下と等価です:
  #
  # attr_reader :password
  #
  # validates :password, presence: true, on: :create
  # validates :password, length: { maximum: 72 }
  # validates :password_confirmation,
  #           presence: true, if: :password_confirmation
  #
  # def password=(unencrypted_password)
  #   if unencrypted_password.present?
  #     @password = unencrypted_password
  #     self.password_digest = BCrypt::Password.create(
  #       unencrypted_password,
  #       cost: BCrypt::Engine.cost  # デフォルト12
  #     )
  #   end
  # end
  #
  # def authenticate(unencrypted_password)
  #   BCrypt::Password.new(password_digest).is_password?(unencrypted_password) && self
  # end
end

```

### セキュリティ上の注意点

- コストファクター: 本番環境では最低12（デフォルト）を推奨します。テスト環境では4に下げて高速化します
- 72バイト制限: BCryptは72バイトを超えるパスワードを切り捨てます。長いパスワードが必要な場合は事前にSHA-256でハッシュ化します
- タイミング攻撃: `authenticate`メソッドはBCryptの比較を使うため、自動的にタイミングセーフです

## セッション管理

### トークンベースのセッション

Rails 8の認証ではセッション情報をデータベースに保存します。

```ruby

class Session < ApplicationRecord
  belongs_to :user

  # 256ビットのランダムトークンを生成します
  before_create -> { self.token = SecureRandom.urlsafe_base64(32) }

  # Cookieにはトークンのみを保存します
  # cookies.signed[:session_token] = session.token
end

```

### セッション管理のベストプラクティス

| 項目 | 推奨設定
| ------ | ---------
| トークン長 | 256ビット以上（`SecureRandom.urlsafe_base64(32)`）
| Cookie設定 | `httponly: true, secure: true, same_site: :lax`
| セッション有効期限 | 30日間（非アクティブで失効）
| 複数デバイス | セッションテーブルで管理します（一覧・個別削除可能）
| パスワード変更時 | 全セッションを無効化します

## パスワードリセットフロー

### 安全なリセットフローの実装

```text

1. ユーザーがメールアドレスを入力します
   ↓
2. サーバーがトークンを生成します

   - 平文トークン → メール送信（URLパラメータ）
   - SHA-256ハッシュ → DBに保存

   ↓
3. ユーザーがメールのリンクをクリックします
   ↓
4. サーバーがトークンを検証します

   - URLのトークンをSHA-256でハッシュ化します
   - DBのハッシュと比較します（タイミングセーフ）
   - 有効期限をチェックします（通常2時間）
   - 使用済みチェックを行います

   ↓
5. パスワード変更を実行します

   - 新パスワードをBCryptでハッシュ化して保存します
   - トークンを使用済みにします
   - 既存セッションをすべて無効化します

```

### なぜトークンをハッシュ化して保存するか

DBにトークンを平文で保存すると、DB漏洩時にすべてのリセットトークンが攻撃者に渡ります。SHA-256でハッシュ化しておけば、
DBが漏洩してもトークンを復元できません。

## レート制限

### Rails 8のrate_limitマクロ

```ruby

class SessionsController < ApplicationController
  # 3分間に10回までのログイン試行を許可します
  rate_limit to: 10, within: 3.minutes, only: :create,
             with: -> { redirect_to new_session_url, alert: "しばらくお待ちください" }
end

```

### レート制限の戦略

| 戦略 | 説明 | メリット | デメリット
| ------ | ------ | --------- | -----------
| IPベース | 同一IPからの試行を制限します | 実装が簡単です | NAT背後のユーザーに影響します
| アカウントベース | 同一アカウントへの試行を制限します | 標的型攻撃に有効です | 正規ユーザーもロックされます
| 複合型 | IP + アカウントの組み合わせです | バランスが良いです | 実装が複雑です
| プログレッシブ | 試行回数に応じて遅延を増加させます | UXへの影響が小さいです | 実装が最も複雑です

## CurrentAttributesパターン

### ActiveSupport::CurrentAttributesの仕組み

```ruby

class Current < ActiveSupport::CurrentAttributes
  attribute :session
  attribute :user_agent, :ip_address

  def user
    session&.user
  end
end

```

内部的には`Thread.current`（正確には`Fiber#[]`）を使用して、リクエストスコープのデータを保持します。
RackミドルウェアがリクエストEnd時に`CurrentAttributes.reset`を呼び出し、データをクリアします。

### 使用上の注意

- Sidekiq等のジョブ: バックグラウンドジョブではCurrentの値は引き継がれません。必要なデータは明示的に渡してください
- テスト: テスト間でCurrentの値が残る可能性があります。`before { Current.reset }`でリセットしてください
- 過度な使用の回避: Currentはグローバル状態であり、多用すると依存関係が不明瞭になります

## Deviseとの比較

### 機能比較表

| 機能 | Rails 8 built-in | Devise
| ------ | ------------------- | --------
| パスワード認証 | `has_secure_password` | `database_authenticatable`
| セッション管理 | Sessionモデル（DB） | Warden + Cookie
| パスワードリセット | 自前実装（生成コード） | `recoverable`モジュール
| メール確認 | 自前実装が必要です | `confirmable`モジュール
| アカウントロック | 自前実装が必要です | `lockable`モジュール
| Remember me | 自前実装が必要です | `rememberable`モジュール
| OmniAuth連携 | 自前実装が必要です | `omniauthable`モジュール
| トラッキング | 自前実装が必要です | `trackable`モジュール
| レート制限 | `rate_limit`マクロ | Rack::Attack（外部gem）
| カスタマイズ性 | コード直接編集 | ジェネレータ + 設定ファイル
| 外部依存 | なし | warden, bcrypt, orm_adapter

### 選択基準

Rails 8組み込み認証を選ぶ場合は以下の通りです。

- シンプルなメール/パスワード認証で十分な場合
- 認証フローを完全にコントロールしたい場合
- 外部gem依存を最小限にしたい場合
- 新規プロジェクトでRails 8以降を使用する場合
- チームがRailsの内部動作を理解している場合

Deviseを選ぶ場合は以下の通りです。

- OAuth / OmniAuth（Google, GitHub等）連携が必須の場合
- メール確認、アカウントロック、トラッキング等の機能が必要な場合
- 認証の実装に時間をかけたくない場合
- 既存プロジェクトでDeviseが使われている場合
- 大規模チームで標準化された認証基盤が必要な場合

## セキュリティベストプラクティス

### パスワード保存

```ruby

# 絶対にやってはいけないこと

user.password_plain = params[:password]  # 平文保存
user.password_hash = Digest::MD5.hexdigest(params[:password])  # MD5
user.password_hash = Digest::SHA256.hexdigest(params[:password])  # ソルトなしSHA

# 正しい方法

user.password = params[:password]  # has_secure_passwordがBCryptで処理します

```

### トークン管理

```ruby

# 悪い例

token = rand(1000000).to_s  # 予測可能です
token = Time.current.to_i.to_s  # 予測可能です
reset_token = SecureRandom.hex(16)

# DBに平文で保存するのは危険です

# 良い例

token = SecureRandom.urlsafe_base64(32)  # 256ビットランダム
digest = Digest::SHA256.hexdigest(token)

# DBにはダイジェストを保存し、平文はメールで送信します

```

### CSRF対策

Rails 8の認証では、以下のCSRF対策が自動的に適用されます。

- `authenticity_token`によるPOST/PATCH/DELETEリクエストの検証を行います
- `cookies.signed`によるCookie署名（改ざん防止）を行います
- `same_site: :lax` Cookie属性によるクロスサイトリクエスト防止を行います

### セッションハイジャック対策

```ruby

# IPアドレスとユーザーエージェントの検証を行います

def validate_session(session)
  return false if session.ip_address != request.remote_ip
  return false if session.user_agent != request.user_agent
  true
end

# セッション固定攻撃の防止のため、

# ログイン成功時にセッショントークンを再生成します

def regenerate_session(user)
  Current.session&.destroy
  new_session = user.sessions.create!
  cookies.signed[:session_token] = new_session.token
end

```

## 実装パターン

### Authentication concern

```ruby

# app/controllers/concerns/authentication.rb

module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_authentication
    helper_method :authenticated?
  end

  private

  def authenticated?
    Current.session.present?
  end

  def require_authentication
    resume_session || request_authentication
  end

  def resume_session
    session = Session.find_by(token: cookies.signed[:session_token])
    if session && !session.expired?
      Current.session = session
      session.touch_last_active
    end
  end

  def request_authentication
    session[:return_to_after_authenticating] = request.url
    redirect_to new_session_url
  end

  def after_authentication_url
    session.delete(:return_to_after_authenticating) || root_url
  end

  def start_new_session_for(user)
    user.sessions.create!(
      user_agent: request.user_agent,
      ip_address: request.remote_ip
    ).tap do |new_session|
      Current.session = new_session
      cookies.signed.permanent[:session_token] = {
        value: new_session.token,
        httponly: true,
        same_site: :lax
      }
    end
  end

  def terminate_session
    Current.session.destroy
    cookies.delete(:session_token)
  end
end

```

### SessionsController

```ruby

class SessionsController < ApplicationController
  skip_before_action :require_authentication, only: %i[new create]
  rate_limit to: 10, within: 3.minutes, only: :create

  def new
  end

  def create
    user = User.authenticate_by(
      email_address: params[:email_address],
      password: params[:password]
    )
    if user
      start_new_session_for(user)
      redirect_to after_authentication_url
    else
      redirect_to new_session_url,
                  alert: "メールアドレスまたはパスワードが正しくありません"
    end
  end

  def destroy
    terminate_session
    redirect_to new_session_url
  end
end

```

## 実行方法

```bash

# テストの実行

bundle exec rspec 22_authentication/authentication_spec.rb

# 個別のメソッドを試す

ruby -r ./22_authentication/authentication -e "pp AuthenticationGenerator.demonstrate_bcrypt_internals"
ruby -r ./22_authentication/authentication -e "pp AuthenticationGenerator.demonstrate_has_secure_password"
ruby -r ./22_authentication/authentication -e "pp AuthenticationGenerator.demonstrate_session_management"
ruby -r ./22_authentication/authentication -e "pp AuthenticationGenerator.demonstrate_password_reset_flow"
ruby -r ./22_authentication/authentication -e "pp AuthenticationGenerator.demonstrate_rate_limiting"
ruby -r ./22_authentication/authentication -e "pp AuthenticationGenerator.demonstrate_remember_me"
ruby -r ./22_authentication/authentication -e "pp AuthenticationGenerator.demonstrate_current_attributes"
ruby -r ./22_authentication/authentication -e "pp AuthenticationGenerator.demonstrate_timing_safe_comparison"
ruby -r ./22_authentication/authentication -e "pp AuthenticationGenerator.demonstrate_devise_comparison"

```

## 参考資料

- [Rails 8 Authentication Generator](https://github.com/rails/rails/pull/52328)
-
  [has_secure_passwordドキュメント](https://api.rubyonrails.org/classes/ActiveModel/SecurePassword/ClassMethods.html)
-
  [ActiveSupport::CurrentAttributes](https://api.rubyonrails.org/classes/ActiveSupport/CurrentAttributes.html)
- [BCrypt Ruby](https://github.com/bcrypt-ruby/bcrypt-ruby)
- [Railsセキュリティガイド](https://guides.rubyonrails.org/security.html)
