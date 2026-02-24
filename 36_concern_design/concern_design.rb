# frozen_string_literal: true

require 'active_support/concern'
require 'active_support/core_ext/class/attribute'
require 'active_support/core_ext/object/blank'

# ActiveSupport::Concern の設計原則を解説するモジュール
#
# Concern は Rails の設計哲学の中核をなすパターンであり、
# モジュールベースの共有振る舞いをクリーンに実現するための仕組みである。
#
# しかし Concern の乱用は「God Concern」や「Concern ゴミ箱」を生み、
# かえってコードの可読性・保守性を低下させる。
#
# このモジュールでは、Concern の内部動作、良い設計と悪い設計の違い、
# そして Concern を使わないべき場面を実例を通じて学ぶ。
module ConcernDesign
  module_function

  # === ActiveSupport::Concern の基本構造 ===
  #
  # Concern は以下の3つのブロックを提供する:
  #   - included ブロック: インクルード先のクラスのコンテキストで評価されるコード
  #   - class_methods ブロック: クラスメソッドを定義するためのブロック
  #   - prepended ブロック: prepend 時にクラスのコンテキストで評価されるコード
  #
  # Concern を使うことで、モジュールの include 時に自動的に
  # クラスメソッドの追加やコールバックの登録などが行われる。
  #
  # 重要: Concern は「振る舞い」を名前付きで共有するための仕組みであり、
  # 単なるコード分割のためのツールではない。
  module Trackable
    extend ActiveSupport::Concern

    included do
      # インクルード先のクラスのコンテキストで実行される
      # ここで class_attribute や scope、コールバックなどを定義する
      class_attribute :tracking_enabled, default: true
    end

    class_methods do
      # クラスメソッドを定義する
      def disable_tracking
        self.tracking_enabled = false
      end

      def enable_tracking
        self.tracking_enabled = true
      end
    end

    # インスタンスメソッド
    def track_event(event_name)
      return nil unless self.class.tracking_enabled

      { event: event_name, tracked_by: self.class.name, at: Time.now.to_s }
    end

    def tracking_status
      self.class.tracking_enabled ? '有効' : '無効'
    end
  end

  def demonstrate_concern_basics
    # Concern をインクルードするクラスを動的に定義
    tracked_class = Class.new do
      include Trackable

      def self.name
        'TrackedModel'
      end
    end

    instance = tracked_class.new

    # トラッキングが有効な状態
    event = instance.track_event('ページ閲覧')

    # トラッキングを無効化
    tracked_class.disable_tracking
    nil_event = instance.track_event('ページ閲覧')

    # 復元
    tracked_class.enable_tracking

    {
      # included ブロックで設定された class_attribute のデフォルト値
      default_tracking: true,
      # インスタンスメソッドが正常に動作する
      event_tracked: !event.nil?,
      event_name: event&.dig(:event),
      # クラスメソッドでトラッキングを無効化できる
      disabled_event: nil_event,
      # トラッキング状態の確認
      status: instance.tracking_status,
      # ancestors にモジュールが含まれる
      includes_trackable: tracked_class.ancestors.include?(Trackable)
    }
  end

  # === Concern vs 素の Module: なぜ Concern が必要か ===
  #
  # 素の Module で included コールバックを使うと、
  # モジュールの依存関係が深くなった場合に問題が発生する。
  #
  # 例: Module A が Module B に依存し、Module B が included コールバックを持つ場合、
  # Class が Module A だけを include しても Module B の included が正しく動作しない。
  #
  # Concern はこの問題を「自動依存解決」で解決する。
  # Concern 同士で include すると、最終的なクラスに include された時点で
  # すべての included ブロックが正しい順序で実行される。

  # 素のモジュールでの問題を示す例
  module PlainModuleB
    def self.included(base)
      base.instance_variable_set(:@module_b_included, true)
    end

    def module_b_method
      'from B'
    end
  end

  module PlainModuleA
    include PlainModuleB

    def self.included(base)
      # PlainModuleB の included は base（最終クラス）に対して呼ばれない！
      # PlainModuleA に対して呼ばれてしまう
      base.instance_variable_set(:@module_a_included, true)
    end

    def module_a_method
      'from A'
    end
  end

  # Concern を使った場合: 依存関係が自動解決される
  module ConcernB
    extend ActiveSupport::Concern

    included do
      class_attribute :concern_b_flag, default: true
    end

    def concern_b_method
      'from ConcernB'
    end
  end

  module ConcernA
    extend ActiveSupport::Concern

    # Concern 同士の依存関係を宣言
    include ConcernB

    included do
      class_attribute :concern_a_flag, default: true
    end

    def concern_a_method
      'from ConcernA'
    end
  end

  def demonstrate_concern_vs_plain_module
    # 素のモジュールの場合
    plain_class = Class.new { include PlainModuleA }

    # Concern の場合
    concern_class = Class.new { include ConcernA }

    {
      # 素のモジュール: PlainModuleA の included は実行される
      plain_a_included: plain_class.instance_variable_get(:@module_a_included) == true,
      # 素のモジュール: PlainModuleB の included は最終クラスに対して実行されない！
      plain_b_included: plain_class.instance_variable_get(:@module_b_included) != true,
      # しかしメソッド自体は使える（include チェーンにより）
      plain_b_method_available: plain_class.new.respond_to?(:module_b_method),

      # Concern: ConcernA の included ブロックは正しく実行される
      concern_a_flag: concern_class.concern_a_flag,
      # Concern: ConcernB の included ブロックも自動的に実行される！
      concern_b_flag: concern_class.concern_b_flag,
      # Concern: メソッドも正しく使える
      concern_b_method: concern_class.new.concern_b_method,
      # ancestors に両方の Concern が含まれる
      ancestors_include_both: concern_class.ancestors.include?(ConcernA) &&
        concern_class.ancestors.include?(ConcernB)
    }
  end

  # === 良い Concern 設計: 単一責任・振る舞い中心 ===
  #
  # 良い Concern は以下の特徴を持つ:
  #   1. 名前が振る舞いを表す（-able, -ible 接尾辞）
  #   2. 単一の責任を持つ
  #   3. どのクラスにも適用可能（特定のクラスに依存しない）
  #   4. インクルード先の内部構造を知らない
  #   5. テストが独立して書ける
  #
  # 良い例: Sluggable, Searchable, Archivable, Publishable
  # 悪い例: UserConcern, ModelHelper, CommonMethods

  # 良い Concern の例: Sluggable
  module Sluggable
    extend ActiveSupport::Concern

    included do
      # slug のソースとなる属性名を設定可能にする
      class_attribute :slug_source, default: :name
    end

    class_methods do
      # slug のソース属性をカスタマイズする DSL
      def sluggable(source_attribute)
        self.slug_source = source_attribute
      end

      # slug でオブジェクトを検索するクラスメソッド
      def find_by_slug(slug)
        # 実際の ActiveRecord では where(slug: slug).first を使う
        { found: true, slug: slug }
      end
    end

    # slug を生成する
    def generate_slug
      source_value = respond_to?(self.class.slug_source) ? send(self.class.slug_source) : nil
      return nil if source_value.nil?

      source_value.to_s.downcase.gsub(/[^a-z0-9\p{Hiragana}\p{Katakana}\p{Han}]+/, '-').gsub(/\A-|-\z/, '')
    end

    # slug としてのパスを返す
    def to_slug_param
      generate_slug || object_id.to_s
    end
  end

  # 良い Concern の例: Archivable
  module Archivable
    extend ActiveSupport::Concern

    included do
      # アーカイブ状態を管理する属性
      class_attribute :archive_column, default: :archived_at
    end

    class_methods do
      def archivable(column: :archived_at)
        self.archive_column = column
      end
    end

    def archive!
      @archived_at = Time.now
      { archived: true, at: @archived_at }
    end

    def unarchive!
      @archived_at = nil
      { archived: false }
    end

    def archived?
      !@archived_at.nil?
    end
  end

  def demonstrate_good_concern_design
    # Sluggable をインクルードしたクラス
    article_class = Class.new do
      include Sluggable

      attr_accessor :title

      # slug のソースを title に設定
      sluggable :title

      def initialize(title)
        @title = title
      end

      def self.name
        'Article'
      end
    end

    # Archivable をインクルードしたクラス
    post_class = Class.new do
      include Archivable

      attr_accessor :title

      def initialize(title)
        @title = title
      end

      def self.name
        'Post'
      end
    end

    article = article_class.new('Ruby on Railsガイド 2024年版')
    post = post_class.new('お知らせ記事')

    # アーカイブ操作
    post.archive!
    archived_status = post.archived?
    post.unarchive!

    {
      # Sluggable: 日本語を含むタイトルからslugを生成
      slug: article.generate_slug,
      slug_param: article.to_slug_param,
      slug_source: article_class.slug_source,
      # Sluggable: クラスメソッドも使える
      find_result: article_class.find_by_slug('ruby-on-rails'),
      # Archivable: アーカイブ/復元が正しく動作
      was_archived: archived_status,
      now_archived: post.archived?,
      # 各 Concern が単一の責任を持つ
      article_concerns: article_class.ancestors.select { |a| a.is_a?(Module) && a.name&.include?('Sluggable') }.length,
      post_concerns: post_class.ancestors.select { |a| a.is_a?(Module) && a.name&.include?('Archivable') }.length
    }
  end

  # === 悪い Concern 設計: アンチパターン ===
  #
  # 悪い Concern の特徴:
  #   1. 名前が曖昧（UserMethods, CommonStuff）
  #   2. 複数の無関係な責任を持つ（God Concern）
  #   3. 特定のクラスの内部構造に依存する
  #   4. 名前空間を汚染する（大量のメソッドを追加）
  #   5. Concern 間で暗黙の依存関係がある
  #
  # 以下は「やってはいけない」例を教育目的で示す。

  # 悪い例1: God Concern（何でも詰め込む）
  module BadGodConcern
    extend ActiveSupport::Concern

    # 問題: 認証、認可、通知、監査、フォーマットなど
    # 無関係な責任が一つのモジュールに混在している

    def format_name
      'formatted'
    end

    def send_notification
      'notified'
    end

    def audit_log
      'logged'
    end

    def authenticate
      'authenticated'
    end

    def authorize
      'authorized'
    end
  end

  # 悪い例2: 特定クラスに依存する Concern
  module BadClassDependentConcern
    extend ActiveSupport::Concern

    # 問題: email, role, admin? など特定のクラスの属性に直接依存している
    # User クラス以外には使えない
    def admin_email_domain
      # email メソッドの存在を前提としている
      respond_to?(:email) ? email.to_s.split('@').last : nil
    end

    def admin?
      respond_to?(:role) ? role == 'admin' : false
    end
  end

  def demonstrate_bad_concern_design
    # God Concern: メソッド数が多すぎる
    god_methods = BadGodConcern.instance_methods(false)

    # クラス依存 Concern: 特定のクラスでしか動作しない
    dependent_class = Class.new do
      include BadClassDependentConcern

      attr_accessor :email, :role

      def initialize(email:, role:)
        @email = email
        @role = role
      end
    end

    # email/role を持たないクラスでインクルードした場合
    unrelated_class = Class.new do
      include BadClassDependentConcern
    end

    user = dependent_class.new(email: 'admin@example.com', role: 'admin')
    unrelated = unrelated_class.new

    {
      # God Concern: 無関係な5つのメソッドが1つのモジュールに
      god_concern_method_count: god_methods.length,
      god_concern_methods: god_methods.sort,
      # クラス依存 Concern: User以外では意味をなさない
      user_admin: user.admin?,
      user_domain: user.admin_email_domain,
      # メソッドは呼べるが意味のある結果にならない
      unrelated_admin: unrelated.admin?,
      unrelated_domain: unrelated.admin_email_domain,
      # 問題: Concern の再利用性が低い
      reusability_issue: 'BadClassDependentConcern はemail/roleを持つクラスでしか有効でない'
    }
  end

  # === Concern の依存関係と連鎖 ===
  #
  # Concern 同士は include で依存関係を宣言できる。
  # ActiveSupport::Concern は依存を遅延解決し、
  # 最終的にクラスに include された時点で正しい順序で全ての
  # included ブロックを実行する。
  #
  # これにより、Concern を組み合わせて複合的な振る舞いを構築できる。

  module Timestampable
    extend ActiveSupport::Concern

    included do
      class_attribute :timestamp_format, default: '%Y-%m-%d %H:%M:%S'
    end

    def current_timestamp
      Time.now.strftime(self.class.timestamp_format)
    end
  end

  module Auditable
    extend ActiveSupport::Concern

    # Timestampable に依存する
    include Timestampable

    included do
      class_attribute :audit_log_enabled, default: true
    end

    def audit_trail
      return [] unless self.class.audit_log_enabled

      [{ action: '作成', timestamp: current_timestamp, class_name: self.class.name }]
    end
  end

  module FullyTracked
    extend ActiveSupport::Concern

    # Auditable（→ Timestampable）に依存する
    include Auditable

    included do
      class_attribute :tracking_level, default: :full
    end

    def tracking_info
      {
        level: self.class.tracking_level,
        audit: audit_trail,
        timestamp: current_timestamp
      }
    end
  end

  def demonstrate_concern_dependencies
    # FullyTracked だけを include すれば、依存する Concern もすべて含まれる
    tracked_class = Class.new do
      include FullyTracked

      def self.name
        'TrackedRecord'
      end
    end

    instance = tracked_class.new

    {
      # 3つの Concern が全て正しく include されている
      has_fully_tracked: tracked_class.ancestors.include?(FullyTracked),
      has_auditable: tracked_class.ancestors.include?(Auditable),
      has_timestampable: tracked_class.ancestors.include?(Timestampable),
      # 依存先の class_attribute も正しく設定されている
      timestamp_format: tracked_class.timestamp_format,
      audit_enabled: tracked_class.audit_log_enabled,
      tracking_level: tracked_class.tracking_level,
      # 各 Concern のメソッドが使える
      timestamp: instance.current_timestamp.is_a?(String),
      audit_trail: instance.audit_trail.length,
      tracking_info_keys: instance.tracking_info.keys.sort
    }
  end

  # === class_methods ブロック vs extend ClassMethods ===
  #
  # Concern 以前は、クラスメソッドを追加するために
  # ClassMethods モジュールを定義して extend する
  # パターンが使われていた。
  #
  # Concern の class_methods ブロックはこのパターンを簡潔にし、
  # 内部的に同じことを行う。
  #
  # どちらも機能的には等価だが、class_methods ブロックの方が
  # 意図が明確で、ボイラープレートが少ない。

  # 旧パターン: extend ClassMethods
  module OldStyleConcern
    extend ActiveSupport::Concern

    module ClassMethods
      def old_style_class_method
        '旧スタイル: extend ClassMethods'
      end
    end

    def old_style_instance_method
      '旧スタイルのインスタンスメソッド'
    end
  end

  # 新パターン: class_methods ブロック
  module NewStyleConcern
    extend ActiveSupport::Concern

    class_methods do
      def new_style_class_method
        '新スタイル: class_methods ブロック'
      end
    end

    def new_style_instance_method
      '新スタイルのインスタンスメソッド'
    end
  end

  def demonstrate_class_methods_styles
    old_class = Class.new { include OldStyleConcern }
    new_class = Class.new { include NewStyleConcern }

    {
      # 旧スタイル: 機能的には問題なく動作する
      old_class_method: old_class.old_style_class_method,
      old_instance_method: old_class.new.old_style_instance_method,
      # 新スタイル: 同じ結果をより簡潔に
      new_class_method: new_class.new_style_class_method,
      new_instance_method: new_class.new.new_style_instance_method,
      # 内部的には両方とも ClassMethods モジュールを使っている
      old_has_class_methods_module: OldStyleConcern.const_defined?(:ClassMethods),
      new_has_class_methods_module: NewStyleConcern.const_defined?(:ClassMethods),
      # 推奨: class_methods ブロックの方が意図が明確
      recommendation: 'class_methods ブロックを使うべき（Rails 4.2+）'
    }
  end

  # === 設定可能な Concern ===
  #
  # Concern をクラスごとにカスタマイズ可能にすることで、
  # 再利用性が大幅に向上する。
  #
  # パターン:
  #   1. class_attribute でデフォルト値を設定
  #   2. DSL メソッドをクラスメソッドとして提供
  #   3. インクルード先のクラスで DSL を呼んで設定をオーバーライド

  module Paginatable
    extend ActiveSupport::Concern

    included do
      class_attribute :per_page, default: 25
      class_attribute :max_per_page, default: 100
    end

    class_methods do
      # ページネーション設定用 DSL
      def paginates_per(count)
        self.per_page = [count, max_per_page].min
      end

      # 最大ページサイズの設定
      def max_paginates_per(count)
        self.max_per_page = count
      end

      # ページネーション計算
      def page_count(total_count)
        (total_count.to_f / per_page).ceil
      end
    end

    # インスタンスからもページネーション情報にアクセスできる
    def pagination_info(total_count, current_page: 1)
      total_pages = self.class.page_count(total_count)
      {
        current_page: current_page,
        per_page: self.class.per_page,
        total_count: total_count,
        total_pages: total_pages,
        has_next: current_page < total_pages,
        has_prev: current_page > 1
      }
    end
  end

  def demonstrate_configurable_concern
    # デフォルト設定のクラス
    default_class = Class.new do
      include Paginatable

      def self.name
        'DefaultModel'
      end
    end

    # カスタム設定のクラス
    custom_class = Class.new do
      include Paginatable

      paginates_per 10
      max_paginates_per 50

      def self.name
        'CustomModel'
      end
    end

    # per_page が max_per_page を超える場合
    capped_class = Class.new do
      include Paginatable

      max_paginates_per 5
      paginates_per 999 # max_per_page の 5 に制限される

      def self.name
        'CappedModel'
      end
    end

    default_class.new
    custom_instance = custom_class.new

    {
      # デフォルト設定
      default_per_page: default_class.per_page,
      default_max: default_class.max_per_page,
      default_page_count: default_class.page_count(100),
      # カスタム設定
      custom_per_page: custom_class.per_page,
      custom_max: custom_class.max_per_page,
      custom_page_count: custom_class.page_count(100),
      # 上限制限
      capped_per_page: capped_class.per_page,
      # インスタンスメソッドでのページネーション情報
      pagination_info: custom_instance.pagination_info(95, current_page: 5),
      # クラスごとに独立した設定が可能
      settings_independent: default_class.per_page != custom_class.per_page
    }
  end

  # === Concern を使わないべき場面と代替パターン ===
  #
  # Concern が不適切な場面:
  #   1. ロジックが複雑で状態を持つ → サービスオブジェクト
  #   2. 特定の操作を委譲したい → Delegation（Forwardable, delegate）
  #   3. 異なるインターフェースで同じ処理 → Composition（has_one + delegate）
  #   4. 条件によって振る舞いが変わる → Strategy パターン
  #
  # 判断基準:
  # 「このモジュールは複数の無関係なクラスに include できるか？」
  # → できないなら Concern ではなく別のパターンを使うべき。

  # 代替1: サービスオブジェクト（複雑なロジックの隔離）
  class NotificationService
    def initialize(recipient)
      @recipient = recipient
    end

    def send_welcome
      { type: 'welcome', to: @recipient, status: 'sent' }
    end

    def send_reminder
      { type: 'reminder', to: @recipient, status: 'sent' }
    end
  end

  # 代替2: Delegation（Forwardable）
  class UserPresenter
    require 'forwardable'
    extend Forwardable

    def_delegators :@user, :name, :email

    def initialize(user)
      @user = user
    end

    def display_name
      "#{name}様"
    end

    def masked_email
      local, domain = email.split('@')
      "#{local[0..1]}***@#{domain}"
    end
  end

  # 代替3: Composition（オブジェクト合成）
  class Address
    attr_reader :city, :state, :zip

    def initialize(city:, state:, zip:)
      @city = city
      @state = state
      @zip = zip
    end

    def full_address
      "#{zip} #{state}#{city}"
    end
  end

  class Customer
    attr_reader :name, :address

    def initialize(name:, address:)
      @name = name
      @address = address
    end

    # 住所関連の処理を Address オブジェクトに委譲
    def full_address
      address.full_address
    end
  end

  def demonstrate_alternatives_to_concerns
    # サービスオブジェクト: 複雑なロジックを分離
    service = NotificationService.new('user@example.com')
    welcome = service.send_welcome
    reminder = service.send_reminder

    # Delegation: Presenter パターン
    user_data = Struct.new(:name, :email).new('田中太郎', 'tanaka@example.com')
    presenter = UserPresenter.new(user_data)

    # Composition: オブジェクト合成
    address = Address.new(city: '渋谷区', state: '東京都', zip: '150-0001')
    customer = Customer.new(name: '佐藤花子', address: address)

    {
      # サービスオブジェクト: テストしやすく、状態を持てる
      service_welcome: welcome,
      service_reminder: reminder,
      # Delegation: 内部オブジェクトのメソッドを委譲
      presenter_display_name: presenter.display_name,
      presenter_masked_email: presenter.masked_email,
      # Composition: 住所ロジックを Address に閉じ込める
      customer_address: customer.full_address,
      address_independent: address.full_address,
      # 使い分けの指針
      guideline: {
        concern: '複数のクラスで共有する振る舞い（Trackable, Searchable）',
        service: '複雑なビジネスロジック（NotificationService, PaymentProcessor）',
        delegation: '内部オブジェクトのインターフェース公開（Presenter, Decorator）',
        composition: 'has-a 関係のモデリング（Customer has Address）'
      }
    }
  end

  # === Concern のテスト戦略: shared_examples パターン ===
  #
  # Concern のテストでは、RSpec の shared_examples を使って
  # 「この Concern を include したクラスはこう振る舞うべき」
  # というコントラクトテストを書く。
  #
  # shared_examples を使うメリット:
  #   1. Concern を include する全クラスで同じテストを再利用できる
  #   2. Concern の振る舞いの契約（コントラクト）を明文化できる
  #   3. 新しいクラスに Concern を追加した際、it_behaves_like で即テスト

  # テスト対象の Concern
  module Publishable
    extend ActiveSupport::Concern

    included do
      class_attribute :default_publish_status, default: :draft
    end

    class_methods do
      def publish_statuses
        %i[draft reviewing published archived]
      end
    end

    def publish!
      @publish_status = :published
      @published_at = Time.now
      { status: :published, at: @published_at }
    end

    def unpublish!
      @publish_status = :draft
      @published_at = nil
      { status: :draft }
    end

    def published?
      @publish_status == :published
    end

    def publish_status
      @publish_status || self.class.default_publish_status
    end
  end

  def demonstrate_testing_concerns
    # テスト用のクラスを2つ作成し、同じ Concern の振る舞いを確認
    article_class = Class.new do
      include Publishable

      def self.name = 'Article'
    end

    page_class = Class.new do
      include Publishable

      def self.name = 'Page'
    end

    article = article_class.new
    page = page_class.new

    # 両方のクラスで同じ振る舞いが期待される
    article.publish!
    page.publish!

    {
      # 両クラスで Publishable の振る舞いが一致する
      article_published: article.published?,
      page_published: page.published?,
      article_status: article.publish_status,
      page_status: page.publish_status,
      # クラスメソッドも両方で使える
      article_statuses: article_class.publish_statuses,
      page_statuses: page_class.publish_statuses,
      # unpublish も両方で動作する
      article_unpublished: begin
        article.unpublish!
        !article.published?
      end,
      page_unpublished: begin
        page.unpublish!
        !page.published?
      end,
      # テスト戦略の説明
      testing_strategy: {
        shared_examples: "shared_examples 'publishable' を定義",
        usage: "it_behaves_like 'publishable' を各モデルのspecに追加",
        benefit: 'Concern のコントラクトテストを全インクルード先で再利用'
      }
    }
  end
end
