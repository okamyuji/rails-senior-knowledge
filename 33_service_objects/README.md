# サービスオブジェクト設計パターン

## サービスオブジェクトの理解が重要な理由

Railsアプリケーションが成長すると、コントローラやモデルに複雑なビジネスロジックが集積し、いわゆる「Fat Controller」「Fat
Model」問題が発生します。サービスオブジェクトは、これらのビジネスロジックを単一責任のクラスに抽出する設計パターンです。

シニアエンジニアがサービスオブジェクトを深く理解すべき理由は以下の通りです。

- テスタビリティの向上につながります。入力と出力が明確で、依存関係を注入できるため、ユニットテストが書きやすくなります
- コードの再利用が可能になります。コントローラ、バックグラウンドジョブ、Rakeタスクなど異なるエントリーポイントから同じビジネスロジックを呼び出せます
- 責任の明確化が実現します。1サービス = 1ビジネス操作という原則により、変更の影響範囲が限定されます
- チーム開発の効率化に寄与します。ビジネスロジックの所在が明確になり、新しいメンバーがコードを理解しやすくなります

## サービスオブジェクト設計原則

### 基本原則

サービスオブジェクトの設計は以下の原則に従います。

```ruby

class UserRegistrationService
  # 1. クラスメソッド.callで呼び出し可能です
  def self.call(...)
    new(...).call
  end

  # 2. コンストラクタで入力を受け取ります
  def initialize(email:, password:, name:)
    @email = email
    @password = password
    @name = name
  end

  # 3. 単一のpublicメソッドcallで実行します
  def call
    validate_inputs
    create_user
    send_welcome_email
    Result.success(user)
  rescue ValidationError => e
    Result.failure(e.message, :validation)
  end

  private
  # 4. 内部ロジックはprivateメソッドに分割します
end

```

### 設計判断の基準

サービスオブジェクトを作成すべきかどうかの判断基準は以下の通りです。

| 状況 | サービスオブジェクトにすべきか
| ------ | --------------------------
| 単純なCRUD操作 | いいえ（モデルで十分です）
| 複数モデルにまたがる操作 | はい
| 外部APIとの連携 | はい
| 複雑なビジネスルール | はい
| トランザクション管理が必要 | はい
| コントローラとジョブで共有する処理 | はい
| モデルの単一属性の更新 | いいえ（モデルで十分です）

## Result Objectパターン

### 例外ではなくResultを使う理由

Rubyでは例外（Exception）をフロー制御に使うことが可能ですが、以下の理由からビジネスロジックのエラーにはResultオブジェクトを使うべきです。

```ruby

# 悪い例: 例外をフロー制御に使っています

class BadRegistrationService
  def call
    validate!          # ValidationErrorをraise
    create_user!       # ActiveRecord::RecordInvalidをraise
    send_email!        # DeliveryErrorをraise
    user
  rescue ValidationError => e
    # 呼び出し側がrescueしないとアプリがクラッシュします
    # どんな例外が飛ぶか、コードを読まないとわかりません
  end
end

# 良い例: Resultオブジェクトで明示的に返します

class GoodRegistrationService
  def call
    return failure("不正な入力", :validation) unless valid?
    return failure("メール重複", :conflict) if email_exists?

    user = create_user
    send_email(user)
    success(user)
  end
end

```

### Resultオブジェクトの実装

```ruby

class Result
  attr_reader :value, :error, :error_type

  def self.success(value = nil)
    new(success: true, value: value)
  end

  def self.failure(error, error_type = :unknown)
    new(success: false, error: error, error_type: error_type)
  end

  def success? = @success
  def failure? = !@success

  # モナディック連鎖: 成功時のみ次のステップを実行します
  def and_then
    return self if failure?
    yield(value)
  end

  # パターンマッチ対応（Ruby 3.0+）
  def deconstruct_keys(_keys)
    success? ? { success: true, value: value } : { success: false, error: error, error_type: error_type }
  end
end

```

### パターンマッチとの組み合わせ（Ruby 3.0+）

```ruby

result = UserRegistrationService.call(email: "user@example.com", password: "secure", name: "太郎")

case result
in { success: true, value: { id: Integer => id } }
  redirect_to user_path(id), notice: "登録完了"
in { success: false, error_type: :validation, error: String => msg }
  render :new, alert: msg, status: :unprocessable_entity
in { success: false, error_type: :conflict }
  render :new, alert: "このメールアドレスは既に登録されています", status: :conflict
in { success: false, error_type: :system }
  # システムエラーは運用チームに通知します
  Rails.error.report(result.error)
  render :error, status: :internal_server_error
end

```

## Fat Model / Fat Controllerの回避

### Fat Controllerの典型例

