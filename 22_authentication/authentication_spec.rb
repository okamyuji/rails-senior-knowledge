# frozen_string_literal: true

require_relative 'authentication'

RSpec.describe AuthenticationGenerator do
  describe '.demonstrate_bcrypt_internals' do
    let(:result) { described_class.demonstrate_bcrypt_internals }

    it '同じパスワードでも異なるハッシュが生成されることを確認する' do
      expect(result[:different_hashes]).to be true
    end

    it '正しいパスワードとハッシュが一致することを確認する' do
      expect(result[:hash1_matches]).to be true
      expect(result[:hash2_matches]).to be true
    end

    it '誤ったパスワードが拒否されることを確認する' do
      expect(result[:wrong_password_rejected]).to be true
    end

    it 'BCrypt ハッシュの構造を確認する' do
      expect(result[:hash_version]).to eq '2a'
      expect(result[:hash_cost]).to be_a(Integer)
      expect(result[:hash_length]).to eq 60
    end
  end

  describe '.demonstrate_has_secure_password' do
    let(:result) { described_class.demonstrate_has_secure_password }

    it 'パスワードが BCrypt でハッシュ化されて保存されることを確認する' do
      expect(result[:digest_is_bcrypt]).to be true
    end

    it 'authenticate メソッドの戻り値を確認する' do
      # 成功時は User オブジェクト、失敗時は false
      expect(result[:auth_success_returns_user]).to be true
      expect(result[:auth_failure_returns_false]).to be true
    end

    it 'パスワード確認の不一致でバリデーションエラーになることを確認する' do
      expect(result[:confirmation_mismatch]).to be true
    end
  end

  describe '.demonstrate_session_management' do
    let(:result) { described_class.demonstrate_session_management }

    it 'セッショントークンが十分な長さで生成されることを確認する' do
      expect(result[:login_success]).to be true
      expect(result[:token_is_string]).to be true
      # 256 ビットのトークンは Base64 で約 43 文字
      expect(result[:token_length]).to be >= 40
    end

    it 'セッションにクライアント情報が記録されることを確認する' do
      expect(result[:session_ip]).to eq '192.168.1.1'
      expect(result[:session_user_agent]).to eq 'Mozilla/5.0'
    end

    it 'トークンからセッションを復元できることを確認する' do
      expect(result[:session_resumed]).to be true
    end

    it '複数セッションの管理とログアウトを確認する' do
      expect(result[:multiple_sessions]).to be true
      expect(result[:logout_result]).to be true
    end
  end

  describe '.demonstrate_password_reset_flow' do
    let(:result) { described_class.demonstrate_password_reset_flow }

    it 'トークンがハッシュ化されて保存されることを確認する' do
      expect(result[:token_stored_as_hash]).to be true
    end

    it '有効なトークンでパスワードリセットが成功することを確認する' do
      expect(result[:valid_token_found]).to be true
      expect(result[:password_changed]).to be true
      expect(result[:new_password_works]).to be true
    end

    it '不正なトークンが拒否されることを確認する' do
      expect(result[:invalid_token_rejected]).to be true
    end

    it '使用済みトークンの再利用がブロックされることを確認する' do
      expect(result[:token_reuse_blocked]).to be true
    end

    it 'リセット後に古いパスワードが無効になることを確認する' do
      expect(result[:old_password_rejected]).to be true
    end
  end

  describe '.demonstrate_rate_limiting' do
    let(:result) { described_class.demonstrate_rate_limiting }

    it '初期状態ではアクセスが許可されることを確認する' do
      expect(result[:initially_allowed]).to be true
    end

    it '上限到達後にブロックされることを確認する' do
      expect(result[:blocked_after_limit]).to be true
    end

    it '別 IP からのアクセスは影響を受けないことを確認する' do
      expect(result[:other_ip_allowed]).to be true
    end

    it 'レート制限時にログインがエラーになることを確認する' do
      expect(result[:rate_limited_login]).to be true
      expect(result[:rate_limit_message]).to include('上限')
    end
  end

  describe '.demonstrate_remember_me' do
    let(:result) { described_class.demonstrate_remember_me }

    it 'Remember me トークンが生成されることを確認する' do
      expect(result[:token_generated]).to be true
      expect(result[:token_length]).to be >= 40
    end

    it 'トークンからユーザーを復元できることを確認する' do
      expect(result[:user_found]).to be true
    end

    it '不正なトークンが拒否されることを確認する' do
      expect(result[:invalid_rejected]).to be true
    end

    it 'トークンがハッシュ化されて保存され有効期限があることを確認する' do
      expect(result[:stored_as_hash]).to be true
      expect(result[:has_expiry]).to be true
      expect(result[:expiry_days]).to eq 14
    end
  end

  describe '.demonstrate_current_attributes' do
    let(:result) { described_class.demonstrate_current_attributes }

    it 'Current でリクエストスコープの情報にアクセスできることを確認する' do
      expect(result[:current_user_email]).to eq 'current@example.com'
      expect(result[:current_ip]).to eq '192.168.1.1'
      expect(result[:user_via_session]).to be true
    end

    it 'リセット後に Current の値がクリアされることを確認する' do
      expect(result[:after_reset_user]).to be true
      expect(result[:after_reset_session]).to be true
    end
  end

  describe '.demonstrate_timing_safe_comparison' do
    let(:result) { described_class.demonstrate_timing_safe_comparison }

    it 'secure_compare で正しい値が一致することを確認する' do
      expect(result[:secure_match]).to be true
    end

    it 'secure_compare で誤った値が不一致になることを確認する' do
      expect(result[:secure_mismatch]).to be true
    end

    it '長さが異なる値も安全に比較されることを確認する' do
      expect(result[:different_length_safe]).to be true
    end
  end

  describe '.demonstrate_devise_comparison' do
    let(:result) { described_class.demonstrate_devise_comparison }

    it 'Rails 8 組み込み認証の機能一覧を確認する' do
      expect(result[:builtin_features]).to include(:has_secure_password, :session_model)
    end

    it 'Devise の追加機能一覧を確認する' do
      expect(result[:devise_extra_features]).to include(:omniauthable, :confirmable, :lockable)
    end

    it '認証ジェネレータが生成するファイル一覧を確認する' do
      expect(result[:generated_files]).to include('app/models/user.rb', 'app/models/session.rb')
    end
  end
end
