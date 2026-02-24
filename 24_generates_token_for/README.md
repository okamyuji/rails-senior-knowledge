# generates_token_forとnormalizes

## なぜgenerates_token_forとnormalizesの理解が重要か

Rails
7.1で導入された`generates_token_for`と`normalizes`は、従来のセキュアトークン管理と属性正規化のパターンを大幅に簡素化します。シニアRailsエンジニアがこれらのAPIを深く理解すべき理由は以下の通りです。

- セキュリティ設計の向上: ステートレスなトークン設計により、トークンテーブルの管理が不要になり、攻撃面（attack surface）が縮小します
- コードの宣言性: コールバックチェーンを使った手続き的なコードから、モデル定義で完結する宣言的なコードへ移行できます
- 自動無効化の仕組み: トークンの用途と無効化条件を一箇所で定義でき、セキュリティ上の見落としを防げます
- データ品質の保証: `normalizes`により、データベースに格納される値が常に一貫した形式になります

## generates_token_forの仕組み（MessageVerifier）

### 内部アーキテクチャ

`generates_token_for`は`ActiveSupport::MessageVerifier`を基盤としています。MessageVerifierはHMAC（Hash-based
Message Authentication Code）を使ってペイロードに署名し、改ざんを検出可能なトークンを生成します。

```text

トークン生成フロー:
┌─────────────────────────────────────────────────────────┐
│ 1. ブロック評価 → 状態値の取得                            │
│    password_salt.last(10) → "abc1234567"                 │
│                                                         │
│ 2. ペイロード構築                                        │
│    [:password_reset, record_id, "abc1234567"]            │
│                                                         │
│ 3. MessageVerifier.generate(payload, expires_at: ...)    │
│    → Base64エンコード + HMAC署名 + 有効期限              │
│                                                         │
│ 4. トークン文字列を返却します                             │
│    "eyJfcmFpbHMiOnsibWVzc..."                           │
└─────────────────────────────────────────────────────────┘

```

```text

トークン検証フロー:
┌─────────────────────────────────────────────────────────┐
│ 1. MessageVerifier.verify(token)                         │
│    → 署名検証 + 有効期限チェック + ペイロード復元         │
│                                                         │
│ 2. ペイロードからpurposeとrecord_idを抽出します           │
│    [:password_reset, 42, "abc1234567"]                   │
│                                                         │
│ 3. レコードをfind(record_id)で取得します                  │
│                                                         │
│ 4. ブロックを再評価して状態値を比較します                  │
│    現在のpassword_salt.last(10) == "abc1234567" ?       │
│                                                         │
│ 5. 一致 → レコードを返却 / 不一致 → nil                 │
└─────────────────────────────────────────────────────────┘

```

### generates_token_forが定義するメソッド

```ruby

class User < ApplicationRecord
  generates_token_for :password_reset, expires_in: 15.minutes do
    password_salt&.last(10)
  end
end

# 以下のメソッドが自動定義されます:

user.generate_token_for(:password_reset)           # トークン生成（インスタンスメソッド）
User.find_by_token_for(:password_reset, token)     # トークン検証（nilを返します）
User.find_by_token_for!(:password_reset, token)    # トークン検証（例外を発生させます）

```

### secret_key_baseとの関係

トークンの署名には`Rails.application.secret_key_base`が使われます。この鍵が漏洩すると、すべてのトークンが危殆化します。`credentials.yml.enc`で安全に管理することが必須です。

## 目的別トークン設計

### パスワードリセット

```ruby

generates_token_for :password_reset, expires_in: 15.minutes do
  password_salt&.last(10)
end

```

- 有効期限: 15〜30分（短いほど安全です）
- 無効化条件: パスワード変更で`password_salt`が変わるため自動無効化されます
- 使い捨て: パスワードリセット完了後、同じトークンは使用できません

### メール確認

```ruby

generates_token_for :email_confirmation, expires_in: 24.hours do
  email_confirmed
end

```

- 有効期限: 24〜48時間（ユーザーがメールを確認する猶予を考慮します）
- 無効化条件: `email_confirmed`が`true`に変わると無効化されます
- 再利用防止: 一度確認が完了すると、同じトークンでは再確認できません

### ワンタイムログイン（マジックリンク）

```ruby

generates_token_for :one_time_login, expires_in: 30.minutes do
  updated_at&.to_f
end

```

- 有効期限: 15〜30分です
- 無効化条件: ログイン時に`updated_at`が更新されると無効化されます
- セキュリティ: ログイン後にトークンが自動的に失効します

### メール配信停止（長期有効）

```ruby

generates_token_for :unsubscribe do
  # ブロックなし、または固定値を返します
  # 有効期限を設定しない場合、secret_key_baseが変わるまで有効です
  email
end

```

## normalizes活用パターン

### 基本的な使い方

```ruby

class User < ApplicationRecord
  # 単一属性の正規化
  normalizes :email, with: ->(email) { email.strip.downcase }

  # 複数属性に同じ正規化を適用します
  normalizes :first_name, :last_name, with: ->(name) { name.strip }

  # nilにも正規化を適用します（デフォルトではnilはスキップ）
  normalizes :phone, with: ->(phone) { phone&.gsub(/\D/, "") },
             apply_to_nil: false  # デフォルト
end

```

### 正規化が適用されるタイミング

