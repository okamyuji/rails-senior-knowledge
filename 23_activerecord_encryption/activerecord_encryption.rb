# frozen_string_literal: true

# ActiveRecord Encryptionによる機密データの保護を解説するモジュール
#
# Rails 7以降、ActiveRecordにはアプリケーションレベルの暗号化機能が組み込まれている。
# これにより、データベースに格納される機密データ（メールアドレス、氏名、電話番号など）を
# 透過的に暗号化・復号できる。
#
# このモジュールでは、シニアRailsエンジニアが知るべき暗号化の仕組み、
# 鍵管理、決定的暗号化と非決定的暗号化の使い分け、GDPR対応パターンを学ぶ。

require 'active_record'

# --- インメモリSQLiteデータベースのセットアップ ---
ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:') unless ActiveRecord::Base.connected?
ActiveRecord::Base.logger = nil # テスト時のログ出力を抑制

# --- 暗号化の設定 ---
# ActiveRecord Encryptionは3つの鍵を使用する:
#   primary_key:       データ暗号化鍵（DEK）の暗号化に使用されるマスター鍵
#   deterministic_key: 決定的暗号化で使用される鍵（同じ入力→同じ暗号文）
#   key_derivation_salt: 鍵導出関数（PBKDF2）で使用されるソルト
# テスト用の鍵を動的生成する。本番環境では bin/rails db:encryption:init で
# 生成した鍵を credentials.yml.enc で管理すること。
ActiveRecord::Encryption.configure(
  primary_key: SecureRandom.hex(16),
  deterministic_key: SecureRandom.hex(16),
  key_derivation_salt: SecureRandom.hex(16)
)

# --- スキーマ定義 ---
ActiveRecord::Schema.define do
  create_table :encrypted_users, force: true do |t|
    t.string :name
    t.string :email
    t.string :phone_number
    t.string :ssn
    t.text :medical_notes
    t.timestamps null: false
  end

  create_table :encrypted_documents, force: true do |t|
    t.string :title
    t.text :content
    t.string :classification
    t.timestamps null: false
  end

  create_table :audit_logs, force: true do |t|
    t.string :action
    t.string :user_identifier
    t.text :details
    t.timestamps null: false
  end
end

# ==========================================================================
# モデル定義: 暗号化属性の宣言
# ==========================================================================

# --- 基本的な暗号化モデル ---
# encrypts メソッドで暗号化する属性を宣言する。
# デフォルトは非決定的暗号化（同じ入力でも毎回異なる暗号文を生成）。
class EncryptedUser < ActiveRecord::Base
  # emailは決定的暗号化: WHERE句での検索が可能
  # 決定的暗号化は同じ平文に対して常に同じ暗号文を生成する
  encrypts :email, deterministic: true

  # nameは決定的暗号化: ユーザー名での検索を可能にする
  encrypts :name, deterministic: true

  # phone_numberは非決定的暗号化（デフォルト）: より強固なセキュリティ
  # 同じ電話番号でも暗号化するたびに異なる暗号文が生成される
  encrypts :phone_number

  # ssnは非決定的暗号化: 社会保障番号のような高機密データ
  encrypts :ssn

  # medical_notesは非決定的暗号化: テキストフィールドも暗号化可能
  encrypts :medical_notes
end

# --- ドキュメント分類モデル ---
class EncryptedDocument < ActiveRecord::Base
  encrypts :content
  encrypts :classification, deterministic: true
end

# --- 監査ログモデル ---
class AuditLog < ActiveRecord::Base
  encrypts :user_identifier, deterministic: true
  encrypts :details
end

