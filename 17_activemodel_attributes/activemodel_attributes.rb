# frozen_string_literal: true

require 'active_model'
require 'bigdecimal'

# ActiveModel属性APIの内部構造と活用パターンを解説するモジュール
#
# ActiveModelはActiveRecordからデータベース依存を除いた属性管理の仕組みを提供する。
# フォームオブジェクト、サービスオブジェクト、Value Objectなど、
# データベースに紐づかないモデル層を構築する際の基盤となる。
#
# シニアエンジニアが知るべきポイント:
# - ActiveModel::Attributesによる型付き属性の定義と型キャスト
# - カスタム型の作成方法
# - Dirty Trackingによる変更追跡
# - フォームオブジェクトパターンの実践的な設計
module ActiveModelAttributes
  module_function

  # === ActiveModel::Model と ActiveModel::Attributes の基本 ===
  #
  # ActiveModel::Model は以下の機能をまとめてインクルードする:
  #   - ActiveModel::AttributeAssignment（属性の一括代入）
  #   - ActiveModel::Validations（バリデーション）
  #   - ActiveModel::Conversion（to_model, to_key, to_param）
  #   - ActiveModel::Naming（model_name によるルーティング/フォーム連携）
  #
  # ActiveModel::Attributes はさらに型付き属性を追加する:
  #   - attribute メソッドで属性名と型を宣言
  #   - 自動的な型キャスト
  #   - デフォルト値の設定
  #
  # ActiveRecordの attribute API と同じインターフェースを持つため、
  # データベースモデルとフォームオブジェクトで統一的なAPIを使える。
  class BasicProfile
    include ActiveModel::Model
    include ActiveModel::Attributes

    attribute :name, :string
    attribute :age, :integer
    attribute :active, :boolean, default: true
  end

  def demonstrate_basic_attributes
    profile = BasicProfile.new(name: '田中太郎', age: '30', active: '1')

    {
      # 文字列として代入した値が型キャストされる
      name: profile.name,
      name_class: profile.name.class,
      # "30" が Integer にキャストされる
      age: profile.age,
      age_class: profile.age.class,
      # "1" が Boolean（true）にキャストされる
      active: profile.active,
      # デフォルト値が設定される
      default_active: BasicProfile.new.active,
      # nil を渡した場合はnilのまま（デフォルト値にはならない）
      nil_age: BasicProfile.new(age: nil).age,
      # attributes メソッドで全属性のハッシュを取得
      attributes: profile.attributes
    }
  end

  # === 組み込み型と型キャスト ===
  #
  # ActiveModelが標準で提供する型:
  #   :string   - to_s で文字列に変換
  #   :integer  - to_i で整数に変換（浮動小数点は切り捨て）
  #   :float    - to_f で浮動小数点に変換
  #   :decimal  - BigDecimal に変換（金額計算に必須）
  #   :boolean  - truthy/falsy の判定（"0", "f", "false" → false）
  #   :date     - Date オブジェクトに変換
  #   :datetime - DateTime/Time オブジェクトに変換
  #   :time     - Time オブジェクトに変換
  #
  # 型キャストのルール:
  # - nil は常に nil のまま（どの型でもキャストしない）
  # - 空文字列 "" は :integer, :float, :decimal では nil になる
  # - Boolean型: "0", "f", "false", "F", "FALSE", "off", "OFF" → false
  # - Boolean型: "1", "t", "true", "T", "TRUE", "on", "ON" → true
  class TypeCastingExample
    include ActiveModel::Model
    include ActiveModel::Attributes

    attribute :string_val, :string
    attribute :integer_val, :integer
    attribute :float_val, :float
    attribute :decimal_val, :decimal
    attribute :boolean_val, :boolean
    attribute :date_val, :date
    attribute :datetime_val, :datetime
  end

  def demonstrate_type_casting
    example = TypeCastingExample.new

    # 文字列から整数へのキャスト
    example.integer_val = '42'
    integer_from_string = example.integer_val

    # 浮動小数点から整数へのキャスト（切り捨て）
    example.integer_val = 3.7
    integer_from_float = example.integer_val

    # 文字列からDecimalへのキャスト
    example.decimal_val = '19.99'
    decimal_from_string = example.decimal_val

    # Boolean型のキャスト（多様な入力に対応）
    boolean_results = %w[1 0 true false t f on off yes no].map do |val|
      example.boolean_val = val
      [val, example.boolean_val]
    end

    # 空文字列の扱い（数値型ではnilになる）
    example.integer_val = ''
    integer_from_empty = example.integer_val

    example.string_val = ''
    string_from_empty = example.string_val

    # 日付文字列のキャスト
    example.date_val = '2024-12-25'
    date_from_string = example.date_val

    {
      integer_from_string: integer_from_string,
      integer_from_string_class: integer_from_string.class,
      integer_from_float: integer_from_float,
      decimal_from_string: decimal_from_string,
      decimal_class: decimal_from_string.class,
      boolean_casting: boolean_results.to_h,
      # 空文字列は数値型でnil、文字列型では空文字列のまま
      integer_from_empty: integer_from_empty,
      string_from_empty: string_from_empty,
      # 日付文字列はDateオブジェクトに変換
      date_from_string: date_from_string,
      date_class: date_from_string.class
    }
  end

  # === カスタム型の作成 ===
  #
  # ActiveModel::Type::Value を継承してカスタム型を定義できる。
  # 実装すべきメソッド:
  #   - cast(value): ユーザー入力からの変換
  #   - serialize(value): 永続化時の変換（ActiveRecordで使用）
  #   - deserialize(value): 永続化層からの復元
  #   - type: 型名のシンボル
  #
  # 実務でのユースケース:
  # - 電話番号のフォーマット正規化
  # - メールアドレスの小文字化
  # - カンマ区切り文字列 ↔ 配列の変換
  # - JSONフィールドのパース
  class EmailType < ActiveModel::Type::Value
    # 型名を返す（デバッグやイントロスペクションで使用）
    def type
      :email
    end

    private

    # ユーザー入力を正規化された形式に変換する
    # strip で前後の空白を除去し、downcase で小文字に統一する
    def cast_value(value)
      return nil if value.blank?

      value.to_s.strip.downcase
    end
  end

  # カンマ区切り文字列を配列として扱うカスタム型
  # フォームの複数選択やタグ入力で活用できる
  class StringArrayType < ActiveModel::Type::Value
    def type
      :string_array
    end

    # changed_in_place? をオーバーライドして配列の内容変更を検知する
    def changed_in_place?(raw_old_value, new_value)
      raw_old_value != serialize(new_value)
    end

    private

    def cast_value(value)
      case value
      when Array
        value.map(&:to_s).reject(&:blank?)
      when String
        value.split(',').map(&:strip).reject(&:blank?)
      else
        []
      end
    end
  end

  # カスタム型をグローバルレジストリに登録する
  # 登録後は attribute :field, :email のように使える
  ActiveModel::Type.register(:email, EmailType)
  ActiveModel::Type.register(:string_array, StringArrayType)

  class ContactForm
    include ActiveModel::Model
    include ActiveModel::Attributes

    attribute :email, :email
    attribute :tags, :string_array
  end

  def demonstrate_custom_types
    form = ContactForm.new

    # メールアドレスの正規化
    form.email = '  Admin@Example.COM  '

    # カンマ区切り文字列から配列へ
    form.tags = 'ruby, rails, activemodel'

    # 配列からの代入も可能
    form_with_array = ContactForm.new(tags: ['ruby', 'rails', ''])

    {
      # メールアドレスが小文字化・トリミングされる
      normalized_email: form.email,
      # カンマ区切り文字列が配列に変換される
      tags_from_string: form.tags,
      # 空要素は除去される
      tags_from_array: form_with_array.tags,
      # nil の場合
      nil_email: ContactForm.new(email: nil).email,
      # 空文字列の場合
      blank_email: ContactForm.new(email: '').email
    }
  end

  # === デフォルト値（静的・動的） ===
  #
  # default オプションで属性のデフォルト値を設定できる。
  # - 静的デフォルト: 固定値（数値、文字列、booleanなど）
  # - 動的デフォルト: Proc を渡すことで、インスタンス生成時に評価される
  #
  # 動的デフォルトはタイムスタンプやUUID生成など、
  # インスタンスごとに異なる値が必要な場合に使用する。
  #
  # 注意: 静的デフォルトでミュータブルなオブジェクト（配列やハッシュ）を
  # 渡すと、全インスタンスで同じオブジェクトが共有される可能性があるため、
  # Proc を使うべきである。
  class EventRegistration
    include ActiveModel::Model
    include ActiveModel::Attributes

    attribute :name, :string
    # 静的デフォルト
    attribute :status, :string, default: 'pending'
    attribute :max_participants, :integer, default: 10
    # 動的デフォルト（Procで毎回評価）
    attribute :registered_at, :datetime, default: -> { Time.now }
    attribute :token, :string, default: -> { SecureRandom.hex(8) }
  end

  def demonstrate_default_values
    reg1 = EventRegistration.new(name: 'Ruby会議')
    # 少し待って別のインスタンスを生成
    reg2 = EventRegistration.new(name: 'Rails勉強会')

    {
      # 静的デフォルト値
      default_status: reg1.status,
      default_max: reg1.max_participants,
      # 動的デフォルト値（インスタンスごとに異なる）
      reg1_token: reg1.token,
      reg2_token: reg2.token,
      tokens_differ: reg1.token != reg2.token,
      # 明示的に値を指定するとデフォルトは使われない
      custom_status: EventRegistration.new(status: 'confirmed').status,
      # registered_at はDateTimeオブジェクト
      registered_at_class: reg1.registered_at.class
    }
  end

  # === Dirty Tracking（変更追跡） ===
  #
  # ActiveModel::Dirty をインクルードすると、属性の変更を追跡できる。
  # ActiveRecordでは自動的に有効だが、ActiveModel単体では
  # 明示的にインクルードして設定する必要がある。
  #
  # 主要メソッド:
  #   changed?           - いずれかの属性が変更されたか
  #   changed            - 変更された属性名の配列
  #   changes            - { 属性名 => [変更前, 変更後] } のハッシュ
  #   <attr>_changed?    - 特定の属性が変更されたか
  #   <attr>_was         - 変更前の値
  #   <attr>_change      - [変更前, 変更後] の配列
  #   changes_applied    - 変更を確定（previous_changes に移動）
  #   previous_changes   - 直前に確定された変更
  #   restore_attributes - 変更を元に戻す
  #
  # 実務での活用:
  # - 変更のあったフィールドだけを更新するAPI呼び出し
  # - 監査ログへの変更内容の記録
  # - 変更通知メールの送信判定
  class UserProfile
    include ActiveModel::Model
    include ActiveModel::Attributes
    include ActiveModel::Dirty

    attribute :name, :string
    attribute :email, :string
    attribute :age, :integer

    # Dirty Tracking を機能させるには、属性のセッターで
    # <attr>_will_change! を呼ぶか、ActiveModel::Attributes と
    # 組み合わせて使う必要がある。
    # ActiveModel::Attributes と Dirty を両方インクルードした場合、
    # attribute で定義した属性は自動的にDirty対応になる。

    # 変更を「保存」するメソッド（ActiveRecordのsaveに相当）
    def save
      changes_applied
      true
    end

    # 変更を元に戻すメソッド
    def rollback
      restore_attributes
    end
  end

  def demonstrate_dirty_tracking
    user = UserProfile.new(name: '佐藤', email: 'sato@example.com', age: 25)
    # 初期状態を確定させる
    user.save

    # 属性を変更
    user.name = '鈴木'
    user.email = 'suzuki@example.com'

    changed_state = {
      changed: user.changed?,
      changed_attributes_list: user.changed,
      changes: user.changes,
      name_changed: user.name_changed?,
      name_was: user.name_was,
      name_change: user.name_change,
      # 変更していない属性
      age_changed: user.age_changed?
    }

    # 変更を保存（確定）
    user.save

    after_save_state = {
      changed_after_save: user.changed?,
      previous_changes: user.previous_changes
    }

    # restore_attributes のデモ
    user_for_rollback = UserProfile.new(name: '田中', email: 'tanaka@example.com')
    user_for_rollback.save
    user_for_rollback.name = '山田'
    user_for_rollback.rollback

    rollback_state = {
      name_after_rollback: user_for_rollback.name,
      changed_after_rollback: user_for_rollback.changed?
    }

    {
      changed_state: changed_state,
      after_save_state: after_save_state,
      rollback_state: rollback_state
    }
  end

  # === バリデーション連携 ===
  #
  # ActiveModel::Validations は ActiveModel::Model に含まれているため、
  # ActiveRecordと同じバリデーションDSLが使える。
  #
  # 型付き属性とバリデーションを組み合わせることで、
  # 型キャスト後の値に対してバリデーションが実行される点に注意。
  # 例: "abc" を :integer 型属性に代入 → nil にキャスト →
  #     presence バリデーションで失敗
  class RegistrationForm
    include ActiveModel::Model
    include ActiveModel::Attributes

    attribute :username, :string
    attribute :email, :string
    attribute :age, :integer
    attribute :terms_accepted, :boolean

    validates :username, presence: true, length: { minimum: 3, maximum: 20 }
    validates :email, presence: true, format: { with: /\A[^@\s]+@[^@\s]+\z/ }
    validates :age, numericality: { greater_than_or_equal_to: 18 }, allow_nil: true
    validates :terms_accepted, acceptance: { accept: true }

    # カスタムバリデーション
    validate :username_not_reserved

    RESERVED_NAMES = %w[admin root system operator].freeze

    private

    def username_not_reserved
      return unless username.present? && RESERVED_NAMES.include?(username.downcase)

      errors.add(:username, 'は予約語のため使用できません')
    end
  end

  def demonstrate_validations
    # 有効なフォーム
    valid_form = RegistrationForm.new(
      username: 'taro',
      email: 'taro@example.com',
      age: '25',
      terms_accepted: '1'
    )

    # 無効なフォーム（複数のエラー）
    invalid_form = RegistrationForm.new(
      username: 'ab',
      email: 'invalid-email',
      age: '15',
      terms_accepted: '0'
    )

    # 予約語チェック
    reserved_form = RegistrationForm.new(
      username: 'admin',
      email: 'admin@example.com',
      terms_accepted: '1'
    )

    {
      valid_result: valid_form.valid?,
      valid_errors: valid_form.errors.full_messages,
      invalid_result: invalid_form.valid?,
      invalid_errors: invalid_form.errors.full_messages,
      # エラーメッセージを属性ごとに取得
      invalid_errors_by_attr: invalid_form.errors.group_by_attribute.transform_values do |errs|
        errs.map(&:message)
      end,
      # 型キャストされた値に対してバリデーションが行われる
      casted_age: invalid_form.age,
      reserved_valid: reserved_form.valid?,
      reserved_errors: reserved_form.errors.full_messages
    }
  end

  # === シリアライゼーション ===
  #
  # ActiveModel::Serialization をインクルードすると、
  # serializable_hash メソッドが使えるようになる。
  # ActiveModel::Serializers::JSON をインクルードすると、
  # さらに as_json, to_json, from_json が追加される。
  #
  # attributes メソッドを定義してシリアライズ対象を指定する。
  # ActiveModel::Attributes を使っている場合は自動的に定義される。
  class ApiResponse
    include ActiveModel::Model
    include ActiveModel::Attributes
    include ActiveModel::Serializers::JSON

    attribute :id, :integer
    attribute :title, :string
    attribute :score, :float
    attribute :published, :boolean, default: false
    attribute :created_at, :datetime
  end

  def demonstrate_serialization
    response = ApiResponse.new(
      id: '1',
      title: 'ActiveModelガイド',
      score: '4.5',
      published: 'true',
      created_at: '2024-12-25 10:30:00'
    )

    # JSON出力のカスタマイズ
    json_with_options = response.as_json(
      only: %i[id title score],
      methods: []
    )

    # from_json でJSONからオブジェクトを復元
    restored = ApiResponse.new
    restored.from_json('{"id": 2, "title": "復元テスト", "score": 3.8}')

    {
      # serializable_hash は属性のハッシュを返す
      serializable_hash: response.serializable_hash,
      # as_json はJSON互換の形式に変換
      as_json: response.as_json,
      # only オプションで出力フィールドを限定
      json_with_options: json_with_options,
      # to_json はJSON文字列を返す
      to_json_string: response.to_json,
      # from_json で復元したオブジェクト
      restored_id: restored.id,
      restored_title: restored.title,
      restored_score: restored.score
    }
  end

  # === フォームオブジェクトパターン ===
  #
  # フォームオブジェクトは、複数のモデルにまたがるフォーム入力を
  # 単一のオブジェクトとして扱うパターンである。
  #
  # 利点:
  # - コントローラーのスリム化（fat controller の回避）
  # - 複雑なバリデーションロジックの集約
  # - モデル間の整合性チェック
  # - テストの容易さ（ActiveRecordに依存しない）
  #
  # 設計の指針:
  # - ActiveModel::Model + ActiveModel::Attributes をベースにする
  # - save メソッドでトランザクション内の永続化処理を行う
  # - バリデーション失敗時はfalseを返し、errorsにメッセージを格納する
  # - 成功時のコールバック（メール送信など）もフォームオブジェクト内で管理する
  class UserRegistrationForm
    include ActiveModel::Model
    include ActiveModel::Attributes

    # ユーザー情報
    attribute :name, :string
    attribute :email, :string
    attribute :password, :string

    # プロフィール情報
    attribute :bio, :string
    attribute :website, :string

    # 同意
    attribute :terms_accepted, :boolean

    validates :name, presence: true
    validates :email, presence: true, format: { with: /\A[^@\s]+@[^@\s]+\z/ }
    validates :password, presence: true, length: { minimum: 8 }
    validates :terms_accepted, acceptance: { accept: true }

    # フォームオブジェクトの save メソッド
    # 実務ではここでActiveRecordモデルの生成・保存を行う
    def save
      return false unless valid?

      # 実務ではトランザクション内で複数モデルを保存する
      # ActiveRecord::Base.transaction do
      #   user = User.create!(name: name, email: email, password: password)
      #   user.create_profile!(bio: bio, website: website)
      #   UserMailer.welcome(user).deliver_later
      # end

      # デモ用: 成功を示すハッシュを返す
      {
        user: { name: name, email: email },
        profile: { bio: bio, website: website }
      }
    rescue StandardError => e
      errors.add(:base, "登録処理中にエラーが発生しました: #{e.message}")
      false
    end

    # フォームの結果を構造化して返すメソッド
    def to_result
      {
        name: name,
        email: email,
        bio: bio,
        website: website,
        terms_accepted: terms_accepted
      }
    end
  end

  def demonstrate_form_object_pattern
    # 有効な登録フォーム
    valid_registration = UserRegistrationForm.new(
      name: '山田太郎',
      email: 'yamada@example.com',
      password: 'securepassword123',
      bio: 'Rubyエンジニア',
      website: 'https://example.com',
      terms_accepted: '1'
    )

    # 無効な登録フォーム
    invalid_registration = UserRegistrationForm.new(
      name: '',
      email: 'invalid',
      password: 'short',
      terms_accepted: '0'
    )

    valid_result = valid_registration.save
    invalid_result = invalid_registration.save

    {
      # 有効なフォームの保存結果
      valid_save_result: valid_result,
      # 無効なフォームの保存結果
      invalid_save_result: invalid_result,
      invalid_errors: invalid_registration.errors.full_messages,
      # model_name を使ったルーティング/i18n連携
      model_name: UserRegistrationForm.model_name.human,
      param_key: UserRegistrationForm.model_name.param_key,
      # to_result でフォーム内容を構造化
      form_result: valid_registration.to_result
    }
  end
end