`normalizes`の最も重要な特徴は、セッター呼び出し時とfinderメソッドの両方で正規化が適用されることです。

```ruby

# 1. セッター呼び出し時

user.email = "  FOO@BAR.COM  "
user.email  # => "foo@bar.com"

# 2. new / create時

user = User.new(email: "  FOO@BAR.COM  ")
user.email  # => "foo@bar.com"

# 3. find_by / whereでも正規化されます

User.find_by(email: "  FOO@BAR.COM  ")

# => SELECT * FROM users WHERE email = 'foo@bar.com'

User.where(email: "  FOO@BAR.COM  ")

# => SELECT * FROM users WHERE email = 'foo@bar.com'

```

従来の`before_validation`コールバックではfinderに正規化が適用されなかったため、大文字小文字の不一致による検索漏れが発生する可能性がありました。`normalizes`はこの問題を根本的に解決します。

### 再利用可能な正規化ブロック

```ruby

module Normalizers
  EMAIL = ->(email) { email.strip.downcase }
  PHONE = ->(phone) { phone.tr("０-９", "0-9").gsub(/[\s\-ー]/, "") }
  BLANK_TO_NIL = ->(value) { value.presence }
  JAPANESE_STRIP = ->(value) { value.gsub(/\A[\s　]+|[\s　]+\z/, "") }
end

class User < ApplicationRecord
  normalizes :email, with: Normalizers::EMAIL
  normalizes :phone, with: Normalizers::PHONE
  normalizes :nickname, with: Normalizers::JAPANESE_STRIP
end

class Admin < ApplicationRecord
  normalizes :email, with: Normalizers::EMAIL  # 同じ正規化を再利用します
end

```

### before_validationとの比較

```ruby

# 従来のパターン（before_validation）

class User < ApplicationRecord
  before_validation :normalize_email

  private

  def normalize_email
    self.email = email&.strip&.downcase
  end
end

# 問題点: User.find_by(email: "  FOO@BAR.COM  ")では正規化されません

# 新しいパターン（normalizes）

class User < ApplicationRecord
  normalizes :email, with: ->(e) { e.strip.downcase }
end

# 利点: User.find_by(email: "  FOO@BAR.COM  ")でも正規化されます

```

## セキュアトークンのベストプラクティス

### 1. ステートレスとステートフルの比較

`generates_token_for`はステートレスなトークン（DBにトークンを保存しない）を生成します。

| 比較項目 | generates_token_for（ステートレス） | DBトークン（ステートフル）
| --------- | ---------------------------------- | ------------------------
| DB保存 | 不要です | 必要です（tokensテーブル）
| 検証速度 | 高速です（暗号処理のみ） | DBクエリが必要です
| スケーラビリティ | 高いです | DBに依存します
| 明示的な失効 | ブロック値の変更が必要です | DELETEで即失効します
| トークン一覧取得 | できません | 可能です

### 2. ブロック値の設計指針

```ruby

# 良い例: 変更を検知できる値を返します

generates_token_for :password_reset do
  password_salt&.last(10)  # パスワード変更で無効化されます
end

# 良い例: 状態変化で無効化されます

generates_token_for :email_confirmation do
  email_confirmed  # trueに変わると無効化されます
end

# 悪い例: 常に同じ値を返します（無効化できません）

generates_token_for :some_purpose do
  "fixed_value"  # これでは状態変化で無効化できません
end

```

### 3. 有効期限の設計

```ruby

# セキュリティが重要な操作は短い有効期限を設定します

generates_token_for :password_reset, expires_in: 15.minutes
generates_token_for :one_time_login, expires_in: 30.minutes

# ユーザー体験を重視する操作はやや長めに設定します

generates_token_for :email_confirmation, expires_in: 24.hours

# 有効期限なし（注意して使用してください）

generates_token_for :unsubscribe do
  email  # メール変更で無効化されます
end

```

### 4. トークンのURL安全性

`generates_token_for`が生成するトークンはBase64エンコードされていますが、URLに含める場合は`CGI.escape`でエスケープすることが推奨されます。

```ruby

token = user.generate_token_for(:password_reset)
url = "https://example.com/password_reset?token=#{CGI.escape(token)}"

```

### 5. レート制限との組み合わせ

トークン生成のエンドポイントにはレート制限を設けることが重要です。

```ruby

# コントローラーでの例

class PasswordResetsController < ApplicationController
  rate_limit to: 5, within: 1.hour, only: :create

  def create
    user = User.find_by(email: params[:email])
    if user
      token = user.generate_token_for(:password_reset)
      PasswordResetMailer.with(user: user, token: token).deliver_later
    end
    # ユーザーが存在しなくても同じレスポンスを返します（列挙攻撃対策）
    redirect_to root_path, notice: "メールを送信しました"
  end
end

```

## 実行方法

```bash

# テストの実行

bundle exec rspec 24_generates_token_for/generates_token_for_spec.rb

# 個別のメソッドを試す

bundle exec ruby -r ./24_generates_token_for/generates_token_for -e "pp GeneratesTokenFor.demonstrate_token_generation"
bundle exec ruby -r ./24_generates_token_for/generates_token_for -e "pp GeneratesTokenFor.demonstrate_normalizes_basics"
bundle exec ruby -r ./24_generates_token_for/generates_token_for -e "pp GeneratesTokenFor.demonstrate_email_confirmation_flow"

```