```ruby

# 悪い例: コントローラにビジネスロジックが集積しています

class UsersController < ApplicationController
  def create
    @user = User.new(user_params)

    if User.exists?(email: @user.email)
      flash[:alert] = "メールアドレスは既に登録されています"
      return render :new, status: :unprocessable_entity
    end

    unless @user.email.match?(/\A[\w+\-.]+@[a-z\d\-.]+\.[a-z]+\z/i)
      flash[:alert] = "メールアドレスの形式が不正です"
      return render :new, status: :unprocessable_entity
    end

    ActiveRecord::Base.transaction do
      @user.save!
      @user.create_profile!(default_avatar: true)
      UserMailer.welcome(@user).deliver_later
      AnalyticsService.track("user.registered", user_id: @user.id)
    end

    redirect_to @user, notice: "登録完了"
  rescue ActiveRecord::RecordInvalid => e
    flash[:alert] = e.message
    render :new, status: :unprocessable_entity
  end
end

```

### サービスオブジェクトでリファクタリングした例

```ruby

# 良い例: コントローラはHTTPの関心事のみを扱います

class UsersController < ApplicationController
  def create
    result = UserRegistrationService.call(**user_params.to_h.symbolize_keys)

    case result
    in { success: true, value: user }
      redirect_to user_path(user[:id]), notice: "登録完了"
    in { success: false, error_type: :validation, error: String => msg }
      flash[:alert] = msg
      render :new, status: :unprocessable_entity
    in { success: false, error_type: :conflict }
      flash[:alert] = "メールアドレスは既に登録されています"
      render :new, status: :conflict
    end
  end
end

# サービスオブジェクト: ビジネスロジックを集約します

class UserRegistrationService < ApplicationService
  def initialize(email:, password:, name:)
    @email = email
    @password = password
    @name = name
  end

  def call
    return failure("不正なメールアドレス", :validation) unless valid_email?
    return failure("既に登録済み", :conflict) if email_exists?

    user = nil
    ActiveRecord::Base.transaction do
      user = User.create!(email: @email, password: @password, name: @name)
      user.create_profile!(default_avatar: true)
    end

    # 副作用（トランザクション外で実行します）
    UserMailer.welcome(user).deliver_later
    AnalyticsService.track("user.registered", user_id: user.id)

    success(user)
  rescue ActiveRecord::RecordInvalid => e
    failure(e.message, :validation)
  end
end

```

### Fat Modelの回避

```ruby

# 悪い例: モデルにビジネスロジックが肥大化しています

class User < ApplicationRecord
  def register!
    # モデルに登録ロジック、メール送信、分析追跡が混在しています
  end

  def change_plan!(new_plan)
    # 課金処理、プラン変更、通知がモデルに含まれています
  end

  def deactivate!
    # アカウント無効化、データ削除、退会処理がモデルに含まれています
  end
end

# 良い例: モデルはデータとバリデーションのみを扱います

class User < ApplicationRecord
  validates :email, presence: true, uniqueness: true
  validates :name, presence: true

  has_one :profile
  has_many :subscriptions
end

# ビジネスロジックは個別のサービスに分離します

# UserRegistrationService

# PlanChangeService

# AccountDeactivationService

```

## コンポーザブルサービス（パイプラインパターン）

複数のサービスを連鎖させて一連のビジネスプロセスを構築します。

```ruby

class RegistrationPipeline < ApplicationService
  def call
    NormalizeEmailService.call(email: @email)
      .and_then { |email| CheckEmailUniquenessService.call(email: email) }
      .and_then { |email| CreateUserService.call(email: email, name: @name) }
      .and_then { |user| SendWelcomeEmailService.call(user: user) }
  end
end

```

途中のいずれかのステップで`Result.failure`が返された場合、後続のステップは自動的にスキップされます。これはモナド（Maybe/Either）
パターンのRuby実装であり、エラーハンドリングのボイラープレートを大幅に削減します。

## エラーカテゴリ分類

サービスオブジェクトでは、エラーを明確に分類することが重要です。

### ビジネスエラー（期待されるエラー）

ユーザーの操作や入力に起因するエラーです。`Result.failure`で返します。

```ruby

# バリデーションエラー → 422 Unprocessable Entity

Result.failure("メールアドレスの形式が不正です", :validation)

# 権限エラー → 403 Forbidden

Result.failure("この操作は管理者のみ実行できます", :authorization)

# リソース競合 → 409 Conflict

Result.failure("このメールアドレスは既に登録されています", :conflict)

# ビジネスルール違反 → 422

Result.failure("残高不足です", :insufficient_funds)

```

### システムエラー（予期しないエラー）

インフラやシステムに起因するエラーです。例外として`raise`し、運用チームに通知します。

```ruby

def call
  result = external_api_call
  success(result)
rescue Timeout::Error => e
  # システムエラーはログ出力 + エラーレポーターに通知します
  Rails.error.report(e, severity: :error)
  failure("外部サービスに一時的な障害が発生しています", :system)
rescue StandardError => e
  Rails.error.report(e, severity: :error)
  failure("予期しないエラーが発生しました", :system)
end

```

