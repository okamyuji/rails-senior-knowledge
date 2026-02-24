# ActiveModel属性API

## ActiveModel属性APIの理解が重要な理由

ActiveModelはRailsのモデル層の基盤であり、ActiveRecordからデータベース依存を分離した属性管理の仕組みを提供します。
シニアエンジニアがActiveModelを深く理解すべき理由は以下の通りです。

- フォームオブジェクトの設計に活用できます。複数モデルにまたがるフォーム処理を、単一の責務を持つオブジェクトとして設計できます
- 型安全なAPI設計が可能になります。型キャストにより、コントローラーから受け取る文字列パラメータを安全に型変換できます
- ActiveRecordとの統一的なインターフェースを利用できます。同じ `attribute`
  APIをデータベースモデルとフォームオブジェクトで共有できます
- テストが容易になります。データベースに依存しないモデルを構築することで、高速なユニットテストが書けます
- Dirty Trackingを活用できます。変更された属性のみを処理する効率的なロジックを実装できます

## ActiveModel属性APIの仕組み

### 基本的な属性定義

`ActiveModel::Attributes` をインクルードすると、`attribute` マクロが使えるようになります。これはActiveRecordの
`attribute` と同じインターフェースを持ちます。

```ruby

class UserForm
  include ActiveModel::Model       # バリデーション、命名、変換
  include ActiveModel::Attributes  # 型付き属性

  attribute :name, :string
  attribute :age, :integer
  attribute :active, :boolean, default: true
end

form = UserForm.new(name: "田中", age: "30", active: "1")
form.age     # => 30 （Integerにキャスト済み）
form.active  # => true （Booleanにキャスト済み）

```

### 組み込み型一覧

| 型 | Rubyクラス | キャスト動作
| --- | --- | ---
| `:string` | `String` | `to_s` で変換します
| `:integer` | `Integer` | `to_i` で変換します（浮動小数点は切り捨てます）
| `:float` | `Float` | `to_f` で変換します
| `:decimal` | `BigDecimal` | 正確な小数計算用です（金額に必須です）
| `:boolean` | `TrueClass`/`FalseClass` | "1","true","on" → true、"0","false","off" → falseに変換します
| `:date` | `Date` | ISO 8601文字列をパースします
| `:datetime` | `Time` | ISO 8601文字列をパースします
| `:time` | `Time` | 時刻文字列をパースします

### 型キャストの詳細ルール

型キャストにおいて注意すべきエッジケースがあります。

```ruby

# 空文字列の扱い

form.integer_val = ""  # => nil （数値型では空文字列はnilになります）
form.string_val = ""   # => ""  （文字列型では空文字列のままです）

# Boolean型の判定

# true として扱われる値: "1", "t", "true", "T", "TRUE", "on", "ON"

# false として扱われる値: "0", "f", "false", "F", "FALSE", "off", "OFF"

# nil は nil のままです（true/false のどちらにもなりません）

# nilは常にnilのままです（どの型でも同様です）

form.age = nil  # => nil （デフォルト値にはなりません）

```

## カスタム型の作成方法

### ActiveModel::Type::Valueの継承

独自の型を作成するには `ActiveModel::Type::Value` を継承し、`cast_value` メソッドをオーバーライドします。

```ruby

class EmailType < ActiveModel::Type::Value
  def type
    :email
  end

  private

  def cast_value(value)
    return nil if value.blank?
    value.to_s.strip.downcase
  end
end

# グローバルレジストリに登録します

ActiveModel::Type.register(:email, EmailType)

# 使用例

class ContactForm
  include ActiveModel::Model
  include ActiveModel::Attributes

  attribute :email, :email
end

form = ContactForm.new(email: "  Admin@Example.COM  ")
form.email  # => "admin@example.com"

```

### カスタム型で実装すべきメソッド

| メソッド | 用途
| --------- | ------
| `cast_value(value)` | ユーザー入力からの変換です（必須）
| `serialize(value)` | 永続化時の変換です（ActiveRecordで使用します）
| `deserialize(value)` | 永続化層からの復元です
| `type` | 型名のシンボルです（イントロスペクション用）
| `changed_in_place?(old, new)` | インプレース変更の検知です（配列やハッシュ型で重要です）

### 実務で役立つカスタム型の例

```ruby

# カンマ区切り文字列と配列を相互変換します

class StringArrayType < ActiveModel::Type::Value
  def type
    :string_array
  end

  def changed_in_place?(raw_old_value, new_value)
    raw_old_value != serialize(new_value)
  end

  private

  def cast_value(value)
    case value
    when Array  then value.map(&:to_s).reject(&:blank?)
    when String then value.split(",").map(&:strip).reject(&:blank?)
    else []
    end
  end
end

```

## フォームオブジェクト設計パターン

### 基本的なフォームオブジェクト

フォームオブジェクトは、コントローラーとモデルの間に位置するレイヤーです。複数モデルへの操作を1つのオブジェクトにまとめることで、
コントローラーのスリム化と関心の分離を実現します。

