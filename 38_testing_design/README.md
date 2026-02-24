# テスト設計パターン（Testing Design Patterns）

## 概要

テスト設計はソフトウェア品質を支える基盤であり、シニアエンジニアにはテストピラミッドの理解、適切なテストダブルの選択、テストスイートの高速化戦略など、高度な設計判断が求められます。このモジュールでは、Rails/RSpecエコシステムにおけるテスト設計の主要パターンを網羅的に解説します。

## テストピラミッド

### ピラミッドの構造

```text

         /\
        /  \         System（E2E）テスト: 10%
       /    \        ブラウザ操作、全スタック結合
      /------\
     /        \      Integrationテスト: 20%
    /          \     コントローラー、API、サービス間連携
   /------------\
  /              \   Unitテスト: 70%
 /________________\  モデル、PORO、個別メソッド

```

### 各層の特性

| 層 | 比率 | 速度 | コスト | 対象
| --- | --- | --- | --- | ---
| Unit | 70% | 高速 | 低 | 単一クラス・メソッドの振る舞い
| Integration | 20% | 中速 | 中 | 複数コンポーネントの連携
| System | 10% | 低速 | 高 | ユーザー視点のE2E動作

### アンチパターン

- アイスクリームコーン型では、Systemテストに偏重し、実行時間が長大化してフレーキーテストが増加します
- アワーグラス型では、UnitとSystemのみでIntegrationが欠落し、コンポーネント間の不整合を見逃します

### Railsでのテスト種別対応

```ruby

# Unitテスト（モデルスペック）

RSpec.describe User, type: :model do
  it { is_expected.to validate_presence_of(:name) }
end

# Integrationテスト（リクエストスペック）

RSpec.describe "Users API", type: :request do
  it "ユーザー一覧を返す" do
    get "/api/v1/users"
    expect(response).to have_http_status(:ok)
  end
end

# Systemテスト

RSpec.describe "ログインフロー", type: :system do
  it "正しい資格情報でログインできる" do
    visit login_path
    fill_in "メールアドレス", with: "user@example.com"
    click_button "ログイン"
    expect(page).to have_content("ようこそ")
  end
end

```

## FixturesとFactoriesの比較

### 比較表

| 観点 | Fixtures | Factories (factory_bot)
| --- | --- | ---
| データ定義 | YAMLファイル | Ruby DSL
| ロード方式 | テスト開始前に一括ロード | テストごとに動的生成
| 速度 | 高速（トランザクション内） | 中速（テストごとにINSERT）
| 柔軟性 | 低い | 高い（trait, sequence, association）
| 可読性 | テストコード内で前提条件が見えにくい | テスト内でデータの前提が明確
| Rails標準 | 標準搭載 | gem追加が必要

### Fixturesの例

```yaml

# test/fixtures/users.yml

alice:
  name: Alice
  email: alice@example.com
  role: admin

bob:
  name: Bob
  email: bob@example.com
  role: member

```

### factory_botの例

```ruby

# spec/factories/users.rb

FactoryBot.define do
  factory :user do
    sequence(:name) { |n| "ユーザー#{n}" }
    sequence(:email) { |n| "user#{n}@example.com" }
    role { :member }

    trait :admin do
      role { :admin }
      admin_since { Time.current }
    end

    trait :with_posts do
      after(:create) do |user|
        create_list(:post, 3, author: user)
      end
    end
  end
end

# テストでの使用

let(:user)  { create(:user) }
let(:admin) { create(:user, :admin) }
let(:user_with_posts) { create(:user, :with_posts) }

```

### 使い分けの指針

- Fixturesが適切な場合は、マスターデータ（都道府県、ステータスコードなど）や変更されない参照データです
- Factoriesが適切な場合は、テストごとに異なるデータが必要な場合やエッジケースの検証です
- 大規模プロジェクトでは、両者を併用する戦略が有効です（マスターデータはFixtures、テスト固有データはFactories）

## テスト高速化戦略

### ボトルネックの特定

```bash

# RSpec標準のプロファイリング（最も遅い10件を表示します）

bundle exec rspec --profile 10

# test-prof gemによる詳細分析

FPROF=1 bundle exec rspec     # FactoryProf: ファクトリの使用状況分析
EVENT_PROF=sql.active_record bundle exec rspec  # SQLクエリの分析

```

### 高速化テクニック

#### 1. build_stubbedの活用

```ruby

# DB書き込みなし（最速）

user = build_stubbed(:user)

# DB書き込みあり（遅い）

user = create(:user)

# メモリ上のみ（永続化なし）

user = build(:user)

```

