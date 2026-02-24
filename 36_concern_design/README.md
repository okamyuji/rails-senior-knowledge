# ActiveSupport::Concern設計原則

## Concernの設計原則の理解が重要な理由

ActiveSupport::ConcernはRailsで最も多用されるパターンの一つですが、同時に最も誤用されやすいパターンでもあります。Concernを正しく設計できるかどうかは、Railsアプリケーションの保守性を大きく左右します。

シニアエンジニアがConcernの設計原則を深く理解すべき理由は以下の通りです。

- モデルの肥大化を防止するためです。「Fat Model」問題の解決策としてConcernが使われますが、設計が悪いと「Fat
  Concern」という新たな問題を生みます
- コードの再利用性を向上させるためです。良いConcernは複数のプロジェクトを横断して再利用できる資産になります
- チーム開発の効率化に寄与するためです。Concernの設計基準が明確であれば、コードレビューの品質が向上します
-
  代替パターンの判断ができるようになるためです。Concernが最適でない場面を見極め、サービスオブジェクトやコンポジションなど適切なパターンを選択できるようになります

## Concernの基本構造

### ActiveSupport::Concernが提供する3つのブロック

```ruby

module Trackable
  extend ActiveSupport::Concern

  # 1. includedブロック: インクルード先クラスのコンテキストで評価されます
  included do
    class_attribute :tracking_enabled, default: true
    # scope, validates, before_actionなども定義できます
  end

  # 2. class_methodsブロック: クラスメソッドを定義します
  class_methods do
    def disable_tracking
      self.tracking_enabled = false
    end
  end

  # 3. 通常のインスタンスメソッド
  def track_event(event_name)
    return unless self.class.tracking_enabled
    { event: event_name, at: Time.current }
  end
end

```

### Concernが解決する問題としての依存関係の自動解決

素のModuleで`included`コールバックを使うと、モジュール間の依存関係が深くなった際に問題が発生します。

```ruby

# 問題のあるコード: 素のModule

module ModuleB
  def self.included(base)
    base.class_eval { attr_accessor :flag_b }  # クラスコンテキストでの設定
  end
end

module ModuleA
  include ModuleB  # ここで ModuleB.included(ModuleA) が呼ばれます

  def self.included(base)
    base.class_eval { attr_accessor :flag_a }
  end
end

class MyClass
  include ModuleA
  # ModuleBのincludedはMyClassに対して呼ばれません
  # ModuleAに対して呼ばれてしまいます
end

```

Concernはこの問題を「遅延実行」で解決します。

```ruby

# 正しいコード: Concern

module ConcernB
  extend ActiveSupport::Concern
  included do
    class_attribute :flag_b, default: true
  end
end

module ConcernA
  extend ActiveSupport::Concern
  include ConcernB  # 依存関係を宣言します（この時点ではincludedは実行されません）

  included do
    class_attribute :flag_a, default: true
  end
end

class MyClass
  include ConcernA
  # ConcernBのincludedもMyClassのコンテキストで正しく実行されます
end

```

## 良いConcernと悪いConcern

### 良いConcernの特徴

| 特徴 | 説明 | 例
| ------ | ------ | -----
| 名前が振る舞いを表します | `-able`、`-ible`接尾辞が自然です | Trackable, Searchable, Sluggable
| 単一責任を持ちます | 一つの関心事だけを扱います | Publishable（公開状態の管理のみ）
| クラスに依存しません | どのクラスにも適用できます | email属性に依存しません
| 設定が可能です | DSLでカスタマイズできます | `paginates_per 25`
| テストが可能です | shared_examplesで独立テストできます | `it_behaves_like "searchable"`

### 良いConcernの実例