module ActiveRecordEncryption
  module_function

  # ==========================================================================
  # 1. encrypts属性: 透過的な暗号化と復号
  # ==========================================================================
  #
  # encrypts宣言された属性は、データベースへの書き込み時に自動的に暗号化され、
  # 読み出し時に自動的に復号される。アプリケーションコードからは
  # 暗号化の存在を意識する必要がない（透過的暗号化）。
  #
  # 内部的には、ActiveRecord::Encryption::EncryptedAttributeType が
  # ActiveModel::Type として属性にバインドされ、cast/serialize/deserialize
  # のフックで暗号化・復号を行う。
  def demonstrate_transparent_encryption
    EncryptedUser.delete_all

    # 通常通りレコードを作成 — 暗号化は透過的に行われる
    user = EncryptedUser.create!(
      name: '田中太郎',
      email: 'tanaka@example.com',
      phone_number: '090-1234-5678',
      ssn: '123-45-6789',
      medical_notes: '花粉症の既往歴あり'
    )

    # アプリケーション層では復号された値が返る
    decrypted_name = user.name
    decrypted_email = user.email

    # データベースに格納されている実際の値（暗号文）を確認
    # ActiveRecord::Base.connectionで生SQLを実行すると暗号文が見える
    raw_row = ActiveRecord::Base.connection.select_one(
      'SELECT name, email, phone_number FROM encrypted_users WHERE id = ?', nil, [user.id]
    )

    # 暗号文はJSON形式のエンベロープに包まれている
    # {"p":"暗号文","h":{"iv":"初期化ベクトル","at":"認証タグ",...}}
    raw_name = raw_row['name']
    raw_email = raw_row['email']

    {
      # アプリケーション層では平文が返る
      decrypted_name: decrypted_name,
      decrypted_email: decrypted_email,
      # データベースには暗号文が格納されている
      raw_name_encrypted: raw_name != '田中太郎',
      raw_email_encrypted: raw_email != 'tanaka@example.com',
      # 暗号文はJSON形式のエンベロープ
      raw_name_is_envelope: raw_name&.include?('{') == true,
      # リロードしても正しく復号される
      reloaded_name: user.reload.name,
      reloaded_email: user.reload.email
    }
  end

  # ==========================================================================
  # 2. 決定的暗号化 vs 非決定的暗号化
  # ==========================================================================
  #
  # ActiveRecord Encryptionは2つの暗号化モードを提供する:
  #
  # 【決定的暗号化（Deterministic Encryption）】
  # - 同じ平文 + 同じ鍵 → 常に同じ暗号文
  # - WHERE句でのクエリが可能（暗号文同士を比較できるため）
  # - AES-256-GCMを固定IVで使用
  # - 注意: 同じ暗号文パターンから頻度分析が可能なため、セキュリティは劣る
  #
  # 【非決定的暗号化（Non-deterministic / Randomized Encryption）】
  # - 同じ平文でも毎回異なる暗号文（ランダムIVを使用）
  # - WHERE句でのクエリは不可能
  # - AES-256-GCMをランダムIVで使用
  # - より強固なセキュリティ（頻度分析が不可能）
  def demonstrate_deterministic_vs_nondeterministic
    EncryptedUser.delete_all

    # 同じデータで2つのレコードを作成
    user1 = EncryptedUser.create!(
      name: '山田花子',
      email: 'yamada@example.com',
      phone_number: '090-1111-2222',
      ssn: '111-22-3333',
      medical_notes: 'なし'
    )
    user2 = EncryptedUser.create!(
      name: '山田花子',
      email: 'yamada@example.com',
      phone_number: '090-1111-2222',
      ssn: '111-22-3333',
      medical_notes: 'なし'
    )

    # 生の暗号文を取得
    raw1 = ActiveRecord::Base.connection.select_one(
      'SELECT email, phone_number FROM encrypted_users WHERE id = ?', nil, [user1.id]
    )
    raw2 = ActiveRecord::Base.connection.select_one(
      'SELECT email, phone_number FROM encrypted_users WHERE id = ?', nil, [user2.id]
    )

    # 決定的暗号化: 同じ平文なら同じ暗号文
    email_ciphertexts_match = raw1['email'] == raw2['email']

    # 非決定的暗号化: 同じ平文でも異なる暗号文
    phone_ciphertexts_match = raw1['phone_number'] == raw2['phone_number']

    {
      # 決定的暗号化（email）: 同じ平文 → 同じ暗号文
      deterministic_same_ciphertext: email_ciphertexts_match,
      # 非決定的暗号化（phone_number）: 同じ平文 → 異なる暗号文
      nondeterministic_different_ciphertext: !phone_ciphertexts_match,
      # どちらも復号すると同じ平文に戻る
      both_decrypt_to_same_email: user1.email == user2.email,
      both_decrypt_to_same_phone: user1.phone_number == user2.phone_number
    }
  end

  # ==========================================================================
  # 3. 鍵導出とエンベロープ暗号化
  # ==========================================================================
  #
  # ActiveRecord Encryptionはエンベロープ暗号化パターンを採用している:
  #
  # 【エンベロープ暗号化の仕組み】
  # 1. データ暗号化鍵（DEK: Data Encryption Key）がランダムに生成される
  # 2. DEKでデータ（平文）を暗号化する
  # 3. マスター鍵（KEK: Key Encryption Key）でDEKを暗号化する
  # 4. 暗号化されたデータと暗号化されたDEKを一緒に保存する
  #
  # 【鍵導出】
  # primary_keyとkey_derivation_saltからPBKDF2で実際の暗号化鍵を導出する。
  # これにより、設定ファイルの鍵が直接暗号化に使われることはない。
  #
  # 【利点】
  # - マスター鍵のローテーションが容易（DEKを再暗号化するだけ）
  # - データの再暗号化が不要
  # - 鍵の階層管理が可能
  def demonstrate_key_derivation_and_envelope
    # 暗号化設定の確認
    ActiveRecord::Encryption.config

    # 鍵プロバイダーの構造を確認
    # DerivedSecretKeyProviderはprimary_keyとsaltからPBKDF2で鍵を導出する
    key_provider_class = ActiveRecord::Encryption.key_provider.class.name

    # エンベロープの構造を確認するためにレコードを作成
    EncryptedUser.delete_all
    user = EncryptedUser.create!(
      name: '鍵テスト',
      email: 'key-test@example.com',
      phone_number: '000-0000-0000',
      ssn: '000-00-0000',
      medical_notes: 'テスト'
    )

    # 暗号文のエンベロープ構造を確認
    raw = ActiveRecord::Base.connection.select_one(
      'SELECT phone_number FROM encrypted_users WHERE id = ?', nil, [user.id]
    )
    raw_ciphertext = raw['phone_number']

    # エンベロープをパース（JSON形式）
    envelope = begin
      JSON.parse(raw_ciphertext)
    rescue StandardError
      nil
    end

    # エンベロープの構造:
    # "p"  = payload（暗号化されたデータ）
    # "h"  = headers（メタデータ）
    #   "iv" = 初期化ベクトル
    #   "at" = 認証タグ（GCMモードの認証タグ）
    #   "k"  = 暗号化されたDEK（エンベロープ暗号化の場合）

    {
      key_provider_class: key_provider_class,
      # エンベロープが正しい構造を持つ
      has_envelope_structure: !envelope.nil?,
      has_payload: envelope&.key?('p'),
      has_headers: envelope&.key?('h'),
      # ヘッダーに初期化ベクトルが含まれる
      has_iv: !envelope&.dig('h', 'iv').nil?,
      # ヘッダーに認証タグが含まれる
      has_auth_tag: !envelope&.dig('h', 'at').nil?,
      # 概念図
      envelope_concept: '平文 → DEK暗号化 → [暗号文 + 暗号化DEK]を保存'
    }
  end

  # ==========================================================================
  # 4. 暗号化データのクエリ（決定的暗号化）
  # ==========================================================================
  #
  # 決定的暗号化（deterministic: true）を使用した属性は、
  # 通常のActiveRecordクエリメソッド（where, find_by等）で検索できる。
  #
  # 内部的には、クエリの引数を同じ鍵で暗号化してから
  # データベースのWHERE句に渡すことで、暗号文同士の比較を行う。
  #
  # 非決定的暗号化の属性では、同じ平文でも暗号文が異なるため
  # WHERE句での検索はできない。
  def demonstrate_querying_encrypted_data
    EncryptedUser.delete_all

    # テストデータの作成
    EncryptedUser.create!(
      name: '佐藤一郎', email: 'sato@example.com',
      phone_number: '090-1111-1111', ssn: '111-11-1111', medical_notes: 'なし'
    )
    EncryptedUser.create!(
      name: '鈴木二郎', email: 'suzuki@example.com',
      phone_number: '090-2222-2222', ssn: '222-22-2222', medical_notes: 'なし'
    )
    EncryptedUser.create!(
      name: '佐藤花子', email: 'sato-h@example.com',
      phone_number: '090-3333-3333', ssn: '333-33-3333', medical_notes: 'なし'
    )

    # === 決定的暗号化属性への検索（成功） ===
    # emailは決定的暗号化なので、where/find_byで検索可能
    found_by_email = EncryptedUser.find_by(email: 'sato@example.com')
    where_by_name = EncryptedUser.where(name: '佐藤一郎')

    # === 非決定的暗号化属性への検索 ===
    # phone_numberは非決定的暗号化なので、クエリでマッチしない。
    # 同じ平文でも暗号文が異なるため、WHERE句の暗号文比較が一致せずnilが返る。
    # これはエラーではなく「見つからない」という結果になる点に注意。
    phone_query_result = EncryptedUser.find_by(phone_number: '090-1111-1111')

    {
      # 決定的暗号化: 正常に検索できる
      found_by_email_name: found_by_email&.name,
      where_by_name_count: where_by_name.count,
      where_by_name_email: where_by_name.first&.email,
      # 非決定的暗号化: 検索してもマッチせずnilが返る
      phone_query_returns_nil: phone_query_result.nil?,
      # 全件取得して復号は可能
      total_users: EncryptedUser.count,
      all_emails: EncryptedUser.order(:id).pluck(:email)
    }
  end

  # ==========================================================================
  # 5. 鍵ローテーション
  # ==========================================================================
  #
  # 暗号化鍵の定期的なローテーションはセキュリティのベストプラクティスである。
  # ActiveRecord Encryptionは、previous_keysオプションを使って
  # 古い鍵でも復号できるようにしつつ、新しい鍵で暗号化する仕組みを持つ。
  #
  # 鍵ローテーションの手順:
  # 1. 新しいprimary_keyを設定に追加
  # 2. 古いprimary_keyをprevious_keysに移動
  # 3. 新しいレコードは新しい鍵で暗号化される
  # 4. 古いレコードは読み取り時に古い鍵で復号される
  # 5. 必要に応じてバッチ処理で古いレコードを再暗号化
  #
  # ActiveRecord::Encryption.config.previous[...] に古い鍵セットを追加することで
  # 複数世代の鍵をサポートできる。
  def demonstrate_key_rotation_concept
    EncryptedUser.delete_all

    # 現在の鍵でレコードを作成
    user = EncryptedUser.create!(
      name: '鍵ローテーションテスト',
      email: 'rotation@example.com',
      phone_number: '090-9999-9999',
      ssn: '999-99-9999',
      medical_notes: 'ローテーション前のデータ'
    )

    # 現在の暗号文を保存
    original_raw = ActiveRecord::Base.connection.select_one(
      'SELECT email FROM encrypted_users WHERE id = ?', nil, [user.id]
    )
    original_ciphertext = original_raw['email']

    # レコードを更新すると新しい暗号文が生成される
    user.update!(email: 'rotation@example.com') # 同じ値で更新
    updated_raw = ActiveRecord::Base.connection.select_one(
      'SELECT email FROM encrypted_users WHERE id = ?', nil, [user.id]
    )
    updated_ciphertext = updated_raw['email']

    # 決定的暗号化なので同じ値は同じ暗号文になる
    ciphertext_unchanged = original_ciphertext == updated_ciphertext

    # 鍵ローテーションの概念的なフロー
    rotation_steps = [
      '1. credentials.ymlに新しいprimary_keyを設定',
      '2. 古いprimary_keyをprevious配列に追加',
      '3. デプロイ後、新しいレコードは新しい鍵で暗号化',
      '4. 古いレコードは読み取り時に旧鍵で自動復号',
      '5. rake db:encryption:rotate で全レコードを再暗号化'
    ]

    {
      # 決定的暗号化: 同じ値を再暗号化しても同じ暗号文
      deterministic_ciphertext_stable: ciphertext_unchanged,
      # 復号は正常に行える
      decrypted_email: user.reload.email,
      # ローテーション手順
      rotation_steps: rotation_steps,
      # 概念: previous_keysの使い方
      config_example: {
        primary_key: '新しいマスター鍵',
        previous: [
          { primary_key: '古いマスター鍵（第1世代）' },
          { primary_key: 'さらに古いマスター鍵（第0世代）' }
        ]
      }
    }
  end

  # ==========================================================================
  # 6. GDPR対応: 暗号化による「忘れられる権利」
  # ==========================================================================
  #
  # GDPRの「忘れられる権利」（Right to Erasure, 第17条）への対応として、
  # 暗号化は強力なツールとなる。
  #
  # 【暗号鍵削除による論理的データ消去】
  # ユーザーごとに固有の暗号化鍵を使用し、データ削除要求時に
  # 鍵を破棄することで、データを復号不可能にする（暗号学的消去）。
  # これにより、物理的なデータ削除が困難なバックアップ等でも
  # 実質的にデータを「忘れる」ことができる。
  #
  # 【データ最小化パターン】
  # 必要最小限のデータのみを保持し、不要になったデータは
  # 暗号化された状態で鍵を破棄するパターン。
  def demonstrate_gdpr_compliance
    EncryptedUser.delete_all
    AuditLog.delete_all

    # GDPRの「忘れられる権利」対応パターン

    # パターン1: レコード自体の削除
    user = EncryptedUser.create!(
      name: '削除対象ユーザー',
      email: 'delete-me@example.com',
      phone_number: '090-0000-0000',
      ssn: '000-00-0000',
      medical_notes: '削除対象の医療メモ'
    )

    user_id = user.id
    user.destroy!
    deleted_user = EncryptedUser.find_by(id: user_id)

    # パターン2: 選択的なデータ消去（個人情報のみNULL化）
    user2 = EncryptedUser.create!(
      name: '匿名化対象ユーザー',
      email: 'anonymize@example.com',
      phone_number: '090-5555-5555',
      ssn: '555-55-5555',
      medical_notes: '匿名化対象'
    )

    # 個人識別情報（PII）のみを消去し、統計データとしてレコードを残す
    user2.update!(
      name: '匿名ユーザー',
      email: "anonymous-#{user2.id}@deleted.local",
      phone_number: nil,
      ssn: nil,
      medical_notes: nil
    )

    # パターン3: 監査ログの暗号化
    # GDPRでは処理活動の記録が求められるが、個人情報は保護する必要がある
    AuditLog.create!(
      action: 'data_deletion_request',
      user_identifier: 'anonymize@example.com',
      details: 'ユーザーからのデータ削除要求を処理。PIIをNULL化。'
    )

    audit = AuditLog.first

    {
      # パターン1: レコード削除
      record_deleted: deleted_user.nil?,
      # パターン2: 匿名化
      anonymized_name: user2.reload.name,
      anonymized_email_pattern: user2.email.match?(/anonymous-\d+@deleted\.local/),
      anonymized_phone: user2.phone_number.nil?,
      anonymized_ssn: user2.ssn.nil?,
      # パターン3: 監査ログ（暗号化されて保存）
      audit_action: audit.action,
      audit_encrypted: begin
        raw = ActiveRecord::Base.connection.select_one(
          'SELECT details FROM audit_logs WHERE id = ?', nil, [audit.id]
        )
        raw['details'] != 'ユーザーからのデータ削除要求を処理。PIIをNULL化。'
      end,
      # GDPR対応の概念
      gdpr_patterns: [
        '完全削除: destroy! でレコードごと削除',
        '匿名化: PIIのみNULL化して統計データは残す',
        '暗号学的消去: ユーザー固有の鍵を破棄して復号不可能にする',
        'データ最小化: 不要な個人情報を定期的にパージ'
      ]
    }
  end

  # ==========================================================================
  # 7. カスタム暗号化器
  # ==========================================================================
  #
  # ActiveRecord::Encryption::Encryptorのインターフェースに従うことで、
  # カスタムの暗号化スキームを実装できる。
  #
  # ユースケース:
  # - 外部KMS（AWS KMS, Google Cloud KMSなど）との統合
  # - 特定のコンプライアンス要件に対応した暗号化方式
  # - データ形式を保持する暗号化（Format-Preserving Encryption）
  # - 検索可能な暗号化スキーム
  def demonstrate_custom_encryptor_concept
    # カスタムEncryptorの概念的な例
    # 実際のカスタムEncryptorはActiveRecord::Encryption::Encryptorの
    # encrypt/decryptインターフェースを実装する

    custom_encryptor_example = <<~RUBY
      class KmsEncryptor
        # AWS KMSと統合するカスタム暗号化器の例
        def encrypt(clear_text, key_provider: nil, cipher_options: {})
          # 1. AWS KMSからデータキーを生成
          # 2. データキーで平文を暗号化
          # 3. 暗号化されたデータキーと暗号文を返す
          ActiveRecord::Encryption::Message.new(
            payload: encrypted_data,
            headers: { iv: iv, at: auth_tag, kms_key_id: key_id }
          )
        end

        def decrypt(encrypted_message, key_provider: nil, cipher_options: {})
          # 1. ヘッダーからKMS鍵IDを取得
          # 2. AWS KMSで暗号化されたデータキーを復号
          # 3. データキーで暗号文を復号
          clear_text
        end
      end

      class SecureDocument < ApplicationRecord
        encrypts :content, encryptor: KmsEncryptor.new
      end
    RUBY

    # モデルでencrypts宣言に利用可能なオプション
    encrypts_options = {
      deterministic: '決定的暗号化を有効にする（デフォルトはfalse）',
      downcase: '暗号化前に小文字に変換する（大文字小文字を無視した検索用）',
      ignore_case: '大文字小文字を無視する（内部的にdowncaseを使用）',
      previous: '以前の暗号化設定（鍵ローテーション用）'
    }

    {
      custom_encryptor_example: custom_encryptor_example,
      encrypts_options: encrypts_options,
      # 標準のEncryptorクラス
      default_encryptor_class: ActiveRecord::Encryption::Encryptor.name,
      # 暗号化メッセージの構造
      message_class: ActiveRecord::Encryption::Message.name
    }
  end

  # ==========================================================================
  # 8. 暗号化の実践的な設定パターン
  # ==========================================================================
  #
  # 本番環境での暗号化設定のベストプラクティス:
  # - Rails credentials（rails credentials:edit）で鍵を管理
  # - 環境変数からの鍵読み込み
  # - マルチテナント環境での鍵分離
  # - CI/テスト環境での設定
  def demonstrate_practical_configuration
    # Rails credentialsでの設定例
    credentials_example = <<~YAML
      # config/credentials.yml.enc の内容（復号後）
      # 鍵は bin/rails db:encryption:init で生成する
      active_record_encryption:
        primary_key: "<bin/rails db:encryption:init で生成>"
        deterministic_key: "<bin/rails db:encryption:init で生成>"
        key_derivation_salt: "<bin/rails db:encryption:init で生成>"
    YAML

    # 環境変数からの読み込みパターン
    env_config_example = <<~RUBY
      # config/application.rb
      config.active_record.encryption.primary_key =
        ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"]
      config.active_record.encryption.deterministic_key =
        ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"]
      config.active_record.encryption.key_derivation_salt =
        ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"]
    RUBY

    # 鍵ローテーション時の設定例
    rotation_config_example = <<~YAML
      active_record_encryption:
        primary_key: "新しいマスター鍵-世代2"
        deterministic_key: "新しい決定的鍵-世代2"
        key_derivation_salt: "ソルトは変更しない"
        previous:
          - primary_key: "旧マスター鍵-世代1"
            deterministic_key: "旧決定的鍵-世代1"
    YAML

    {
      credentials_example: credentials_example,
      env_config_example: env_config_example,
      rotation_config_example: rotation_config_example,
      # 鍵生成コマンド
      key_generation_command: 'bin/rails db:encryption:init',
      # 設定の確認
      encryption_configured: ActiveRecord::Encryption.config.primary_key.present?,
      # セキュリティのベストプラクティス
      best_practices: [
        '鍵はcredentials.yml.encまたは環境変数で管理する',
        '鍵をソースコードにハードコードしない',
        '本番・ステージング・開発で異なる鍵を使用する',
        '鍵のローテーションは定期的に行う（90日推奨）',
        'バックアップからの復元テストを定期的に実施する',
        '鍵のアクセス権限を最小限に制限する'
      ]
    }
  end
end