#### 2. let_it_be（test-prof gem）

```ruby

# before(:all)ベースの安全なlet

# describeブロック内で一度だけ作成し、各テスト後にロールバックします

describe "ユーザー関連テスト" do
  let_it_be(:user) { create(:user) }       # 一度だけINSERT
  let(:fresh_user) { create(:user) }        # 毎テストINSERT

  it "テスト1" do
    # userは共有されます（高速）
  end

  it "テスト2" do
    # 同じuserを再利用します（高速）
  end
end

```

#### 3. before(:all)とbefore(:each)の比較

| フック | 実行タイミング | 分離性 | パフォーマンス
| --- | --- | --- | ---
| `before(:each)` | 各テスト前 | 高い | 低い
| `before(:all)` | ブロック全体で一度 | 低い（データ共有） | 高い
| `let_it_be` | ブロック全体で一度 + ロールバック | 中程度 | 高い

#### 4. 不要な関連オブジェクトの回避

```ruby

# 悪い例: 不要な関連を大量に生成します

factory :order do
  user          # User + Profile + Addressを連鎖生成
  items { create_list(:item, 5) }  # 5つのItem + Product + Category
end

# 良い例: 必要最小限の関連のみを定義します

factory :order do
  association :user, strategy: :build_stubbed
  # itemsは必要なテストでのみtraitで追加します
  trait :with_items do
    after(:create) { |order| create_list(:item, 2, order: order) }
  end
end

```

## 並列テスト

### Rails標準（Minitest）

```ruby

# test/test_helper.rb

class ActiveSupport::TestCase
  parallelize(workers: :number_of_processors)

  # プロセス並列化時のフック
  parallelize_setup do |worker|
    # ワーカーごとの初期化処理
    ActiveStorage::Blob.service.root = "#{ActiveStorage::Blob.service.root}-#{worker}"
  end
end

```

### RSpec（parallel_tests gem）

```bash

# インストール

gem install parallel_tests

# DBの準備

bundle exec rake parallel:create
bundle exec rake parallel:prepare

# テスト実行

bundle exec parallel_rspec spec/

# 実行時間に基づく最適分割

bundle exec parallel_rspec spec/ --group-by runtime

```

### database.ymlの設定

```yaml

test:
  adapter: postgresql
  database: myapp_test<%= ENV['TEST_ENV_NUMBER'] %>
  # ワーカー0: myapp_test, ワーカー1: myapp_test2, ...

```

### CIでの並列化

```yaml

# GitHub Actionsの例

jobs:
  test:
    strategy:
      matrix:
        ci_node_total: [4]
        ci_node_index: [0, 1, 2, 3]
    steps:

      - run: |

          bundle exec parallel_rspec spec/ \
            --group-by runtime \
            --only-group ${{ matrix.ci_node_index }}

```

## テストダブルの使い分け

### 4種類のテストダブル

```text

┌──────────────────────────────────────────────────────────┐
│  テストダブル（Test Double）                                │
├──────────┬──────────┬──────────┬──────────────────────────┤
│  Stub    │  Mock    │  Spy     │  Fake                    │
│ 固定値返却 │ 呼出検証  │ 履歴記録  │ 簡易実装                   │
└──────────┴──────────┴──────────┴──────────────────────────┘

```

### Stub（スタブ）

固定値を返すだけのダブルです。戻り値のみが重要な場合に使います。

```ruby

# 外部APIの応答をスタブ化します

allow(PaymentGateway).to receive(:charge).and_return(
  status: :success, transaction_id: "txn_001"
)

# HTTPリクエストのスタブ（webmock）

stub_request(:get, "https://api.example.com/users/1")
  .to_return(status: 200, body: { name: "Alice" }.to_json)

```

### Mock（モック）

メソッド呼び出しの期待を設定し、テスト終了時に検証します。

```ruby

# 通知が送信されることを検証します

expect(NotificationService).to receive(:send_email)
  .with(to: "user@example.com", subject: "注文確認")
  .once

OrderService.new.complete_order(order)

# テスト終了時に自動検証されます

```

### Spy（スパイ）

呼び出し履歴を記録し、事後的に検証します。Arrange-Act-Assertパターンに適合します。

```ruby

# Arrange

logger = spy("Logger")
service = SomeService.new(logger: logger)

# Act

service.execute

# Assert（事後検証）

expect(logger).to have_received(:info).with("処理開始")
expect(logger).to have_received(:info).with("処理完了")

```