```ruby

# Sluggable: URLフレンドリーなスラグを自動生成します

module Sluggable
  extend ActiveSupport::Concern

  included do
    class_attribute :slug_source, default: :name
    before_validation :generate_slug, if: :slug_source_changed?
  end

  class_methods do
    def sluggable(source_attribute)
      self.slug_source = source_attribute
    end

    def find_by_slug!(slug)
      find_by!(slug: slug)
    end
  end

  def to_param
    slug || super
  end

  private

  def generate_slug
    source = send(self.class.slug_source)
    self.slug = source.to_s.parameterize if source.present?
  end
end

# 使用例

class Article < ApplicationRecord
  include Sluggable
  sluggable :title  # DSLでスラグソースを指定します
end

class Product < ApplicationRecord
  include Sluggable
  sluggable :name  # 別のクラスでも同じConcernを再利用します
end

```

### 悪いConcernのアンチパターン

#### 1. God Concern（何でも入れるゴミ箱）

```ruby

# 悪い例: 無関係な責任が一つのモジュールに混在しています

module UserMethods
  extend ActiveSupport::Concern

  # 認証ロジック
  def authenticate(password) ... end

  # 認可ロジック
  def authorize(action) ... end

  # メール送信
  def send_welcome_email ... end

  # フォーマット
  def full_name ... end

  # 通知
  def notify_admin ... end
end

# 改善: 責任ごとに分割します

module Authenticatable ... end
module Authorizable ... end
module Notifiable ... end

```

#### 2. 特定クラス依存のConcern

```ruby

# 悪い例: Userクラスの内部構造に依存しています

module AdminUtils
  extend ActiveSupport::Concern

  def admin?
    role == "admin"  # role属性の存在を前提としています
  end

  def admin_email_domain
    email.split("@").last  # email属性の存在を前提としています
  end
end

# → User以外のクラスには使えません。サービスオブジェクトにすべきです。

```

#### 3. 名前空間汚染

```ruby

# 悪い例: 大量のメソッドをインクルード先に追加しています

module CommonHelpers
  extend ActiveSupport::Concern

  # 30個以上のメソッドが定義されています
  def format_date ... end
  def format_currency ... end
  def format_phone ... end
  def truncate_text ... end
  # ... さらに26個のメソッド
end

# → ユーティリティクラスやヘルパーモジュールにすべきです

```

## 代替パターン（Concernを使わないべき場面）

### 判断フローチャート

```text

振る舞いを複数のクラスで共有したいか？
├── はい → その振る舞いは単一の責任か？
│   ├── はい → Concernが適切です
│   └── いいえ → サービスオブジェクトに分割します
└── いいえ → 特定のクラスに固有のロジックか？
    ├── はい → プライベートメソッドまたはサービスオブジェクトにします
    └── いいえ → CompositionまたはDelegationを使います

```

### 代替1: サービスオブジェクト

複雑なビジネスロジックや複数のモデルにまたがる処理には、サービスオブジェクトが適しています。

```ruby

# Concernではなくサービスオブジェクトにすべき例

class UserRegistrationService
  def initialize(params)
    @params = params
  end

  def call
    user = User.new(@params.slice(:name, :email))
    profile = Profile.new(@params.slice(:bio, :avatar))

    ActiveRecord::Base.transaction do
      user.save!
      profile.update!(user: user)
      WelcomeMailer.send_to(user).deliver_later
    end

    Result.new(success: true, user: user)
  rescue ActiveRecord::RecordInvalid => e
    Result.new(success: false, errors: e.record.errors)
  end
end

```

### 代替2: Delegation（委譲）

内部オブジェクトのメソッドを公開したい場合は、`delegate`や`Forwardable`を使います。

```ruby

class Order < ApplicationRecord
  # Concernではなくdelegateを使います
  belongs_to :customer
  delegate :name, :email, to: :customer, prefix: true
  # → order.customer_name, order.customer_email

  # Forwardableを使う場合
  extend Forwardable
  def_delegators :shipping_address, :city, :state, :zip
end

```

### 代替3: Composition（合成）

`has-a`関係のモデリングには、オブジェクト合成を使います。

