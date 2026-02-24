# frozen_string_literal: true

require_relative 'method_lookup'

RSpec.describe MethodLookup do
  # ==========================================================================
  # 1. 基本的なメソッド探索順序
  # ==========================================================================
  describe 'メソッド探索順序' do
    it 'クラス自身のメソッドが最優先で呼び出される' do
      expect(described_class.user_greeting).to eq('User#greeting')
    end

    it 'ancestors チェーンが正しい順序で構成される' do
      ancestors = described_class.user_ancestors
      user_index = ancestors.index(MethodLookup::User)
      printable_index = ancestors.index(MethodLookup::Printable)
      greetable_index = ancestors.index(MethodLookup::Greetable)
      base_entity_index = ancestors.index(MethodLookup::BaseEntity)

      # User → Printable（後に include）→ Greetable（先に include）→ BaseEntity
      expect(user_index).to be < printable_index
      expect(printable_index).to be < greetable_index
      expect(greetable_index).to be < base_entity_index
    end

    it 'ancestors チェーンの末尾は BasicObject である' do
      expect(described_class.user_ancestors.last).to eq(BasicObject)
    end
  end

  # ==========================================================================
  # 2. include vs prepend
  # ==========================================================================
  describe 'include vs prepend' do
    it 'include の場合、クラスのメソッドが優先される' do
      expect(described_class.include_action).to eq('ServiceWithInclude#action')
    end

    it 'prepend の場合、モジュールのメソッドが優先される' do
      expect(described_class.prepend_action).to eq('LoggingPrepend#action')
    end

    it 'include は ancestors でクラスの後ろに挿入される' do
      ancestors = described_class.include_ancestors
      class_index = ancestors.index(MethodLookup::ServiceWithInclude)
      module_index = ancestors.index(MethodLookup::LoggingInclude)

      expect(class_index).to be < module_index
    end

    it 'prepend は ancestors でクラスの前に挿入される' do
      ancestors = described_class.prepend_ancestors
      class_index = ancestors.index(MethodLookup::ServiceWithPrepend)
      module_index = ancestors.index(MethodLookup::LoggingPrepend)

      expect(module_index).to be < class_index
    end
  end

  # ==========================================================================
  # 3. prepend + super によるデコレータパターン
  # ==========================================================================
  describe 'prepend + super によるデコレータ' do
    it 'prepend されたモジュールが super で元メソッドをラップする' do
      result = described_class.decorated_process(5)

      expect(result).to eq({ original_result: 10, decorated: true })
    end
  end

  # ==========================================================================
  # 4. 複数 include の探索順序（LIFO）
  # ==========================================================================
  describe '複数 include の LIFO 順序' do
    it '最後に include されたモジュールが最初に探索される' do
      expect(described_class.multi_include_identity).to eq('ModuleC')
    end

    it 'ancestors チェーンで include 順序が逆順になる' do
      ancestors = described_class.multi_include_ancestors
      class_index = ancestors.index(MethodLookup::MultiIncluder)
      c_index = ancestors.index(MethodLookup::ModuleC)
      b_index = ancestors.index(MethodLookup::ModuleB)
      a_index = ancestors.index(MethodLookup::ModuleA)

      # MultiIncluder → ModuleC → ModuleB → ModuleA（LIFO）
      expect(class_index).to be < c_index
      expect(c_index).to be < b_index
      expect(b_index).to be < a_index
    end
  end

  # ==========================================================================
  # 5. super キーワードの動作
  # ==========================================================================
  describe 'super キーワード' do
    it 'super チェーンを通じて計算結果が伝播される' do
      # SuperDemo#calculate → SuperMiddle#calculate → SuperBase#calculate
      # SuperBase: 3 + 5 = 8
      # SuperMiddle: 8 * 2 = 16
      # SuperDemo: super で 16 を返す
      expect(described_class.super_chain_result(3, 5)).to eq(16)
    end

    it 'super() は引数なしで親メソッドを呼び出す' do
      result = described_class.explicit_super_config(env: 'production')

      # super() は引数なし → DefaultProvider#config({}) → { defaults: true }
      # その後 { custom: true } を merge
      expect(result).to eq({ defaults: true, custom: true })
    end

    it 'super は引数をそのまま親メソッドに転送する' do
      result = described_class.implicit_super_config(env: 'production')

      # super は引数を転送 → DefaultProvider#config({ env: "production" })
      # → { defaults: true, env: "production" }
      # その後 { custom: true } を merge
      expect(result).to eq({ defaults: true, env: 'production', custom: true })
    end
  end

  # ==========================================================================
  # 6. method_missing と respond_to_missing?
  # ==========================================================================
  describe 'method_missing と respond_to_missing?' do
    let(:result) { described_class.dynamic_finder_example }

    it '動的メソッドが正しく呼び出される' do
      expect(result[:find_by_name]).to eq({ attribute: :name, value: 'Alice', found: true })
      expect(result[:find_by_email]).to eq({ attribute: :email, value: 'alice@example.com', found: true })
    end

    it 'respond_to? が許可された属性に対して true を返す' do
      expect(result[:responds_to_find_by_name]).to be true
      expect(result[:responds_to_find_by_age]).to be true
    end

    it 'respond_to? が未許可の属性に対して false を返す' do
      expect(result[:responds_to_find_by_unknown]).to be false
    end

    it 'method オブジェクトが取得できる（respond_to_missing? の効果）' do
      expect(result[:method_object_available]).to be true
    end

    it '未許可の動的メソッド呼び出しは NoMethodError を発生させる' do
      finder = MethodLookup::DynamicFinder.new

      expect { finder.find_by_unknown('test') }.to raise_error(NoMethodError)
    end
  end

  # ==========================================================================
  # 7. Module#ancestors の活用
  # ==========================================================================
  describe 'Module#ancestors' do
    it '継承チェーンにおけるモジュールの位置を確認できる' do
      ancestors = described_class.product_ancestors

      # Product → Cacheable → ApplicationRecord → Serializable → Object → ...
      product_idx = ancestors.index(MethodLookup::Product)
      cacheable_idx = ancestors.index(MethodLookup::Cacheable)
      app_record_idx = ancestors.index(MethodLookup::ApplicationRecord)
      serializable_idx = ancestors.index(MethodLookup::Serializable)

      expect(product_idx).to be < cacheable_idx
      expect(cacheable_idx).to be < app_record_idx
      expect(app_record_idx).to be < serializable_idx
    end

    it 'module_position_in_ancestors でモジュールの位置を取得できる' do
      position = described_class.module_position_in_ancestors(
        MethodLookup::Product,
        MethodLookup::Cacheable
      )

      expect(position).to be_a(Integer)
      expect(position).to be_positive # Product 自身（0）の後ろ
    end
  end

  # ==========================================================================
  # 8. Refinements（プレビュー）
  # ==========================================================================
  describe 'Refinements' do
    it 'Refinements で定義したメソッドが using スコープ内で使える' do
      expect(described_class.refinement_shout('hello')).to eq('HELLO!!!')
    end

    it 'Refinements は ancestors に表示されない' do
      expect(described_class.refinement_not_in_ancestors).to be false
    end
  end
end
