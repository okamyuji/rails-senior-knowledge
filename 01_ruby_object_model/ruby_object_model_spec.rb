# frozen_string_literal: true

require_relative 'ruby_object_model'

RSpec.describe RubyObjectModel do
  describe '.demonstrate_class_hierarchy' do
    let(:result) { described_class.demonstrate_class_hierarchy }

    it 'すべてのクラスの祖先に BasicObject が含まれることを確認する' do
      expect(result[:has_basic_object]).to be true
      expect(result[:has_object]).to be true
      expect(result[:has_kernel]).to be true
    end

    it '継承チェーンの頂点が BasicObject であることを確認する' do
      expect(result[:root_ancestor]).to eq BasicObject
      expect(result[:object_superclass]).to eq BasicObject
      expect(result[:basic_object_superclass]).to be_nil
    end

    it 'Integer の祖先チェーンに Numeric と Comparable が含まれることを確認する' do
      expect(result[:integer_ancestors]).to include(Numeric, Comparable, Object, Kernel, BasicObject)
    end
  end

  describe '.demonstrate_singleton_class' do
    let(:result) { described_class.demonstrate_singleton_class }

    it '特異メソッドが定義されたオブジェクトだけが応答することを確認する' do
      expect(result[:obj_a_responds]).to be true
      expect(result[:obj_b_responds]).to be false
    end

    it 'シングルトンクラスの構造を確認する' do
      expect(result[:singleton_is_class]).to be true
      expect(result[:singleton_superclass]).to eq Object
      expect(result[:singleton_methods]).to eq [:greet]
    end
  end

  describe '.demonstrate_instance_variable_storage' do
    let(:result) { described_class.demonstrate_instance_variable_storage }

    it 'インスタンス変数がオブジェクトごとに独立して格納されることを確認する' do
      expect(result[:alice_vars]).to eq [:@name]
      expect(result[:bob_vars]).to eq %i[@age @name]
    end

    it 'インスタンス変数への動的アクセスが可能であることを確認する' do
      expect(result[:alice_name]).to eq 'Alice'
      expect(result[:bob_age]).to eq 30
      expect(result[:alice_dynamic]).to eq 'set dynamically'
      expect(result[:alice_vars_after]).to include(:@dynamic)
    end
  end

  describe '.demonstrate_immediate_values' do
    let(:result) { described_class.demonstrate_immediate_values }

    it '整数が即値として同一オブジェクトであることを確認する' do
      expect(result[:same_integer_identity]).to be true
    end

    it 'Symbol が同じ名前なら同一オブジェクトであることを確認する' do
      expect(result[:symbol_same_object]).to be true
      expect(result[:symbol_same_id]).to be true
    end

    it 'true, false, nil がフリーズ済みの即値であることを確認する' do
      expect(result[:true_frozen]).to be true
      expect(result[:false_frozen]).to be true
      expect(result[:nil_frozen]).to be true
      # CRuby 3.4 の即値 object_id
      expect(result[:true_id]).to eq 20
      expect(result[:false_id]).to eq 0
      expect(result[:nil_id]).to eq 4
    end
  end

  describe '.demonstrate_identity_vs_equality' do
    let(:result) { described_class.demonstrate_identity_vs_equality }

    it '== と equal? の違いを確認する' do
      # 同じ内容の文字列は == で等しいが、equal? では異なる
      expect(result[:value_equal]).to be true
      expect(result[:identity_equal]).to be false
    end

    it 'eql? が型変換を行わないことを確認する' do
      expect(result[:int_float_equal]).to be true # == は 1 == 1.0 を true にする
      expect(result[:int_float_eql]).to be false # eql? は型が異なると false
    end

    it 'Hash の契約（eql? と hash の整合性）を確認する' do
      expect(result[:hash_contract]).to be true
      expect(result[:symbol_identity]).to be true
    end
  end

  describe '.demonstrate_frozen_objects' do
    let(:result) { described_class.demonstrate_frozen_objects }

    it 'frozen_string_literal プラグマの効果を確認する' do
      expect(result[:literal_frozen]).to be true
      expect(result[:mutable_not_frozen]).to be true
    end

    it 'フリーズされたオブジェクトへの変更で FrozenError が発生することを確認する' do
      expect(result[:frozen_error_raised]).to be true
    end

    it 'dup と clone のフリーズ状態の違いを確認する' do
      # dup はフリーズを解除する
      expect(result[:duped_not_frozen]).to be true
      expect(result[:duped_content]).to eq [1, 2, 3]
      # clone はフリーズ状態を保持する
      expect(result[:cloned_frozen]).to be true
      # freeze は不可逆
      expect(result[:still_frozen_after]).to be true
    end
  end

  describe '.demonstrate_class_as_object' do
    let(:result) { described_class.demonstrate_class_as_object }

    it 'クラスが Class のインスタンスであることを確認する' do
      expect(result[:string_is_class_instance]).to be true
      expect(result[:class_is_class_instance]).to be true
    end

    it 'Class → Module → Object の継承チェーンを確認する' do
      expect(result[:class_superclass]).to eq Module
      expect(result[:module_superclass]).to eq Object
    end

    it '動的に生成したクラスが正常に動作することを確認する' do
      expect(result[:dynamic_instance_hello]).to eq 'dynamic hello'
      expect(result[:dynamic_instance_world]).to eq 'dynamic world'
    end

    it 'クラスのクラスが Class であることを確認する' do
      expect(result[:class_of_string]).to eq Class
      expect(result[:class_of_class]).to eq Class
      expect(result[:class_has_object_id]).to be true
    end
  end
end
