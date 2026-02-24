# frozen_string_literal: true

require_relative '../spec/spec_helper'
require_relative 'generates_token_for'

RSpec.describe GeneratesTokenFor do
  # --------------------------------------------------------------------------
  # テスト用ヘルパー: ユーザー作成
  # --------------------------------------------------------------------------
  def create_user(email: 'test@example.com', password: 'secure_password_123', email_confirmed: false)
    TokenUser.create!(
      email: email,
      password: password,
      password_confirmation: password,
      email_confirmed: email_confirmed
    )
  end

  before do
    TokenUser.delete_all
    ApiClient.delete_all
  end

  # --------------------------------------------------------------------------
  # 1. トークン生成の基本
  # --------------------------------------------------------------------------

  describe '.demonstrate_token_generation' do
    it '目的別のセキュアトークンを正しく生成・検証する' do
      result = described_class.demonstrate_token_generation

      expect(result[:tokens_are_different]).to be true
      expect(result[:reset_found]).to be true
      expect(result[:confirm_found]).to be true
      expect(result[:login_found]).to be true
    end
  end

  # --------------------------------------------------------------------------
  # 2. トークン構造と不正トークンの処理
  # --------------------------------------------------------------------------

  describe '.demonstrate_token_structure' do
    it 'トークンの構造と不正トークンの処理を検証する' do
      result = described_class.demonstrate_token_structure

      expect(result[:token_is_string]).to be true
      expect(result[:token_length]).to be_positive
      expect(%w[UTF-8 US-ASCII]).to include(result[:token_encoding])
      # 不正なトークンはnilを返す
      expect(result[:invalid_token_result]).to be_nil
      # 異なる目的のトークンは無効
      expect(result[:wrong_purpose_result]).to be_nil
    end
  end

  # --------------------------------------------------------------------------
  # 3. generates_token_for: 直接的なトークンの生成と検証
  # --------------------------------------------------------------------------

  describe 'generates_token_for の直接テスト' do
    it 'generate_token_for でトークンを生成し find_by_token_for で検証できる' do
      user = create_user

      token = user.generate_token_for(:password_reset)

      expect(token).to be_a(String)
      expect(token.length).to be > 10

      found = TokenUser.find_by_token_for(:password_reset, token)
      expect(found).to eq(user)
    end

    it '異なる目的のトークンでは検証に失敗する' do
      user = create_user

      reset_token = user.generate_token_for(:password_reset)

      # パスワードリセットトークンでメール確認は不可
      found = TokenUser.find_by_token_for(:email_confirmation, reset_token)
      expect(found).to be_nil
    end

    it '不正なトークン文字列は nil を返す' do
      result = TokenUser.find_by_token_for(:password_reset, 'completely_invalid_token')
      expect(result).to be_nil
    end

    it '空文字列のトークンは nil を返す' do
      result = TokenUser.find_by_token_for(:password_reset, '')
      expect(result).to be_nil
    end
  end

  # --------------------------------------------------------------------------
  # 4. トークン無効化: 属性変更による自動無効化
  # --------------------------------------------------------------------------

  describe '.demonstrate_token_invalidation' do
    it '属性変更によるトークン無効化が正しく動作する' do
      result = described_class.demonstrate_token_invalidation

      expect(result[:before_password_change]).to be true
      expect(result[:after_password_change]).to be true
      expect(result[:confirm_unaffected_by_password]).to be true
      expect(result[:after_email_confirmation]).to be true
    end
  end

  describe 'トークン無効化の直接テスト' do
    it 'パスワード変更後にパスワードリセットトークンが無効化される' do
      user = create_user(password: 'original_pass')
      token = user.generate_token_for(:password_reset)

      # 変更前は有効
      expect(TokenUser.find_by_token_for(:password_reset, token)).to eq(user)

      # パスワード変更
      user.update!(password: 'new_password_456', password_confirmation: 'new_password_456')

      # 変更後は無効
      expect(TokenUser.find_by_token_for(:password_reset, token)).to be_nil
    end

    it 'メール確認完了後にメール確認トークンが無効化される' do
      user = create_user(email_confirmed: false)
      token = user.generate_token_for(:email_confirmation)

      # 確認前は有効
      expect(TokenUser.find_by_token_for(:email_confirmation, token)).to eq(user)

      # メール確認を実行
      user.confirm_email!

      # 確認後は無効
      expect(TokenUser.find_by_token_for(:email_confirmation, token)).to be_nil
    end

    it '無関係な属性の変更はトークンに影響しない' do
      user = create_user(email_confirmed: false)
      confirm_token = user.generate_token_for(:email_confirmation)

      # パスワード変更はメール確認トークンに影響しない
      user.update!(password: 'changed_pass', password_confirmation: 'changed_pass')

      expect(TokenUser.find_by_token_for(:email_confirmation, confirm_token)).to eq(user)
    end
  end

  # --------------------------------------------------------------------------
  # 5. normalizes の基本テスト
  # --------------------------------------------------------------------------

  describe '.demonstrate_normalizes_basics' do
    it '属性の正規化が正しく動作する' do
      result = described_class.demonstrate_normalizes_basics

      expect(result[:saved_email]).to eq('alice@example.com')
      expect(result[:email_after_setter]).to eq('bob@example.com')
      expect(result[:found_by_normalized]).to be true
      expect(result[:where_sql_contains_normalized]).to be true
    end
  end

  describe 'normalizes の直接テスト' do
    it '保存時にメールアドレスが正規化される' do
      user = create_user(email: '  TEST@EXAMPLE.COM  ')

      expect(user.email).to eq('test@example.com')
    end

    it 'セッター呼び出し時に即座に正規化される' do
      user = create_user
      user.email = '  NEW@EXAMPLE.COM  '

      expect(user.email).to eq('new@example.com')
    end

    it 'find_by でも正規化が適用される' do
      user = create_user(email: 'findme@example.com')

      found = TokenUser.find_by(email: '  FINDME@EXAMPLE.COM  ')
      expect(found).to eq(user)
    end

    it 'where でも正規化が適用される' do
      user = create_user(email: 'search@example.com')

      results = TokenUser.where(email: '  SEARCH@EXAMPLE.COM  ')
      expect(results).to include(user)
    end
  end

  # --------------------------------------------------------------------------
  # 6. normalizes 高度な使い方
  # --------------------------------------------------------------------------

  describe '.demonstrate_normalizes_advanced' do
    it '複数属性の正規化が正しく動作する' do
      result = described_class.demonstrate_normalizes_advanced

      expect(result[:name]).to eq('Acme Corp')
      expect(result[:company_name]).to eq('Widget Inc')
      expect(result[:contact_email]).to eq('contact@acme.com')
      expect(result[:name_stripped]).to be true
      expect(result[:company_stripped]).to be true
      expect(result[:email_normalized]).to be true
    end
  end

  describe 'ApiClient の normalizes' do
    it '複数属性に同じ正規化が適用される' do
      client = ApiClient.create!(
        name: '  Test Corp  ',
        company_name: '  Test Inc  ',
        contact_email: '  ADMIN@TEST.COM  '
      )

      expect(client.name).to eq('Test Corp')
      expect(client.company_name).to eq('Test Inc')
      expect(client.contact_email).to eq('admin@test.com')
    end
  end

  # --------------------------------------------------------------------------
  # 7. カスタム正規化ブロック
  # --------------------------------------------------------------------------

  describe '.demonstrate_custom_normalizers' do
    it 'カスタム正規化ブロックが正しく動作する' do
      result = described_class.demonstrate_custom_normalizers

      expect(result[:email_normalizer]).to eq('test@example.com')
      expect(result[:phone_normalizer]).to eq('09012345678')
      expect(result[:blank_to_nil]).to be_nil
      expect(result[:blank_to_nil_with_value]).to eq('hello')
      expect(result[:japanese_strip]).to eq('こんにちは')
    end
  end

  # --------------------------------------------------------------------------
  # 8. メール確認フロー（統合テスト）
  # --------------------------------------------------------------------------

  describe '.demonstrate_email_confirmation_flow' do
    it 'メール確認フロー全体が正しく動作する' do
      result = described_class.demonstrate_email_confirmation_flow

      expect(result[:email_normalized]).to be true
      expect(result[:registered_email]).to eq('newuser@example.com')
      expect(result[:token_valid_before_confirmation]).to be true
      expect(result[:token_invalid_after_confirmation]).to be true
      expect(result[:user_confirmed]).to be true
      expect(result[:new_token_valid]).to be true
    end
  end

  # --------------------------------------------------------------------------
  # 9. セキュリティのベストプラクティス
  # --------------------------------------------------------------------------

  describe '.demonstrate_security_best_practices' do
    it 'セキュリティ推奨事項をHashで返す' do
      result = described_class.demonstrate_security_best_practices

      expect(result).to be_a(Hash)
      expect(result[:recommended_expiry]).to be_a(Hash)
      expect(result[:invalidation_strategies]).to be_a(Hash)
      expect(result[:stateless_advantage]).to include('DB')
      expect(result[:key_management]).to include('secret_key_base')
    end
  end

  # --------------------------------------------------------------------------
  # 10. NormalizerLibrary のユニットテスト
  # --------------------------------------------------------------------------

  describe NormalizerLibrary do
    describe 'EMAIL_NORMALIZER' do
      it 'メールアドレスをストリップして小文字化する' do
        normalizer = NormalizerLibrary::EMAIL_NORMALIZER

        expect(normalizer.call('  TEST@EXAMPLE.COM  ')).to eq('test@example.com')
        expect(normalizer.call('User@Gmail.Com')).to eq('user@gmail.com')
      end
    end

    describe 'PHONE_NORMALIZER' do
      it '全角数字をASCII数字に変換しハイフン・スペースを除去する' do
        normalizer = NormalizerLibrary::PHONE_NORMALIZER

        expect(normalizer.call('０９０-１２３４-５６７８')).to eq('09012345678')
        expect(normalizer.call('090 1234 5678')).to eq('09012345678')
        expect(normalizer.call('03-1234-5678')).to eq('0312345678')
      end
    end

    describe 'BLANK_TO_NIL_NORMALIZER' do
      it '空文字列をnilに変換する' do
        normalizer = NormalizerLibrary::BLANK_TO_NIL_NORMALIZER

        expect(normalizer.call('')).to be_nil
        expect(normalizer.call('  ')).to be_nil
        expect(normalizer.call('hello')).to eq('hello')
      end
    end

    describe 'JAPANESE_STRIP_NORMALIZER' do
      it '全角スペースを含む前後の空白を除去する' do
        normalizer = NormalizerLibrary::JAPANESE_STRIP_NORMALIZER

        expect(normalizer.call('　テスト　')).to eq('テスト')
        expect(normalizer.call('  テスト  ')).to eq('テスト')
        expect(normalizer.call('　 混在 　')).to eq('混在')
      end
    end
  end
end
