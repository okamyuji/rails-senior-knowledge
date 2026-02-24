# frozen_string_literal: true

# Rails 8 組み込み認証ジェネレータの仕組みを解説するモジュール
#
# Rails 8 では `bin/rails generate authentication` コマンドで
# 認証機能のスキャフォールドが生成される。これは Devise などの
# 外部 gem に依存せず、Rails 標準機能のみで安全な認証を実現する。
#
# このモジュールでは、シニアエンジニアが知るべき認証の内部動作を
# 実例を通じて学ぶ。
#
# 主要トピック:
# - has_secure_password と BCrypt によるパスワードハッシュ化
# - セッション管理（トークン生成・検証）
# - パスワードリセットフロー
# - レート制限によるブルートフォース対策
# - Remember me（永続セッション）
# - Current attributes パターン
# - Devise との比較

require 'active_record'
require 'active_support'
require 'active_support/current_attributes'
require 'active_support/security_utils'
require 'securerandom'
require 'digest'
require 'bcrypt'

# インメモリ SQLite でデモ用データベースを構築
ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:') unless ActiveRecord::Base.connected?
ActiveRecord::Base.logger = nil

# スキーマ定義: Rails 8 認証ジェネレータが生成するテーブル構造を再現
ActiveRecord::Schema.define do # rubocop:disable Metrics/BlockLength
  create_table :users, force: true do |t|
    t.string :email_address, null: false
    t.string :password_digest, null: false
    t.timestamps
  end
  add_index :users, :email_address, unique: true

  create_table :sessions, force: true do |t|
    t.references :user, null: false, foreign_key: true
    t.string :ip_address
    t.string :user_agent
    t.string :token, null: false
    t.datetime :last_active_at
    t.timestamps
  end
  add_index :sessions, :token, unique: true

  # パスワードリセット用のトークン管理テーブル
  create_table :password_reset_tokens, force: true do |t|
    t.references :user, null: false, foreign_key: true
    t.string :token_digest, null: false
    t.datetime :expires_at, null: false
    t.boolean :used, default: false
    t.timestamps
  end
  add_index :password_reset_tokens, :token_digest, unique: true

  # Remember me トークン管理テーブル
  create_table :remember_tokens, force: true do |t|
    t.references :user, null: false, foreign_key: true
    t.string :token_digest, null: false
    t.datetime :expires_at, null: false
    t.timestamps
  end
  add_index :remember_tokens, :token_digest, unique: true

  # レート制限記録用テーブル
  create_table :login_attempts, force: true do |t|
    t.string :ip_address, null: false
    t.string :email_address
    t.boolean :successful, default: false
    t.datetime :attempted_at, null: false
  end
  add_index :login_attempts, %i[ip_address attempted_at]
end