### Fake（フェイク）

簡易的な実装を持つダブルです。インメモリDB、インメモリキャッシュなどに使います。

```ruby

# インメモリキャッシュのFake

class FakeCache
  def initialize = @store = {}
  def read(key) = @store[key]
  def write(key, value, **) = @store[key] = value
  def delete(key) = @store.delete(key)
end

# テストで注入します

service = CachingService.new(cache: FakeCache.new)

```

### 使い分けガイドライン

| ダブル | 目的 | 使う場面 | 避ける場面
| --- | --- | --- | ---
| Stub | 固定値を返します | 外部サービスの応答シミュレート | 呼び出し自体の検証が必要な場合
| Mock | 呼び出しを検証します | 副作用の発生確認 | 実装詳細に過度に依存する場合
| Spy | 履歴を記録・事後検証します | AAAパターンでの検証 | 単純なケース
| Fake | 簡易実装を提供します | インフラ依存の回避 | Stubで十分な場合

### verified doubles（検証付きダブル）の推奨

```ruby

# 推奨: instance_double（存在しないメソッドをstubするとエラーになります）

user = instance_double(User, name: "Alice")

# 推奨: class_double（クラスメソッドの検証付きダブル）

mailer = class_double(UserMailer, welcome: true)

# 非推奨: 検証なしのdouble（タイポを見逃します）

user = double("User", nmae: "Alice")  # typoに気づけません

```

## Database Cleaner戦略

### 3つの戦略

| 戦略 | 仕組み | 速度 | 複数接続対応 | 用途
| --- | --- | --- | --- | ---
| Transaction | BEGIN → ROLLBACK | 最速 | 不可 | Unit/Integrationテスト
| Truncation | TRUNCATE TABLE | 中速 | 可能 | Systemテスト
| Deletion | DELETE FROM | 低速 | 可能 | 外部キー制約が厳しい場合

### 推奨構成

```ruby

# spec/support/database_cleaner.rb

RSpec.configure do |config|
  config.use_transactional_fixtures = false

  config.before(:suite) do
    DatabaseCleaner.clean_with(:truncation)
  end

  config.before(:each) do
    DatabaseCleaner.strategy = :transaction
  end

  config.before(:each, type: :system) do
    DatabaseCleaner.strategy = :truncation
  end

  config.before(:each) { DatabaseCleaner.start }
  config.after(:each)  { DatabaseCleaner.clean }
end

```

## コントラクトテスト

マイクロサービス環境では、サービス間のAPI契約が守られていることを自動検証します。

```ruby

# APIレスポンスのスキーマ検証

RSpec.describe "Users API Contract" do
  it "GET /api/v1/users/:idのレスポンスがスキーマに適合する" do
    get "/api/v1/users/1"

    expect(response).to match_json_schema("user")
    # json_matchers gemやjson-schema gemを使用します
  end
end

```

### Consumer-Driven Contract Testing（Pact）

```ruby

# 消費者側でコントラクトを定義します

Pact.service_consumer "Frontend" do
  has_pact_with "UserService" do
    mock_service :user_service do
      port 1234
    end
  end
end

```

## Property-Based Testing

具体的な入力値ではなく、「満たすべき性質」を定義してランダム入力で検証します。

```ruby

# 従来のテスト

it "ソートが正しい" do
  expect([3,1,2].sort).to eq([1,2,3])
end

# Property-Based Testing

it "ソートは要素数を保存する" do
  property_of { array(integer) }.check do |arr|
    expect(arr.sort.length).to eq(arr.length)
  end
end

```

## 実行方法

```bash

# テストの実行

bundle exec rspec 38_testing_design/testing_design_spec.rb

# 特定のテストのみ実行

bundle exec rspec 38_testing_design/testing_design_spec.rb -e "テストダブル"

# プロファイリング付き実行

bundle exec rspec 38_testing_design/testing_design_spec.rb --profile 5

```

## 参考資料

- [RSpec Documentation](https://rspec.info/documentation/)
- [factory_bot Getting
  Started](https://github.com/thoughtbot/factory_bot/blob/main/GETTING_STARTED.md)
- [test-prof: Ruby Tests Profiling Toolbox](https://test-prof.evilmartians.io/)
- [Rails Testing Guide](https://guides.rubyonrails.org/testing.html)
- [Pact - Contract Testing](https://docs.pact.io/)
- [Martin Fowler - Test Double](https://martinfowler.com/bliki/TestDouble.html)
