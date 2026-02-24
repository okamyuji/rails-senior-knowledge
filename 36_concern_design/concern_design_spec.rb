# frozen_string_literal: true

require_relative 'concern_design'

RSpec.describe ConcernDesign do
  describe '.demonstrate_concern_basics' do
    let(:result) { described_class.demonstrate_concern_basics }

    it 'included ブロックで設定された class_attribute のデフォルト値が有効であることを確認する' do
      expect(result[:default_tracking]).to be true
    end

    it 'Concern のインスタンスメソッドが正しく動作することを確認する' do
      expect(result[:event_tracked]).to be true
      expect(result[:event_name]).to eq 'ページ閲覧'
    end

    it 'クラスメソッドでトラッキングを無効化できることを確認する' do
      expect(result[:disabled_event]).to be_nil
    end

    it 'ancestors に Concern モジュールが含まれることを確認する' do
      expect(result[:includes_trackable]).to be true
    end
  end

  describe '.demonstrate_concern_vs_plain_module' do
    let(:result) { described_class.demonstrate_concern_vs_plain_module }

    it '素のモジュールでは依存先の included が最終クラスに対して実行されないことを確認する' do
      # PlainModuleA の included は実行される
      expect(result[:plain_a_included]).to be true
      # PlainModuleB の included は最終クラスに対して実行されない
      expect(result[:plain_b_included]).to be true
      # しかしメソッド自体は使える
      expect(result[:plain_b_method_available]).to be true
    end

    it 'Concern では依存先の included ブロックも自動的に実行されることを確認する' do
      expect(result[:concern_a_flag]).to be true
      expect(result[:concern_b_flag]).to be true
    end

    it 'Concern の依存先のメソッドが正しく使えることを確認する' do
      expect(result[:concern_b_method]).to eq 'from ConcernB'
    end

    it 'ancestors に依存先の Concern も含まれることを確認する' do
      expect(result[:ancestors_include_both]).to be true
    end
  end

  describe '.demonstrate_good_concern_design' do
    let(:result) { described_class.demonstrate_good_concern_design }

    it 'Sluggable Concern がタイトルから slug を生成することを確認する' do
      expect(result[:slug]).to be_a(String)
      expect(result[:slug]).not_to be_empty
      expect(result[:slug_source]).to eq :title
    end

    it 'Sluggable Concern のクラスメソッドが動作することを確認する' do
      expect(result[:find_result]).to eq({ found: true, slug: 'ruby-on-rails' })
    end

    it 'Archivable Concern がアーカイブ/復元操作を提供することを確認する' do
      expect(result[:was_archived]).to be true
      expect(result[:now_archived]).to be false
    end
  end

  describe '.demonstrate_bad_concern_design' do
    let(:result) { described_class.demonstrate_bad_concern_design }

    it 'God Concern が過剰な数のメソッドを持つことを確認する' do
      expect(result[:god_concern_method_count]).to eq 5
      expect(result[:god_concern_methods]).to include(:format_name, :send_notification, :authenticate)
    end

    it 'クラス依存 Concern が特定のクラスでのみ有効であることを確認する' do
      # email/role を持つクラスでは動作する
      expect(result[:user_admin]).to be true
      expect(result[:user_domain]).to eq 'example.com'
      # email/role を持たないクラスでは無意味な結果になる
      expect(result[:unrelated_admin]).to be false
      expect(result[:unrelated_domain]).to be_nil
    end
  end

  describe '.demonstrate_concern_dependencies' do
    let(:result) { described_class.demonstrate_concern_dependencies }

    it '依存する3つの Concern が全て正しく include されることを確認する' do
      expect(result[:has_fully_tracked]).to be true
      expect(result[:has_auditable]).to be true
      expect(result[:has_timestampable]).to be true
    end

    it '依存先の class_attribute が正しく設定されることを確認する' do
      expect(result[:timestamp_format]).to eq '%Y-%m-%d %H:%M:%S'
      expect(result[:audit_enabled]).to be true
      expect(result[:tracking_level]).to eq :full
    end

    it '依存チェーン全体のメソッドが利用可能であることを確認する' do
      expect(result[:timestamp]).to be true
      expect(result[:audit_trail]).to eq 1
      expect(result[:tracking_info_keys]).to eq %i[audit level timestamp]
    end
  end

  describe '.demonstrate_class_methods_styles' do
    let(:result) { described_class.demonstrate_class_methods_styles }

    it '旧スタイル（extend ClassMethods）でクラスメソッドが動作することを確認する' do
      expect(result[:old_class_method]).to eq '旧スタイル: extend ClassMethods'
      expect(result[:old_instance_method]).to eq '旧スタイルのインスタンスメソッド'
    end

    it '新スタイル（class_methods ブロック）でクラスメソッドが動作することを確認する' do
      expect(result[:new_class_method]).to eq '新スタイル: class_methods ブロック'
      expect(result[:new_instance_method]).to eq '新スタイルのインスタンスメソッド'
    end

    it '両スタイルとも内部的に ClassMethods モジュールを使っていることを確認する' do
      expect(result[:old_has_class_methods_module]).to be true
      expect(result[:new_has_class_methods_module]).to be true
    end
  end

  describe '.demonstrate_configurable_concern' do
    let(:result) { described_class.demonstrate_configurable_concern }

    it 'デフォルト設定が正しく適用されることを確認する' do
      expect(result[:default_per_page]).to eq 25
      expect(result[:default_max]).to eq 100
      expect(result[:default_page_count]).to eq 4 # 100 / 25 = 4
    end

    it 'カスタム設定が正しく適用されることを確認する' do
      expect(result[:custom_per_page]).to eq 10
      expect(result[:custom_max]).to eq 50
      expect(result[:custom_page_count]).to eq 10 # 100 / 10 = 10
    end

    it 'per_page が max_per_page を超えないように制限されることを確認する' do
      expect(result[:capped_per_page]).to eq 5
    end

    it 'クラスごとに独立した設定が維持されることを確認する' do
      expect(result[:settings_independent]).to be true
    end

    it 'インスタンスメソッドでページネーション情報が取得できることを確認する' do
      info = result[:pagination_info]
      expect(info[:current_page]).to eq 5
      expect(info[:per_page]).to eq 10
      expect(info[:total_count]).to eq 95
      expect(info[:total_pages]).to eq 10 # (95 / 10).ceil = 10
      expect(info[:has_next]).to be true
      expect(info[:has_prev]).to be true
    end
  end

  describe '.demonstrate_alternatives_to_concerns' do
    let(:result) { described_class.demonstrate_alternatives_to_concerns }

    it 'サービスオブジェクトが複雑なロジックを分離することを確認する' do
      expect(result[:service_welcome][:type]).to eq 'welcome'
      expect(result[:service_welcome][:status]).to eq 'sent'
      expect(result[:service_reminder][:type]).to eq 'reminder'
    end

    it 'Delegation パターンが内部オブジェクトのメソッドを公開することを確認する' do
      expect(result[:presenter_display_name]).to eq '田中太郎様'
      expect(result[:presenter_masked_email]).to eq 'ta***@example.com'
    end

    it 'Composition パターンがオブジェクト合成で住所を管理することを確認する' do
      expect(result[:customer_address]).to eq '150-0001 東京都渋谷区'
      expect(result[:address_independent]).to eq '150-0001 東京都渋谷区'
    end

    it '使い分けのガイドラインが4つのパターンを含むことを確認する' do
      guideline = result[:guideline]
      expect(guideline.keys).to contain_exactly(:concern, :service, :delegation, :composition)
    end
  end

  describe '.demonstrate_testing_concerns' do
    let(:result) { described_class.demonstrate_testing_concerns }

    it 'Publishable Concern が複数のクラスで同じ振る舞いを提供することを確認する' do
      expect(result[:article_published]).to be true
      expect(result[:page_published]).to be true
      expect(result[:article_status]).to eq :published
      expect(result[:page_status]).to eq :published
    end

    it 'クラスメソッドが全ての include 先で利用可能であることを確認する' do
      expect(result[:article_statuses]).to eq %i[draft reviewing published archived]
      expect(result[:page_statuses]).to eq %i[draft reviewing published archived]
    end

    it 'unpublish が全てのクラスで正しく動作することを確認する' do
      expect(result[:article_unpublished]).to be true
      expect(result[:page_unpublished]).to be true
    end

    it 'テスト戦略の情報が shared_examples パターンを含むことを確認する' do
      strategy = result[:testing_strategy]
      expect(strategy[:shared_examples]).to include('shared_examples')
      expect(strategy[:usage]).to include('it_behaves_like')
    end
  end

  # === shared_examples による Concern テストの実例 ===
  #
  # 実際のプロジェクトでは以下のように shared_examples を定義し、
  # Concern を include する全クラスのスペックで再利用する。

  shared_examples 'publishable なオブジェクト' do
    it 'デフォルトのステータスが draft であること' do
      expect(subject.publish_status).to eq :draft
    end

    it 'publish! で公開状態になること' do
      subject.publish!
      expect(subject.published?).to be true
      expect(subject.publish_status).to eq :published
    end

    it 'unpublish! で下書き状態に戻ること' do
      subject.publish!
      subject.unpublish!
      expect(subject.published?).to be false
      expect(subject.publish_status).to eq :draft
    end

    it 'publish_statuses がクラスメソッドとして利用可能であること' do
      expect(subject.class.publish_statuses).to include(:draft, :published)
    end
  end

  describe 'shared_examples によるコントラクトテスト' do
    context 'Article クラス' do
      subject do
        klass = Class.new do
          include ConcernDesign::Publishable

          def self.name = 'Article'
        end
        klass.new
      end

      it_behaves_like 'publishable なオブジェクト'
    end

    context 'Page クラス' do
      subject do
        klass = Class.new do
          include ConcernDesign::Publishable

          def self.name = 'Page'
        end
        klass.new
      end

      it_behaves_like 'publishable なオブジェクト'
    end
  end
end