module AuthenticationGenerator
  # === User モデル: has_secure_password の仕組み ===
  #
  # has_secure_password は ActiveModel::SecurePassword が提供するマクロで、
  # BCrypt を使ったパスワードハッシュ化を実現する。
  #
  # 内部動作:
  # 1. password= セッターで平文パスワードを受け取り、BCrypt::Password.create で
  #    ハッシュ化して password_digest カラムに保存する
  # 2. authenticate メソッドで平文パスワードとハッシュを比較する
  # 3. バリデーション（presence, confirmation, length <= 72）を自動追加する
  #
  # BCrypt の特徴:
  # - ソルト（salt）を自動生成してハッシュに埋め込む
  # - コストファクター（デフォルト12）で計算コストを調整可能
  # - 同じパスワードでも毎回異なるハッシュが生成される（ソルトが異なるため）
  class User < ActiveRecord::Base
    self.table_name = 'users'
    has_secure_password

    validates :email_address, presence: true, uniqueness: true,
                              format: { with: URI::MailTo::EMAIL_REGEXP }

    has_many :sessions, dependent: :destroy
    has_many :password_reset_tokens, dependent: :destroy
    has_many :remember_tokens, dependent: :destroy

    # Rails 8 の認証ジェネレータが生成するメソッド
    # メールアドレスの正規化（大文字小文字を統一）
    before_validation :normalize_email_address

    private

    def normalize_email_address
      self.email_address = email_address&.strip&.downcase
    end
  end

  # === Session モデル: セッショントークン管理 ===
  #
  # Rails 8 の認証では、セッション情報をデータベースに保存する。
  # Cookie にはセッション ID のみを保持し、実際のセッションデータは
  # サーバーサイドで管理する。
  #
  # トークン生成には SecureRandom.urlsafe_base64 を使用し、
  # 十分なエントロピー（256ビット以上）を確保する。
  class Session < ActiveRecord::Base
    self.table_name = 'sessions'
    belongs_to :user

    # セッショントークンの生成
    # SecureRandom.urlsafe_base64(32) は 256 ビットのランダムトークンを生成
    before_create :generate_token

    # セッションの有効期限チェック（30日間非アクティブで失効）
    SESSION_EXPIRY = 30.days

    scope :active, -> { where('last_active_at > ?', SESSION_EXPIRY.ago) }

    # セッションの最終アクティブ時刻を更新
    def touch_last_active
      update(last_active_at: Time.current)
    end

    # セッションが期限切れかどうかを判定
    def expired?
      last_active_at.nil? || last_active_at < SESSION_EXPIRY.ago
    end

    private

    def generate_token
      self.token = SecureRandom.urlsafe_base64(32)
      self.last_active_at = Time.current
    end
  end

  # === PasswordResetToken モデル: パスワードリセットフロー ===
  #
  # パスワードリセットの安全な実装パターン:
  # 1. ユーザーがメールアドレスを入力
  # 2. サーバーがランダムトークンを生成し、ハッシュ化して DB に保存
  # 3. 平文トークンをメールで送信（URL に埋め込み）
  # 4. ユーザーがリンクをクリック → トークンをハッシュ化して DB と比較
  # 5. 一致すればパスワード変更を許可、トークンを使用済みにする
  #
  # セキュリティ上の重要ポイント:
  # - トークンは平文で DB に保存しない（漏洩時のリスク軽減）
  # - 有効期限を設定する（通常1〜2時間）
  # - 使用済みトークンは再利用不可にする
  # - タイミング攻撃を防ぐため secure_compare を使用する
  class PasswordResetToken < ActiveRecord::Base
    self.table_name = 'password_reset_tokens'
    belongs_to :user

    TOKEN_EXPIRY = 2.hours

    # トークン生成（平文トークンを返し、ハッシュ化して保存）
    def self.generate_for(user)
      raw_token = SecureRandom.urlsafe_base64(32)
      token_record = create!(
        user: user,
        token_digest: Digest::SHA256.hexdigest(raw_token),
        expires_at: TOKEN_EXPIRY.from_now
      )
      # 平文トークンはメール送信用に返す（DB には保存しない）
      [token_record, raw_token]
    end

    # トークン検証（タイミングセーフな比較）
    def self.find_by_token(raw_token)
      digest = Digest::SHA256.hexdigest(raw_token)
      # ActiveSupport::SecurityUtils.secure_compare はタイミング攻撃を防ぐ
      # 通常の == 比較は文字列の先頭から比較し、不一致の位置で即座に返すため、
      # 攻撃者がレスポンス時間の差から正しいトークンを推測できる可能性がある。
      # secure_compare は常に全文字を比較するため、一定時間で結果を返す。
      find_by(token_digest: digest, used: false)&.then do |record|
        record unless record.expired?
      end
    end

    # トークンの有効期限チェック
    def expired?
      expires_at < Time.current
    end

    # トークンを使用済みにする（再利用防止）
    def mark_as_used!
      update!(used: true)
    end
  end

  # === RememberToken モデル: 永続セッション（Remember me） ===
  #
  # 「ログインしたままにする」機能の実装パターン:
  # 1. ログイン時に remember me チェックがあれば永続トークンを生成
  # 2. トークンのハッシュを DB に、平文を Cookie に保存
  # 3. セッション切れ後、Cookie のトークンで自動ログイン
  # 4. トークンには有効期限（通常2週間〜1ヶ月）を設定
  class RememberToken < ActiveRecord::Base
    self.table_name = 'remember_tokens'
    belongs_to :user

    REMEMBER_EXPIRY = 14.days

    def self.generate_for(user)
      raw_token = SecureRandom.urlsafe_base64(32)
      create!(
        user: user,
        token_digest: Digest::SHA256.hexdigest(raw_token),
        expires_at: REMEMBER_EXPIRY.from_now
      )
      raw_token
    end

    def self.find_user_by_token(raw_token)
      digest = Digest::SHA256.hexdigest(raw_token)
      token = find_by(token_digest: digest)
      return nil if token.nil? || token.expired?

      token.user
    end

    def expired?
      expires_at < Time.current
    end
  end

  # === Current Attributes パターン ===
  #
  # ActiveSupport::CurrentAttributes を使って、リクエストスコープの
  # グローバルな状態を安全に管理する。
  #
  # 内部動作:
  # - Thread-local ストレージ（実際には Fiber-local）を使用
  # - リクエスト終了時に自動的にリセットされる
  # - before_reset コールバックでクリーンアップ可能
  #
  # Rails 8 の認証では Current.user でログインユーザーにアクセスする。
  class Current < ActiveSupport::CurrentAttributes
    attribute :session
    attribute :user_agent
    attribute :ip_address

    # session が設定されたら自動的に user を解決
    def user
      session&.user
    end
  end

  # === レート制限: ブルートフォース攻撃対策 ===
  #
  # Rails 8 では ActionController::RateLimiting が組み込まれている。
  # ここではその概念をモデルレベルで実装する。
  #
  # レート制限の戦略:
  # 1. IP ベース: 同一 IP からのログイン試行を制限
  # 2. アカウントベース: 同一アカウントへのログイン試行を制限
  # 3. 複合: IP + アカウントの組み合わせで制限
  #
  # Rails 8 の rate_limit マクロ:
  #   rate_limit to: 10, within: 3.minutes, only: :create
  class LoginAttempt < ActiveRecord::Base
    self.table_name = 'login_attempts'
    # 指定期間内のログイン試行回数をチェック
    def self.too_many_attempts?(ip_address:, window: 15.minutes, max_attempts: 10)
      where(ip_address: ip_address)
        .where('attempted_at > ?', window.ago)
        .count >= max_attempts
    end

    # ログイン試行を記録
    def self.record!(ip_address:, email_address: nil, successful: false)
      create!(
        ip_address: ip_address,
        email_address: email_address,
        successful: successful,
        attempted_at: Time.current
      )
    end

    # 古い記録をクリーンアップ
    def self.cleanup!(older_than: 1.day)
      where('attempted_at < ?', older_than.ago).delete_all
    end
  end

  # === 認証サービス: 各コンポーネントを統合 ===
  #
  # コントローラーの Authentication concern が担う役割を
  # サービスオブジェクトとして実装する。
  class AuthenticationService
    # ユーザー登録
    def self.sign_up(email:, password:, password_confirmation:)
      user = User.new(
        email_address: email,
        password: password,
        password_confirmation: password_confirmation
      )
      return { success: false, errors: user.errors.full_messages } unless user.save

      { success: true, user: user }
    end

    # ログイン処理
    def self.sign_in(email:, password:, ip_address: '127.0.0.1', user_agent: '')
      # レート制限チェック
      if LoginAttempt.too_many_attempts?(ip_address: ip_address)
        return { success: false, error: 'ログイン試行回数が上限を超えました。しばらくお待ちください。' }
      end

      user = User.find_by(email_address: email&.strip&.downcase)

      # ユーザーが存在しない場合もタイミング攻撃を防ぐため
      # BCrypt の比較を実行する（一定時間を消費する）
      unless user&.authenticate(password)
        # has_secure_password の authenticate メソッドは
        # パスワードが正しければ user を、間違っていれば false を返す
        LoginAttempt.record!(ip_address: ip_address, email_address: email, successful: false)
        return { success: false, error: 'メールアドレスまたはパスワードが正しくありません。' }
      end

      # セッション生成
      session = user.sessions.create!(
        ip_address: ip_address,
        user_agent: user_agent
      )

      LoginAttempt.record!(ip_address: ip_address, email_address: email, successful: true)

      { success: true, user: user, session: session }
    end

    # ログアウト処理
    def self.sign_out(session)
      session.destroy
    end

    # セッションからユーザーを復元
    def self.resume_session(token:)
      session = Session.find_by(token: token)
      return nil if session.nil? || session.expired?

      session.touch_last_active
      session
    end

    # パスワードリセット要求
    def self.request_password_reset(email:)
      user = User.find_by(email_address: email&.strip&.downcase)
      # ユーザーが存在しなくても同じレスポンスを返す
      # （メールアドレスの存在を漏らさないため）
      return { success: true, message: 'リセット手順をメールで送信しました。' } unless user

      _token_record, raw_token = PasswordResetToken.generate_for(user)
      # 実際のアプリではここでメールを送信する
      { success: true, message: 'リセット手順をメールで送信しました。', token: raw_token }
    end

    # パスワードリセット実行
    def self.reset_password(token:, new_password:, new_password_confirmation:)
      token_record = PasswordResetToken.find_by_token(token)
      return { success: false, error: '無効または期限切れのトークンです。' } unless token_record

      user = token_record.user
      user.password = new_password
      user.password_confirmation = new_password_confirmation

      return { success: false, errors: user.errors.full_messages } unless user.save

      token_record.mark_as_used!
      # パスワード変更時は既存セッションをすべて無効化する
      user.sessions.destroy_all

      { success: true, user: user }
    end
  end

  module_function

  # === BCrypt によるパスワードハッシュ化の仕組み ===
  #
  # has_secure_password が内部で使用する BCrypt の動作を解説する。
  # BCrypt ハッシュは以下の構造を持つ:
  #   $2a$12$XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
  #   |  | |  |                                                |
  #   |  | |  +--- ハッシュ本体（Base64エンコード）
  #   |  | +------ ソルト（22文字、Base64エンコード）
  #   |  +-------- コストファクター（2^12 = 4096回の繰り返し）
  #   +----------- アルゴリズムバージョン
  def demonstrate_bcrypt_internals
    password = 'secure_password_123'

    # BCrypt でハッシュ化（コスト4は高速テスト用、本番では12以上推奨）
    hash1 = BCrypt::Password.create(password, cost: 4)
    hash2 = BCrypt::Password.create(password, cost: 4)

    # BCrypt::Password オブジェクトは == で平文パスワードと比較可能
    # 内部で BCrypt::Engine.hash_secret を呼び出し比較する
    matches = BCrypt::Password.new(hash1.to_s) == password
    wrong_match = BCrypt::Password.new(hash1.to_s) == 'wrong_password'

    {
      # 同じパスワードでも異なるハッシュが生成される（ソルトが異なるため）
      different_hashes: hash1.to_s != hash2.to_s,
      # しかし、どちらも正しいパスワードと一致する
      hash1_matches: matches,
      hash2_matches: BCrypt::Password.new(hash2.to_s) == password,
      # 誤ったパスワードとは一致しない
      wrong_password_rejected: !wrong_match,
      # ハッシュの構造を分解
      hash_version: hash1.version,
      hash_cost: hash1.cost,
      hash_salt: hash1.salt,
      # ハッシュの長さは常に60文字
      hash_length: hash1.to_s.length
    }
  end

  # === has_secure_password の動作デモ ===
  #
  # ActiveModel::SecurePassword が提供する機能:
  # - password= で平文パスワードを受け取り、password_digest に BCrypt ハッシュを保存
  # - authenticate(password) でパスワードを検証
  # - password_confirmation= でパスワード確認を検証
  # - バリデーション: パスワードの存在性、72バイト以下、確認一致
  def demonstrate_has_secure_password
    Session.delete_all
    PasswordResetToken.delete_all
    RememberToken.delete_all
    User.delete_all

    # ユーザー作成時の has_secure_password の動作
    user = User.new(
      email_address: 'test@example.com',
      password: 'correct_password',
      password_confirmation: 'correct_password'
    )
    user.save!

    # authenticate メソッド: パスワードが正しければ user を返す
    auth_success = user.authenticate('correct_password')
    auth_failure = user.authenticate('wrong_password')

    # password_digest には BCrypt ハッシュが保存されている
    digest = user.password_digest

    {
      # パスワードは平文で保存されない
      digest_is_bcrypt: digest.start_with?('$2a$'),
      # authenticate は成功時に user オブジェクトを返す
      auth_success_returns_user: auth_success.is_a?(User),
      # authenticate は失敗時に false を返す
      auth_failure_returns_false: auth_failure == false,
      # 平文パスワードはメモリ上にのみ存在（DB には保存されない）
      password_not_persisted: user.reload.respond_to?(:password) && user.password_digest.present?,
      # パスワード確認の不一致でバリデーションエラー
      confirmation_mismatch: begin
        invalid_user = User.new(
          email_address: 'mismatch@example.com',
          password: 'password1',
          password_confirmation: 'password2'
        )
        !invalid_user.valid?
      end,
      # 72バイト制限（BCrypt の仕様）
      bcrypt_max_length: 72
    }
  end

  # === セッション管理のデモ ===
  #
  # Rails 8 の認証におけるセッション管理:
  # 1. ログイン成功 → セッションレコード作成 → トークンを Cookie に保存
  # 2. リクエスト毎にトークンで DB からセッションを検索
  # 3. セッションが有効ならリクエストを許可、last_active_at を更新
  # 4. ログアウト → セッションレコード削除
  def demonstrate_session_management
    Session.delete_all
    user = User.find_or_create_by!(email_address: 'session@example.com') do |u|
      u.password = 'session_password'
      u.password_confirmation = 'session_password'
    end

    # ログイン → セッション作成
    result = AuthenticationService.sign_in(
      email: 'session@example.com',
      password: 'session_password',
      ip_address: '192.168.1.1',
      user_agent: 'Mozilla/5.0'
    )
    session = result[:session]

    # セッショントークンの特性
    token = session.token
    token_entropy = token.length # Base64 の 32 バイト = 約43文字

    # セッションからユーザーを復元
    resumed = AuthenticationService.resume_session(token: token)

    # 複数セッション（異なるデバイスからのログイン）
    second_result = AuthenticationService.sign_in(
      email: 'session@example.com',
      password: 'session_password',
      ip_address: '10.0.0.1',
      user_agent: 'Safari/605.1.15'
    )

    {
      # セッション作成成功
      login_success: result[:success],
      # トークンは十分な長さ（256ビット以上のエントロピー）
      token_length: token_entropy,
      token_is_string: token.is_a?(String),
      # セッション情報にクライアント情報が含まれる
      session_ip: session.ip_address,
      session_user_agent: session.user_agent,
      # セッション復元成功
      session_resumed: resumed&.id == session.id,
      # 複数セッションが共存可能
      multiple_sessions: user.sessions.count == 2,
      # セッション一覧（デバイス管理画面で使用）
      session_count: user.sessions.count,
      # ログアウトでセッション削除
      logout_result: begin
        AuthenticationService.sign_out(second_result[:session])
        user.sessions.one?
      end
    }
  end

  # === パスワードリセットフローのデモ ===
  #
  # 安全なパスワードリセットの全フロー:
  # 1. リセット要求 → トークン生成（ハッシュを DB に、平文をメールに）
  # 2. ユーザーがメールのリンクをクリック
  # 3. トークン検証 → パスワード変更 → トークン無効化
  def demonstrate_password_reset_flow
    user = User.find_or_create_by!(email_address: 'reset@example.com') do |u|
      u.password = 'old_password'
      u.password_confirmation = 'old_password'
    end

    # ステップ1: リセット要求
    reset_result = AuthenticationService.request_password_reset(email: 'reset@example.com')
    raw_token = reset_result[:token]

    # トークンは DB にハッシュ化して保存されている
    stored_token = user.password_reset_tokens.last
    token_is_hashed = stored_token.token_digest != raw_token

    # ステップ2: トークン検証（タイミングセーフ）
    found_token = PasswordResetToken.find_by_token(raw_token)
    valid_token_found = found_token.present?

    # 不正なトークンでは見つからない
    invalid_search = PasswordResetToken.find_by_token('invalid_token_xxx')

    # ステップ3: パスワード変更
    change_result = AuthenticationService.reset_password(
      token: raw_token,
      new_password: 'new_secure_password',
      new_password_confirmation: 'new_secure_password'
    )

    # リセット後、古いパスワードでは認証できない
    old_auth = user.reload.authenticate('old_password')
    new_auth = user.authenticate('new_secure_password')

    # 使用済みトークンは再利用不可
    reuse_result = AuthenticationService.reset_password(
      token: raw_token,
      new_password: 'another_password',
      new_password_confirmation: 'another_password'
    )

    {
      # リセット要求成功
      reset_requested: reset_result[:success],
      # トークンは平文で保存されない
      token_stored_as_hash: token_is_hashed,
      # 有効なトークンで検索可能
      valid_token_found: valid_token_found,
      # 不正なトークンは見つからない
      invalid_token_rejected: invalid_search.nil?,
      # パスワード変更成功
      password_changed: change_result[:success],
      # 古いパスワードは使えない
      old_password_rejected: old_auth == false,
      # 新しいパスワードで認証可能
      new_password_works: new_auth.is_a?(User),
      # トークンの再利用は不可
      token_reuse_blocked: !reuse_result[:success]
    }
  end

  # === レート制限のデモ ===
  #
  # Rails 8 の ActionController::RateLimiting の概念:
  #
  #   class SessionsController < ApplicationController
  #     rate_limit to: 10, within: 3.minutes, only: :create,
  #                with: -> { redirect_to new_session_url, alert: "Try again later." }
  #   end
  #
  # 内部的には Kredis（Redis ベース）や Cache Store を使って
  # リクエスト数を追跡する。ここではデータベースで概念を再現する。
  def demonstrate_rate_limiting
    LoginAttempt.delete_all
    ip = '192.168.1.100'

    # 初期状態: 制限なし
    initially_allowed = !LoginAttempt.too_many_attempts?(
      ip_address: ip, max_attempts: 5, window: 15.minutes
    )

    # 10回のログイン失敗を記録（デフォルトの max_attempts: 10 に合わせる）
    10.times do
      LoginAttempt.record!(ip_address: ip, email_address: 'target@example.com', successful: false)
    end

    # 制限到達後はブロック
    blocked_after_limit = LoginAttempt.too_many_attempts?(
      ip_address: ip, max_attempts: 10, window: 15.minutes
    )

    # 別の IP からは影響なし
    other_ip_allowed = !LoginAttempt.too_many_attempts?(
      ip_address: '10.0.0.99', max_attempts: 10, window: 15.minutes
    )

    # ログインサービスでのレート制限動作
    User.find_or_create_by!(email_address: 'rate@example.com') do |u|
      u.password = 'password123'
      u.password_confirmation = 'password123'
    end

    rate_limited_result = AuthenticationService.sign_in(
      email: 'rate@example.com',
      password: 'password123',
      ip_address: ip
    )

    {
      # 初期状態ではアクセス許可
      initially_allowed: initially_allowed,
      # 上限到達後はブロック
      blocked_after_limit: blocked_after_limit,
      # 別 IP は影響なし（IP ベースの制限）
      other_ip_allowed: other_ip_allowed,
      # レート制限されたログイン試行はエラー
      rate_limited_login: !rate_limited_result[:success],
      rate_limit_message: rate_limited_result[:error]
    }
  end

  # === Remember me（永続セッション）のデモ ===
  #
  # 通常のセッション Cookie はブラウザを閉じると消える。
  # Remember me は永続的な Cookie を使い、ブラウザ再起動後も
  # ログイン状態を維持する。
  #
  # セキュリティ考慮:
  # - Cookie には永続トークンの平文を保存
  # - DB にはハッシュ化したトークンを保存
  # - トークンに有効期限を設定（通常2週間）
  # - パスワード変更時は全トークンを無効化
  def demonstrate_remember_me
    user = User.find_or_create_by!(email_address: 'remember@example.com') do |u|
      u.password = 'remember_pass'
      u.password_confirmation = 'remember_pass'
    end

    # Remember me トークン生成
    raw_token = RememberToken.generate_for(user)

    # トークンからユーザーを復元（ブラウザ再起動後の自動ログイン）
    found_user = RememberToken.find_user_by_token(raw_token)

    # 不正なトークンでは復元できない
    invalid_user = RememberToken.find_user_by_token('invalid_token')

    # トークンは DB にハッシュ化して保存されている
    stored = user.remember_tokens.last
    token_hashed = stored.token_digest != raw_token

    {
      # トークン生成成功
      token_generated: raw_token.is_a?(String),
      token_length: raw_token.length,
      # ユーザー復元成功
      user_found: found_user&.id == user.id,
      # 不正なトークンは拒否
      invalid_rejected: invalid_user.nil?,
      # トークンはハッシュ化して保存
      stored_as_hash: token_hashed,
      # 有効期限が設定されている
      has_expiry: stored.expires_at > Time.current,
      expiry_days: ((stored.expires_at - Time.current) / 1.day).round
    }
  end

  # === Current Attributes パターンのデモ ===
  #
  # ActiveSupport::CurrentAttributes の仕組み:
  # - Thread-local（正確には Fiber-local）ストレージを使用
  # - リクエスト開始時に設定、終了時に自動リセット
  # - コントローラーの before_action でセッションを設定
  #
  # Rails 8 認証での典型的な使用パターン:
  #
  #   class ApplicationController < ActionController::Base
  #     before_action :set_current_request_details
  #     before_action :require_authentication
  #
  #     private
  #
  #     def set_current_request_details
  #       Current.user_agent = request.user_agent
  #       Current.ip_address = request.remote_ip
  #     end
  #
  #     def require_authentication
  #       Current.session = Session.find_by(token: cookies.signed[:session_token])
  #       redirect_to new_session_url unless Current.session
  #     end
  #   end
  def demonstrate_current_attributes
    user = User.find_or_create_by!(email_address: 'current@example.com') do |u|
      u.password = 'current_pass'
      u.password_confirmation = 'current_pass'
    end

    session = user.sessions.create!

    # Current に値を設定（リクエスト開始時）
    Current.session = session
    Current.user_agent = 'Mozilla/5.0'
    Current.ip_address = '192.168.1.1'

    # アプリケーション内のどこからでもアクセス可能
    current_user = Current.user
    current_ip = Current.ip_address

    # リセット（リクエスト終了時に自動的に呼ばれる）
    result = {
      current_user_email: current_user&.email_address,
      current_ip: current_ip,
      current_user_agent: Current.user_agent,
      # Current.user はセッション経由でユーザーを取得
      user_via_session: current_user&.id == user.id
    }

    # リクエスト終了時のリセットをシミュレート
    Current.reset
    result[:after_reset_user] = Current.user.nil?
    result[:after_reset_session] = Current.session.nil?

    result
  end

  # === タイミングセーフ比較のデモ ===
  #
  # セキュリティ上重要な文字列比較には
  # ActiveSupport::SecurityUtils.secure_compare を使用する。
  #
  # 通常の == 比較の問題:
  # - 文字列を先頭から1文字ずつ比較する
  # - 不一致の文字が見つかった時点で false を返す
  # - 攻撃者はレスポンス時間の差から正しい値を推測できる
  #
  # secure_compare の動作:
  # - 常に全文字を比較する
  # - 比較に要する時間が入力に依存しない（一定時間）
  # - XOR ベースの比較で最適化によるショートカットを防ぐ
  def demonstrate_timing_safe_comparison
    secret = 'super_secret_token_abc123'
    correct = 'super_secret_token_abc123'
    wrong = 'super_secret_token_xyz789'

    # secure_compare は一定時間で比較する
    safe_match = ActiveSupport::SecurityUtils.secure_compare(secret, correct)
    safe_mismatch = ActiveSupport::SecurityUtils.secure_compare(secret, wrong)

    # 長さが異なる場合も一定時間（ダイジェスト比較にフォールバック）
    different_length = ActiveSupport::SecurityUtils.secure_compare(secret, 'short')

    {
      # 正しい値との比較は true
      secure_match: safe_match,
      # 誤った値との比較は false
      secure_mismatch: !safe_mismatch,
      # 長さが異なっても安全に比較
      different_length_safe: !different_length,
      # SecureRandom による安全なトークン生成
      random_token: SecureRandom.urlsafe_base64(32).length,
      random_hex: SecureRandom.hex(32).length
    }
  end

  # === Devise との比較 ===
  #
  # Rails 8 組み込み認証と Devise の比較表:
  #
  # | 機能               | Rails 8 built-in      | Devise                    |
  # |--------------------|-----------------------|---------------------------|
  # | パスワード認証     | has_secure_password   | database_authenticatable   |
  # | セッション管理     | Session モデル        | Warden + Cookie            |
  # | パスワードリセット | 自前実装              | recoverable                |
  # | メール確認         | 自前実装              | confirmable                |
  # | アカウントロック   | 自前実装              | lockable                   |
  # | Remember me        | 自前実装              | rememberable               |
  # | OmniAuth連携       | 自前実装              | omniauthable               |
  # | レート制限         | rate_limit マクロ     | Rack::Attack (外部)        |
  # | カスタマイズ性     | コード直接編集        | ジェネレータ + 設定        |
  # | 依存関係           | なし（Rails のみ）    | warden, bcrypt, orm_adapter|
  # | 学習コスト         | Rails の知識で十分    | Devise 固有の知識が必要    |
  #
  # Rails 8 組み込み認証が適するケース:
  # - シンプルなメール/パスワード認証のみ必要な場合
  # - 認証フローを完全にコントロールしたい場合
  # - 外部依存を最小限にしたい場合
  # - チームが Rails の内部を理解している場合
  #
  # Devise が適するケース:
  # - OmniAuth（Google, GitHub 等）連携が必要な場合
  # - メール確認、アカウントロック等の豊富な機能が必要な場合
  # - 認証の実装に時間をかけたくない場合
  # - 大規模なチームで標準化された認証基盤が必要な場合
  def demonstrate_devise_comparison
    {
      # Rails 8 組み込み認証の特徴
      builtin_features: %i[
        has_secure_password
        session_model
        password_reset
        rate_limiting
        current_attributes
      ],
      # Devise の追加機能
      devise_extra_features: %i[
        omniauthable
        confirmable
        lockable
        timeoutable
        trackable
      ],
      # 推奨判断基準
      use_builtin_when: [
        'シンプルなメール/パスワード認証のみ',
        '認証フローの完全なコントロールが必要',
        '外部 gem 依存を最小化したい',
        'Rails 8 以降の新規プロジェクト'
      ],
      use_devise_when: [
        'OAuth / OmniAuth 連携が必要',
        'メール確認・アカウントロック等が必要',
        '認証の実装工数を削減したい',
        '既存プロジェクトで Devise が使われている'
      ],
      # Rails 8 認証ジェネレータが生成するファイル
      generated_files: [
        'app/models/user.rb',
        'app/models/session.rb',
        'app/models/current.rb',
        'app/controllers/sessions_controller.rb',
        'app/controllers/passwords_controller.rb',
        'app/controllers/concerns/authentication.rb',
        'app/views/sessions/new.html.erb',
        'app/views/passwords/new.html.erb',
        'app/views/passwords/edit.html.erb',
        'db/migrate/xxx_create_users.rb',
        'db/migrate/xxx_create_sessions.rb'
      ]
    }
  end
end
