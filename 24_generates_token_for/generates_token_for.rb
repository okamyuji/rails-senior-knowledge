# frozen_string_literal: true

# Rails 7.1+/8 で導入された generates_token_for と normalizes を解説するモジュール
#
# generates_token_for は目的別のセキュアトークンを生成するAPIで、
# パスワードリセット、メール確認、ワンタイムログインなど用途ごとに
# トークンの有効期限や無効化条件を宣言的に定義できる。
#
# normalizes はモデル属性の正規化（ストリップ、小文字化など）を
# 宣言的に定義するAPIで、バリデーション前・保存前に自動適用される。
#
# このモジュールでは、シニアRailsエンジニアが知るべき
# トークン生成・検証の内部動作と属性正規化の仕組みを実例を通じて学ぶ。

require 'active_record'
require 'active_support'

# --- generates_token_for のための MessageVerifier セットアップ ---
#
# generates_token_for は内部で ActiveRecord::Base.generated_token_verifier を使用する。
# この class_attribute に ActiveSupport::MessageVerifier のインスタンスを設定する必要がある。
#
# 実際のRailsアプリケーションでは、railtie が Rails.application.message_verifier を
# 自動的に generated_token_verifier に設定する。
# スタンドアロン環境では手動で MessageVerifier を構成する。
#
# MessageVerifier は secret_key_base（HMAC署名用の秘密鍵）を受け取り、
# ペイロードの署名・検証を行う。
# 実際のRailsアプリでは config/credentials.yml.enc で secret_key_base を管理する。
TOKEN_VERIFIER_SECRET = SecureRandom.hex(64)
ActiveRecord::Base.generated_token_verifier = ActiveSupport::MessageVerifier.new(
  TOKEN_VERIFIER_SECRET,
  digest: 'SHA256',
  serializer: JSON
)

# --- インメモリSQLiteデータベースのセットアップ ---
ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:') unless ActiveRecord::Base.connected?
ActiveRecord::Base.logger = nil # テスト時のログ出力を抑制

ActiveRecord::Schema.define do
  create_table :token_users, force: true do |t|
    t.string :email, null: false
    t.string :password_digest, null: false
    t.string :unconfirmed_email
    t.boolean :email_confirmed, default: false
    t.timestamps null: false
  end

  create_table :api_clients, force: true do |t|
    t.string :name
    t.string :company_name
    t.string :contact_email
    t.string :api_key_digest
    t.integer :request_count, default: 0
    t.timestamps null: false
  end
end

# --- モデル定義 ---

# トークン生成とメール正規化を活用するユーザーモデル
class TokenUser < ActiveRecord::Base
  has_secure_password

  # ==========================================================================
  # normalizes: 属性の正規化を宣言的に定義
  # ==========================================================================
  #
  # normalizes はバリデーション前・保存前に属性値を正規化する。
  # コールバック（before_validation等）を使う従来のパターンを置き換え、
  # モデルの宣言部で正規化ルールを明示できる。
  #
  # 特徴:
  # - セッター呼び出し時にも即座に適用される
  # - finder メソッド（find_by, where等）でも正規化が適用される
  # - nil は正規化されない（apply_to_nil: true で変更可能）
  normalizes :email, with: ->(email) { email.strip.downcase }

  # ==========================================================================
  # generates_token_for: 目的別セキュアトークンの生成
  # ==========================================================================
  #
  # generates_token_for は ActiveRecord::Base.generates_token_for として定義され、
  # 内部的に ActiveSupport::MessageVerifier を使用してトークンを生成する。
  #
  # トークン構造:
  #   MessageVerifier.generate([purpose, record_id, ...block_values], expires_at: ...)
  #
  # トークンには以下が暗号化・署名されて埋め込まれる:
  # - 目的（purpose）: :password_reset, :email_confirmation 等
  # - レコードID: find_by_token_for でレコードを特定するため
  # - ブロックの戻り値: トークン無効化に使用される値
  # - 有効期限: expires_in で指定した期間

  # パスワードリセット用トークン（15分間有効）
  # ブロックで password_salt の末尾10文字を返す。
  # パスワードが変更されると password_salt が変わるため、
  # 古いトークンは自動的に無効化される。
  generates_token_for :password_reset, expires_in: 15.minutes do
    password_salt&.last(10)
  end

  # メール確認用トークン（24時間有効）
  # email_confirmed フラグをブロックで返すことで、
  # 一度確認が完了するとトークンは無効化される。
  generates_token_for :email_confirmation, expires_in: 24.hours do
    email_confirmed
  end

  # ワンタイムログイン用トークン（30分有効）
  # updated_at をブロックで返すことで、
  # ユーザーがログインして情報が更新されるとトークンが無効になる。
  generates_token_for :one_time_login, expires_in: 30.minutes do
    updated_at&.to_f
  end

  # メール確認を実行するメソッド
  def confirm_email!
    update!(email_confirmed: true)
  end