```ruby

class ShippingCalculator
  def initialize(order)
    @order = order
  end

  def calculate
    base_cost + weight_surcharge + distance_surcharge
  end

  private

  def base_cost = 500
  def weight_surcharge = @order.total_weight * 10
  def distance_surcharge = @order.distance_km * 5
end

class Order < ApplicationRecord
  def shipping_cost
    ShippingCalculator.new(self).calculate
  end
end

```

## テスト戦略

### shared_examplesパターン

Concernのテストでは、RSpecの`shared_examples`を使ってコントラクトテストを定義します。

```ruby

# spec/support/shared_examples/publishable.rb

RSpec.shared_examples "publishableなオブジェクト" do
  it "デフォルトのステータスがdraftであること" do
    expect(subject.publish_status).to eq :draft
  end

  it "publish!で公開状態になること" do
    subject.publish!
    expect(subject.published?).to be true
  end

  it "unpublish!で下書き状態に戻ること" do
    subject.publish!
    subject.unpublish!
    expect(subject.published?).to be false
  end

  it "publish_statusesがクラスメソッドとして利用可能であること" do
    expect(subject.class.publish_statuses).to include(:draft, :published)
  end
end

# spec/models/article_spec.rb

RSpec.describe Article do
  subject { described_class.new }
  it_behaves_like "publishableなオブジェクト"
end

# spec/models/page_spec.rb

RSpec.describe Page do
  subject { described_class.new }
  it_behaves_like "publishableなオブジェクト"
end

```

### テストのベストプラクティス

1. Concern単体のテストとして、ダミークラスを作成してConcernの振る舞いをテストします
2. shared_examplesの定義として、Concernのコントラクト（契約）を明文化します
3. 各モデルでの`it_behaves_like`として、Concernをincludeする全モデルでコントラクトテストを実行します
4. モデル固有のテストとして、Concernの振る舞いがモデル固有のロジックと正しく連携することをテストします

```ruby

# ダミークラスによるConcern単体テスト

RSpec.describe Sluggable do
  let(:dummy_class) do
    Class.new do
      include Sluggable
      attr_accessor :title
      sluggable :title
      def self.name = "DummyModel"
    end
  end

  subject { dummy_class.new.tap { |d| d.title = "Hello World" } }

  it "タイトルからslugを生成すること" do
    expect(subject.generate_slug).to eq "hello-world"
  end
end

```

## class_methodsブロックとextend ClassMethodsの比較

### 旧スタイル（Rails 4.1以前）

```ruby

module Searchable
  extend ActiveSupport::Concern

  module ClassMethods
    def search(query)
      where("name LIKE ?", "%#{query}%")
    end
  end
end

```

### 新スタイル（Rails 4.2+、推奨）

```ruby

module Searchable
  extend ActiveSupport::Concern

  class_methods do
    def search(query)
      where("name LIKE ?", "%#{query}%")
    end
  end
end

```

両者は機能的に等価ですが、`class_methods`ブロックの方が意図が明確でボイラープレートが少なくなります。新規コードでは必ず`class_methods`ブロックを使うべきです。

## 設計判断のまとめ

| 場面 | 推奨パターン | 理由
| ------ | ------------ | ------
| 複数モデルで共有する振る舞い | Concern | Trackable, Searchableなど
| 複雑なビジネスロジック | サービスオブジェクト | 単一責任でテストが容易です
| 内部オブジェクトの公開 | Delegation | delegate, Forwardable
| has-a関係のモデリング | Composition | オブジェクト合成を使います
| 条件による振る舞い切替 | Strategyパターン | ポリモーフィズムを活用します
| ユーティリティメソッド | モジュール関数 | module_functionを使います

## 実行方法

```bash

# テストの実行

bundle exec rspec 36_concern_design/concern_design_spec.rb

# 個別のメソッドを試す

ruby -r ./36_concern_design/concern_design -e "pp ConcernDesign.demonstrate_concern_basics"
ruby -r ./36_concern_design/concern_design -e "pp ConcernDesign.demonstrate_good_concern_design"
ruby -r ./36_concern_design/concern_design -e "pp ConcernDesign.demonstrate_alternatives_to_concerns"

```