```ruby

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

  def save
    return false unless valid?

    ActiveRecord::Base.transaction do
      user = User.create!(name: name, email: email, password: password)
      user.create_profile!(bio: bio, website: website)
      UserMailer.welcome(user).deliver_later
    end
    true
  rescue ActiveRecord::RecordInvalid => e
    errors.add(:base, e.message)
    false
  end
end

```

### コントローラーでの使用例

```ruby

class RegistrationsController < ApplicationController
  def new
    @form = UserRegistrationForm.new
  end

  def create
    @form = UserRegistrationForm.new(registration_params)

    if @form.save
      redirect_to root_path, notice: "登録が完了しました"
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def registration_params
    params.require(:user_registration_form).permit(
      :name, :email, :password, :bio, :website, :terms_accepted
    )
  end
end

```

### フォームオブジェクト設計の指針

1. ActiveModel::ModelとActiveModel::Attributesをベースにします。Railsのフォームヘルパーとの互換性を確保します
2. saveメソッドを公開APIとします。バリデーション、永続化、通知の流れを1メソッドに集約します
3. トランザクションで原子性を保証します。複数モデルの操作は必ずトランザクション内で行います
4. エラーはerrorsオブジェクトに集約します。フォームヘルパーがエラー表示に使うためです
5. 永続化の詳細を隠蔽します。コントローラーはフォームオブジェクトのインターフェースだけを知ればよいです

## Dirty Trackingの活用

### 基本的な使い方

`ActiveModel::Dirty` をインクルードすると、属性の変更を追跡できます。

```ruby

class UserProfile
  include ActiveModel::Model
  include ActiveModel::Attributes
  include ActiveModel::Dirty

  attribute :name, :string
  attribute :email, :string

  def save
    changes_applied  # 変更を確定してprevious_changesに移動します
    true
  end
end

profile = UserProfile.new(name: "佐藤")
profile.save  # 初期状態を確定します

profile.name = "鈴木"
profile.changed?          # => true
profile.changed           # => ["name"]
profile.name_changed?     # => true
profile.name_was          # => "佐藤"
profile.name_change       # => ["佐藤", "鈴木"]
profile.changes           # => {"name" => ["佐藤", "鈴木"]}

```

### 主要メソッド一覧

| メソッド | 説明
| --------- | ------
| `changed?` | いずれかの属性が変更されたかを返します
| `changed` | 変更された属性名の配列を返します
| `changes` | `{ 属性名 => [変更前, 変更後] }` のハッシュを返します
| `<attr>_changed?` | 特定の属性が変更されたかを返します
| `<attr>_was` | 変更前の値を返します
| `<attr>_change` | `[変更前, 変更後]` の配列を返します
| `changes_applied` | 変更を確定します（previous_changesに移動します）
| `previous_changes` | 直前に確定された変更を返します
| `restore_attributes` | 変更を元に戻します

### 実務での活用パターン

#### 変更監査ログ

```ruby

class AuditableForm
  include ActiveModel::Model
  include ActiveModel::Attributes
  include ActiveModel::Dirty

  attribute :status, :string
  attribute :assignee, :string

  def save
    if valid?
      log_changes if changed?
      changes_applied
      true
    else
      false
    end
  end

  private

  def log_changes
    changes.each do |attr, (old_val, new_val)|
      Rails.logger.info "[監査] #{attr}: #{old_val.inspect} → #{new_val.inspect}"
    end
  end
end

```

#### 差分更新API

```ruby

def update_external_service
  return unless changed?

  # 変更があった属性のみをAPI送信します（帯域の節約になります）
  payload = changes.transform_values(&:last)
  ExternalApi.patch("/users/#{id}", payload)
  changes_applied
end

```

## シリアライゼーション

`ActiveModel::Serializers::JSON` をインクルードすると、JSONシリアライゼーションが使えるようになります。

```ruby

class ApiResponse
  include ActiveModel::Model
  include ActiveModel::Attributes
  include ActiveModel::Serializers::JSON

  attribute :id, :integer
  attribute :title, :string
  attribute :score, :float
end

response = ApiResponse.new(id: 1, title: "テスト", score: 4.5)

# ハッシュ化

response.serializable_hash

# => {"id" => 1, "title" => "テスト", "score" => 4.5}

# JSON文字列化

response.to_json

# => '{"id":1,"title":"テスト","score":4.5}'

# フィールド限定

response.as_json(only: [:id, :title])

# => {"id" => 1, "title" => "テスト"}

# JSONからの復元

restored = ApiResponse.new
restored.from_json('{"id": 2, "title": "復元"}')
restored.id     # => 2
restored.title  # => "復元"

```

## 実行方法

```bash

# テストの実行

bundle exec rspec 17_activemodel_attributes/activemodel_attributes_spec.rb

# 個別のメソッドを試します

ruby -r ./17_activemodel_attributes/activemodel_attributes -e "pp ActiveModelAttributes.demonstrate_basic_attributes"
ruby -r ./17_activemodel_attributes/activemodel_attributes -e "pp ActiveModelAttributes.demonstrate_type_casting"
ruby -r ./17_activemodel_attributes/activemodel_attributes -e "pp ActiveModelAttributes.demonstrate_custom_types"
ruby -r ./17_activemodel_attributes/activemodel_attributes -e "pp ActiveModelAttributes.demonstrate_dirty_tracking"

```