end

# 複数のnormalizesを活用するAPIクライアントモデル
class ApiClient < ActiveRecord::Base
  # 複数属性への同時正規化
  normalizes :name, :company_name, with: lambda(&:strip)

  # メールアドレスの正規化（ストリップ + 小文字化）
  normalizes :contact_email, with: ->(email) { email.strip.downcase }
end

# ==========================================================================
# カスタム正規化ブロックの再利用パターン
# ==========================================================================
#
# 正規化ロジックを定数やメソッドとして切り出すことで、
# 複数のモデルで一貫した正規化を適用できる。
module NormalizerLibrary
  # メールアドレス正規化: ストリップ + 小文字化
  EMAIL_NORMALIZER = ->(email) { email.strip.downcase }

  # 電話番号正規化: ハイフン・スペース除去、全角→半角変換
  PHONE_NORMALIZER = lambda { |phone|
    phone.tr('０-９', '0-9').gsub(/[\s\-ー]/, '')
  }

  # 空文字をnilに変換する正規化
  # normalizes はデフォルトで nil をスキップするが、
  # apply_to_nil: true と組み合わせることで活用可能
  BLANK_TO_NIL_NORMALIZER = lambda(&:presence)

  # 日本語全角スペースも含めたストリップ
  JAPANESE_STRIP_NORMALIZER = lambda { |value|
    value.gsub(/\A[\s　]+|[\s　]+\z/, '')
  }
end