## 依存関係注入によるテスタビリティ

サービスオブジェクトの最大の利点の1つは、依存関係を注入できることです。

```ruby

class NotificationService < ApplicationService
  # デフォルト引数で本番用の依存関係を設定します
  # テスト時にモックを注入できます
  def initialize(user:, message:, notifier: PushNotifier.new, logger: Rails.logger)
    @user = user
    @message = message
    @notifier = notifier
    @logger = logger
  end

  def call
    @notifier.send(user: @user, message: @message)
    @logger.info("Notification sent to user #{@user.id}")
    success
  end
end

# テスト

RSpec.describe NotificationService do
  let(:mock_notifier) { instance_double(PushNotifier) }

  it "通知を送信すること" do
    allow(mock_notifier).to receive(:send).and_return(true)

    result = described_class.call(
      user: user,
      message: "テスト",
      notifier: mock_notifier
    )

    expect(result.success?).to be true
    expect(mock_notifier).to have_received(:send).once
  end
end

```

## アンチパターン

### 1. God Service Object

1つのサービスに複数の責任を詰め込むパターンです。Fat Model/Controllerの問題をFat Serviceに移動しただけになります。

```ruby

# 悪い例

class UserManagementService
  def call(action, **params)
    case action
    when :register then register(params)
    when :update then update(params)
    when :delete then delete(params)
    when :notify then notify(params)
    end
  end
end

# 良い例: 各操作を独立したサービスに分割します

# UserRegistrationService

# UserUpdateService

# UserDeletionService

# UserNotificationService

```

### 2. 単なるメソッド抽出

モデルの単純な操作をサービスで薄く包んだだけのパターンです。

```ruby

# 悪い例: これはモデルのメソッドで十分です

class UpdateUserNameService
  def call(user:, name:)
    user.update!(name: name)
  end
end

# モデルに書くべきです

user.update!(name: "新しい名前")

```

### 3. 過度な抽象化

DSLやメタプログラミングを駆使した複雑な基底クラスを作り、新しいメンバーが理解できないパターンです。

```ruby

# 悪い例: 過度に抽象化された基底クラス

class AbstractService
  include Transactional
  include Loggable
  include Retryable
  include Cacheable
  extend DSLMethods

  step :validate
  step :authorize
  step :execute
  step :notify

  around_step :execute, :with_transaction
  after_step :execute, :clear_cache
  # ... 基底クラスの理解なしにサービスを書けません
end

# 良い例: YAGNIに従いシンプルにします

class ApplicationService
  def self.call(...)
    new(...).call
  end

  private

  def success(value = nil) = Result.success(value)
  def failure(error, type = :unknown) = Result.failure(error, type)
end

```

## 実務での活用ガイドライン

### ディレクトリ構成

```text

app/
  services/
    application_service.rb          # 基底クラス
    result.rb                       # Resultオブジェクト
    users/
      registration_service.rb       # ユーザー登録
      profile_update_service.rb     # プロフィール更新
    payments/
      processing_service.rb         # 決済処理
      refund_service.rb             # 返金処理
    orders/
      create_service.rb             # 注文作成
      cancel_service.rb             # 注文キャンセル

```

### 命名規則

- クラス名は`動詞 + 名詞 + Service`の形式にします（例: `UserRegistrationService`）
- ファイル名はスネークケースにします（例: `user_registration_service.rb`）
- 名前空間でドメインを表現します（例: `Users::RegistrationService`）

### コントローラからの呼び出しパターン

```ruby

class OrdersController < ApplicationController
  def create
    result = Orders::CreateService.call(
      user: current_user,
      items: order_params[:items],
      payment_method: order_params[:payment_method]
    )

    if result.success?
      redirect_to order_path(result.value), notice: "注文が完了しました"
    else
      flash.now[:alert] = result.error
      render :new, status: error_status(result.error_type)
    end
  end

  private

  def error_status(error_type)
    case error_type
    when :validation then :unprocessable_entity
    when :authorization then :forbidden
    when :conflict then :conflict
    else :internal_server_error
    end
  end
end

```

## 実行方法

```bash

# テストの実行

bundle exec rspec 33_service_objects/service_objects_spec.rb

# 個別のメソッドを試す

ruby -r ./33_service_objects/service_objects -e "pp ServiceObjects::BaseService.demonstrate_basic_service"
ruby -r ./33_service_objects/service_objects -e "pp ServiceObjects::InputValidation.demonstrate_validation"
ruby -r ./33_service_objects/service_objects -e "pp ServiceObjects::ComposableServices.demonstrate_pipeline"
ruby -r ./33_service_objects/service_objects -e "pp ServiceObjects::TransactionHandling.demonstrate_transaction"

```
