# frozen_string_literal: true

require_relative 'activemodel_attributes'

RSpec.describe ActiveModelAttributes do
  describe '.demonstrate_basic_attributes' do
    let(:result) { described_class.demonstrate_basic_attributes }

    it '文字列から各型への自動キャストが正しく行われることを確認する' do
      # 文字列 "30" が Integer にキャストされる
      expect(result[:age]).to eq 30
      expect(result[:age_class]).to eq Integer
      # 文字列 "1" が Boolean true にキャストされる
      expect(result[:active]).to be true
      # 名前は文字列のまま
      expect(result[:name]).to eq '田中太郎'
      expect(result[:name_class]).to eq String
    end

    it 'デフォルト値が正しく設定されることを確認する' do
      expect(result[:default_active]).to be true
    end

    it 'nilを明示的に渡した場合はデフォルト値にならないことを確認する' do
      expect(result[:nil_age]).to be_nil
    end

    it 'attributesメソッドで全属性のハッシュが取得できることを確認する' do
      expect(result[:attributes]).to include(
        'name' => '田中太郎',
        'age' => 30,
        'active' => true
      )
    end
  end

  describe '.demonstrate_type_casting' do
    let(:result) { described_class.demonstrate_type_casting }

    it '文字列から数値型への型キャストが正しく行われることを確認する' do
      expect(result[:integer_from_string]).to eq 42
      expect(result[:integer_from_string_class]).to eq Integer
      # 浮動小数点から整数への切り捨て
      expect(result[:integer_from_float]).to eq 3
    end

    it 'Decimal型への変換が正確に行われることを確認する' do
      expect(result[:decimal_from_string]).to eq BigDecimal('19.99')
      expect(result[:decimal_class]).to eq BigDecimal
    end

    it 'Boolean型のキャストが多様な入力値に対応することを確認する' do
      casting = result[:boolean_casting]
      # truthy な値
      expect(casting['1']).to be true
      expect(casting['true']).to be true
      expect(casting['t']).to be true
      expect(casting['on']).to be true
      # falsy な値
      expect(casting['0']).to be false
      expect(casting['false']).to be false
      expect(casting['f']).to be false
      expect(casting['off']).to be false
    end

    it '空文字列が数値型ではnilに、文字列型では空文字列のままになることを確認する' do
      expect(result[:integer_from_empty]).to be_nil
      expect(result[:string_from_empty]).to eq ''
    end

    it '日付文字列がDateオブジェクトに変換されることを確認する' do
      expect(result[:date_from_string]).to eq Date.new(2024, 12, 25)
      expect(result[:date_class]).to eq Date
    end
  end

  describe '.demonstrate_custom_types' do
    let(:result) { described_class.demonstrate_custom_types }

    it 'カスタムEmail型が入力を正規化することを確認する' do
      # 前後の空白除去 + 小文字化
      expect(result[:normalized_email]).to eq 'admin@example.com'
    end

    it 'カスタムStringArray型がカンマ区切り文字列を配列に変換することを確認する' do
      expect(result[:tags_from_string]).to eq %w[ruby rails activemodel]
    end

    it 'カスタムStringArray型が配列入力から空要素を除去することを確認する' do
      expect(result[:tags_from_array]).to eq %w[ruby rails]
    end

    it 'カスタム型がnilと空文字列を正しく処理することを確認する' do
      expect(result[:nil_email]).to be_nil
      expect(result[:blank_email]).to be_nil
    end
  end

  describe '.demonstrate_default_values' do
    let(:result) { described_class.demonstrate_default_values }

    it '静的デフォルト値が正しく設定されることを確認する' do
      expect(result[:default_status]).to eq 'pending'
      expect(result[:default_max]).to eq 10
    end

    it '動的デフォルト値がインスタンスごとに異なることを確認する' do
      expect(result[:tokens_differ]).to be true
      expect(result[:reg1_token]).not_to eq result[:reg2_token]
    end

    it '明示的に値を指定するとデフォルト値が上書きされることを確認する' do
      expect(result[:custom_status]).to eq 'confirmed'
    end
  end

  describe '.demonstrate_dirty_tracking' do
    let(:result) { described_class.demonstrate_dirty_tracking }

    it '属性変更後にchanged?がtrueを返すことを確認する' do
      state = result[:changed_state]
      expect(state[:changed]).to be true
      expect(state[:changed_attributes_list]).to contain_exactly('name', 'email')
    end

    it '変更前後の値をchangesで取得できることを確認する' do
      state = result[:changed_state]
      expect(state[:name_changed]).to be true
      expect(state[:name_was]).to eq '佐藤'
      expect(state[:name_change]).to eq %w[佐藤 鈴木]
      # 変更していない属性
      expect(state[:age_changed]).to be false
    end

    it 'save後にchangesがクリアされprevious_changesに移動することを確認する' do
      after = result[:after_save_state]
      expect(after[:changed_after_save]).to be false
      expect(after[:previous_changes]).to include('name', 'email')
    end

    it 'restore_attributesで変更前の値に戻せることを確認する' do
      rollback = result[:rollback_state]
      expect(rollback[:name_after_rollback]).to eq '田中'
      expect(rollback[:changed_after_rollback]).to be false
    end
  end

  describe '.demonstrate_validations' do
    let(:result) { described_class.demonstrate_validations }

    it '有効なフォームがバリデーションを通過することを確認する' do
      expect(result[:valid_result]).to be true
      expect(result[:valid_errors]).to be_empty
    end

    it '無効なフォームが適切なエラーメッセージを返すことを確認する' do
      expect(result[:invalid_result]).to be false
      expect(result[:invalid_errors]).not_to be_empty
      # 年齢が型キャストされた値に対してバリデーションが行われる
      expect(result[:casted_age]).to eq 15
    end

    it 'カスタムバリデーションが予約語を検出することを確認する' do
      expect(result[:reserved_valid]).to be false
      expect(result[:reserved_errors].join).to include('予約語')
    end
  end

  describe '.demonstrate_serialization' do
    let(:result) { described_class.demonstrate_serialization }

    it 'serializable_hashが全属性を含むハッシュを返すことを確認する' do
      hash = result[:serializable_hash]
      expect(hash).to include('id' => 1, 'title' => 'ActiveModelガイド')
      expect(hash['score']).to eq 4.5
      expect(hash['published']).to be true
    end

    it 'as_jsonのonlyオプションで出力フィールドを限定できることを確認する' do
      json = result[:json_with_options]
      expect(json.keys).to contain_exactly('id', 'title', 'score')
    end

    it 'from_jsonでJSONからオブジェクトを復元できることを確認する' do
      expect(result[:restored_id]).to eq 2
      expect(result[:restored_title]).to eq '復元テスト'
      expect(result[:restored_score]).to eq 3.8
    end
  end

  describe '.demonstrate_form_object_pattern' do
    let(:result) { described_class.demonstrate_form_object_pattern }

    it '有効なフォームオブジェクトの保存が成功することを確認する' do
      expect(result[:valid_save_result]).to be_a(Hash)
      expect(result[:valid_save_result][:user][:name]).to eq '山田太郎'
    end

    it '無効なフォームオブジェクトの保存が失敗しエラーを返すことを確認する' do
      expect(result[:invalid_save_result]).to be false
      expect(result[:invalid_errors]).not_to be_empty
    end

    it 'model_nameがフォーム連携用の情報を提供することを確認する' do
      # param_key はフォームのパラメータ名に使われる
      expect(result[:param_key]).to eq 'active_model_attributes_user_registration_form'
    end

    it 'to_resultでフォーム内容を構造化して取得できることを確認する' do
      form_result = result[:form_result]
      expect(form_result[:name]).to eq '山田太郎'
      expect(form_result[:email]).to eq 'yamada@example.com'
      expect(form_result[:terms_accepted]).to be true
    end
  end
end