module GeneratesTokenFor
  module_function

  # ==========================================================================
  # 1. generates_token_for の基本: 目的別トークンの生成と検証
  # ==========================================================================
  #
  # generates_token_for は以下のメソッドを自動的に定義する:
  # - インスタンスメソッド: generate_token_for(:purpose)
  # - クラスメソッド: find_by_token_for(:purpose, token)
  # - クラスメソッド: find_by_token_for!(:purpose, token) — 見つからない場合に例外
  #
  # トークンはBase64エンコードされた署名付き文字列として生成される。
  # Rails の secret_key_base を使って署名されるため、改ざんは検出される。
  def demonstrate_token_generation
    TokenUser.delete_all

    user = TokenUser.create!(
      email: 'alice@example.com',
      password: 'secure_password_123',
      password_confirmation: 'secure_password_123'
    )

    # トークン生成
    reset_token = user.generate_token_for(:password_reset)
    confirm_token = user.generate_token_for(:email_confirmation)
    login_token = user.generate_token_for(:one_time_login)

    # トークン検証（find_by_token_for）
    found_by_reset = TokenUser.find_by_token_for(:password_reset, reset_token)
    found_by_confirm = TokenUser.find_by_token_for(:email_confirmation, confirm_token)
    found_by_login = TokenUser.find_by_token_for(:one_time_login, login_token)

    {
      user_id: user.id,
      # トークンはBase64エンコードされた文字列
      reset_token_sample: "#{reset_token[0..30]}...",
      confirm_token_sample: "#{confirm_token[0..30]}...",
      login_token_sample: "#{login_token[0..30]}...",
      # 各トークンは異なる値（目的ごとに生成されるため）
      tokens_are_different: [reset_token, confirm_token, login_token].uniq.length == 3,
      # find_by_token_for で正しいユーザーが見つかる
      reset_found: found_by_reset&.id == user.id,
      confirm_found: found_by_confirm&.id == user.id,
      login_found: found_by_login&.id == user.id
    }
  end

  # ==========================================================================
  # 2. トークン構造: MessageVerifier による安全なトークン設計
  # ==========================================================================
  #
  # generates_token_for の内部では、以下の流れでトークンが生成される:
  #
  # 1. ブロックを評価して「状態値」を取得（例: password_salt.last(10)）
  # 2. [purpose, record_id, ...block_values] の配列を構築
  # 3. MessageVerifier.generate(payload, expires_at: ...) で署名付きトークンを生成
  #
  # トークン検証時:
  # 1. MessageVerifier.verify(token) でペイロードを復元
  # 2. purpose とレコードIDを抽出
  # 3. レコードを find して、ブロックを再評価
  # 4. 生成時の状態値と現在の状態値を比較
  # 5. 一致しなければ nil を返す（トークン無効化）
  def demonstrate_token_structure
    TokenUser.delete_all

    user = TokenUser.create!(
      email: 'bob@example.com',
      password: 'password_456',
      password_confirmation: 'password_456'
    )

    token = user.generate_token_for(:password_reset)

    # トークンの特性確認
    {
      token_is_string: token.is_a?(String),
      # トークンはURL-safeな文字列（Base64エンコード）
      token_length: token.length,
      # 同じユーザーで再生成しても異なるトークンになる場合がある
      # （タイムスタンプが含まれるため）
      token_encoding: token.encoding.to_s,
      # 不正なトークンはnilを返す（例外を発生させない）
      invalid_token_result: TokenUser.find_by_token_for(:password_reset, 'invalid_token'),
      # 異なる目的のトークンは互いに無効
      wrong_purpose_result: TokenUser.find_by_token_for(:email_confirmation, token),
      # find_by_token_for! は見つからない場合に例外を発生させる
      bang_method_raises: begin
        TokenUser.find_by_token_for!(:password_reset, 'invalid')
        false
      rescue ActiveSupport::MessageVerifier::InvalidSignature
        true
      rescue ActiveRecord::RecordNotFound
        true
      end
    }
  end

  # ==========================================================================
  # 3. トークン無効化: 属性変更による自動無効化の仕組み
  # ==========================================================================
  #
  # generates_token_for のブロックで返す値が「トークンの有効性を検証する鍵」となる。
  # トークン生成時にブロックの戻り値が記録され、
  # 検証時に再度ブロックを評価して一致するかチェックする。
  #
  # パスワードリセットの例:
  # - トークン生成時: password_salt.last(10) → "abc1234567"
  # - パスワード変更後: password_salt.last(10) → "xyz9876543"（変わる）
  # - 検証: "abc1234567" != "xyz9876543" → トークン無効
  def demonstrate_token_invalidation
    TokenUser.delete_all

    user = TokenUser.create!(
      email: 'charlie@example.com',
      password: 'original_pass',
      password_confirmation: 'original_pass'
    )

    # パスワードリセットトークンを生成
    reset_token = user.generate_token_for(:password_reset)

    # メール確認トークンを生成
    confirm_token = user.generate_token_for(:email_confirmation)

    # パスワード変更前: トークンは有効
    before_change = TokenUser.find_by_token_for(:password_reset, reset_token)

    # パスワードを変更すると password_salt が変わる
    user.update!(password: 'new_password_789', password_confirmation: 'new_password_789')

    # パスワード変更後: パスワードリセットトークンは無効化される
    after_password_change = TokenUser.find_by_token_for(:password_reset, reset_token)

    # メール確認トークンは（email_confirmed が変わっていないので）まだ有効
    confirm_still_valid = TokenUser.find_by_token_for(:email_confirmation, confirm_token)

    # メール確認を実行
    user.confirm_email!

    # メール確認後: メール確認トークンも無効化される
    after_confirmation = TokenUser.find_by_token_for(:email_confirmation, confirm_token)

    {
      # パスワード変更前はトークン有効
      before_password_change: before_change&.id == user.id,
      # パスワード変更後はリセットトークン無効
      after_password_change: after_password_change.nil?,
      # メール確認トークンはパスワード変更の影響を受けない
      confirm_unaffected_by_password: confirm_still_valid&.id == user.id,
      # メール確認後はメール確認トークン無効
      after_email_confirmation: after_confirmation.nil?
    }
  end

  # ==========================================================================
  # 4. normalizes の基本: 属性正規化の仕組み
  # ==========================================================================
  #
  # normalizes は以下のタイミングで属性値を正規化する:
  # - セッター呼び出し時（user.email = "  FOO@BAR.COM  " → "foo@bar.com"）
  # - new / create 時
  # - update 時
  # - finder メソッド（find_by, where）のパラメータにも適用
  #
  # これにより、データベースに格納される値が常に正規化された状態になる。
  # 従来の before_validation コールバックでは finder には適用されなかったが、
  # normalizes では finder にも自動適用される。
  def demonstrate_normalizes_basics
    TokenUser.delete_all

    # 前後の空白と大文字を含むメールで作成
    user = TokenUser.create!(
      email: '  Alice@Example.COM  ',
      password: 'password_123',
      password_confirmation: 'password_123'
    )

    # セッターで再代入しても正規化される
    user.email = '  BOB@EXAMPLE.COM  '
    email_after_setter = user.email

    # find_by でも正規化が適用される
    user.update!(email: 'alice@example.com')
    found_by_normalized = TokenUser.find_by(email: '  ALICE@EXAMPLE.COM  ')

    # where でも正規化が適用される
    where_result = TokenUser.where(email: '  ALICE@EXAMPLE.COM  ').to_sql

    {
      # 保存時に正規化される
      saved_email: user.reload.email,
      # セッターでも即座に正規化される
      email_after_setter: email_after_setter,
      # find_by でも正規化が適用される
      found_by_normalized: found_by_normalized&.id == user.id,
      # SQLクエリにも正規化された値が使われる
      where_sql_contains_normalized: where_result.include?('alice@example.com')
    }
  end

  # ==========================================================================
  # 5. normalizes の高度な使い方: 複数属性と apply_to_nil
  # ==========================================================================
  #
  # normalizes は複数の属性に同じ正規化を適用できる。
  # また、apply_to_nil: true を指定すると nil に対しても正規化が適用される。
  #
  # Type.normalize_value_in(record) メソッドを使うと、
  # 特定の属性の正規化を手動で適用できる。
  def demonstrate_normalizes_advanced
    ApiClient.delete_all

    # 複数属性に同じ正規化が適用される
    client = ApiClient.create!(
      name: '  Acme Corp  ',
      company_name: '  Widget Inc  ',
      contact_email: '  CONTACT@ACME.COM  '
    )

    {
      # 両方の属性がストリップされる
      name: client.name,
      company_name: client.company_name,
      # メールは追加でdowncaseされる
      contact_email: client.contact_email,
      # 正規化の確認
      name_stripped: client.name == 'Acme Corp',
      company_stripped: client.company_name == 'Widget Inc',
      email_normalized: client.contact_email == 'contact@acme.com'
    }
  end

  # ==========================================================================
  # 6. カスタム正規化ブロックの再利用パターン
  # ==========================================================================
  #
  # 正規化ロジックを定数化し、複数モデルで一貫して使うパターン。
  # NormalizerLibrary モジュールで定義した正規化用Procを参照する。
  def demonstrate_custom_normalizers
    {
      # メール正規化
      email_normalizer: NormalizerLibrary::EMAIL_NORMALIZER.call('  TEST@Example.COM  '),
      # 電話番号正規化
      phone_normalizer: NormalizerLibrary::PHONE_NORMALIZER.call('０９０-１２３４-５６７８'),
      # 空文字→nil変換
      blank_to_nil: NormalizerLibrary::BLANK_TO_NIL_NORMALIZER.call(''),
      blank_to_nil_with_value: NormalizerLibrary::BLANK_TO_NIL_NORMALIZER.call('hello'),
      # 日本語対応ストリップ
      japanese_strip: NormalizerLibrary::JAPANESE_STRIP_NORMALIZER.call('　こんにちは　'),
      # これらの正規化は normalizes の with: パラメータに直接渡せる
      # 例: normalizes :email, with: NormalizerLibrary::EMAIL_NORMALIZER
      usage_example: 'normalizes :email, with: NormalizerLibrary::EMAIL_NORMALIZER'
    }
  end

  # ==========================================================================
  # 7. 実践パターン: generates_token_for + normalizes によるメール確認フロー
  # ==========================================================================
  #
  # 実際のアプリケーションで使われるメール確認フローの完全な例。
  # normalizes でメールアドレスを正規化し、
  # generates_token_for でメール確認トークンを生成する。
  #
  # フロー:
  # 1. ユーザー登録時にメールアドレスが正規化される
  # 2. メール確認トークンを生成してメールで送信
  # 3. ユーザーがリンクをクリック → トークン検証
  # 4. 確認完了 → トークンは自動無効化（再利用防止）
  def demonstrate_email_confirmation_flow
    TokenUser.delete_all

    # Step 1: ユーザー登録（メールアドレスは正規化される）
    user = TokenUser.create!(
      email: '  NewUser@Example.COM  ',
      password: 'secure_pass_123',
      password_confirmation: 'secure_pass_123',
      email_confirmed: false
    )
    registered_email = user.email

    # Step 2: メール確認トークンを生成
    confirmation_token = user.generate_token_for(:email_confirmation)

    # Step 3: トークンを使ってユーザーを検証
    found_user = TokenUser.find_by_token_for(:email_confirmation, confirmation_token)
    token_valid_before = found_user&.id == user.id

    # Step 4: メール確認を実行
    found_user&.confirm_email!

    # Step 5: 同じトークンでの再利用を試みる → 無効化されている
    reuse_attempt = TokenUser.find_by_token_for(:email_confirmation, confirmation_token)

    # Step 6: リロードして最新の状態を取得してから新しいトークンを生成
    # user オブジェクトをリロードしないと、メモリ上の email_confirmed は false のまま。
    # generate_token_for のブロックはインスタンスの状態を評価するため、
    # リロードして email_confirmed: true の状態でトークンを生成する。
    user.reload
    new_token_after_confirm = user.generate_token_for(:email_confirmation)
    # このトークンは email_confirmed: true で生成されるため、
    # DB上の現在の状態と一致し、有効期限内は有効
    new_token_valid = TokenUser.find_by_token_for(:email_confirmation, new_token_after_confirm)

    {
      # メールアドレスが正規化されている
      registered_email: registered_email,
      email_normalized: registered_email == 'newuser@example.com',
      # 確認前: トークンは有効
      token_valid_before_confirmation: token_valid_before,
      # 確認後: email_confirmed が変わったため旧トークンは無効
      token_invalid_after_confirmation: reuse_attempt.nil?,
      # ユーザーの確認状態
      user_confirmed: user.reload.email_confirmed,
      # 新しいトークンは現在の状態で生成されるため有効
      new_token_valid: new_token_valid&.id == user.id
    }
  end

  # ==========================================================================
  # 8. セキュリティのベストプラクティス
  # ==========================================================================
  #
  # generates_token_for を使う際のセキュリティ上の注意点をまとめる。
  def demonstrate_security_best_practices
    {
      # 1. トークンの有効期限は用途に応じて最小限にする
      recommended_expiry: {
        password_reset: '15〜30分',
        email_confirmation: '24〜48時間',
        one_time_login: '15〜30分',
        unsubscribe: '無期限（ただしユーザー固有の値をブロックに含める）'
      },
      # 2. ブロックには変更検知に使える値を含める
      invalidation_strategies: {
        password_reset: 'password_salt — パスワード変更で自動無効化',
        email_confirmation: 'email_confirmed — 確認完了で自動無効化',
        one_time_login: 'updated_at — ログイン時の更新で自動無効化'
      },
      # 3. トークンの保存は不要
      # generates_token_for はステートレスなトークンを生成するため、
      # データベースにトークンを保存する必要がない。
      # これにより、トークンテーブルの管理が不要になる。
      stateless_advantage: 'DBにトークンを保存する必要がない（MessageVerifierベース）',
      # 4. secret_key_base の管理
      # トークンの署名に使われるため、漏洩すると全トークンが危殆化する
      key_management: 'secret_key_base はcredentials.yml.encで安全に管理する',
      # 5. normalizes でメールアドレスを正規化することで、
      # 大文字小文字の違いによるアカウント重複を防止
      normalization_security: 'メール正規化でアカウント重複と混乱を防止'
    }
  end
end
