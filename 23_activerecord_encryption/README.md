# ActiveRecord Encryption

## なぜActiveRecord Encryptionの理解が重要か

Rails 7で導入されたActiveRecord
Encryptionは、アプリケーションレベルでデータベースの機密データを透過的に暗号化する仕組みです。個人情報保護法やGDPRなどの法規制への対応、
セキュリティインシデント時のデータ保護において不可欠な機能です。

シニアエンジニアがこの仕組みを深く理解すべき理由は以下の通りです。

- 法規制への準拠: GDPR、個人情報保護法、PCI DSSなどの規制が求めるデータ保護要件を満たすための基盤技術です
- インシデント対応: データベースが漏洩した場合でも、暗号化されたデータは平文で読めないため被害を最小限に抑えられます
- 設計判断: 決定的暗号化と非決定的暗号化の使い分け、パフォーマンスとのトレードオフなど、アーキテクチャレベルの判断が必要です
- 運用: 鍵管理、鍵ローテーション、バックアップからの復元など、運用面での理解が欠かせません

## ActiveRecord Encryptionの仕組み

### 基本的な使い方

`encrypts`メソッドをモデルに宣言するだけで、指定した属性が透過的に暗号化されます。

```ruby

class User < ApplicationRecord
  # emailは決定的暗号化（検索可能）
  encrypts :email, deterministic: true

  # phone_numberは非決定的暗号化（より安全）
  encrypts :phone_number

  # ssnは非決定的暗号化（高機密データ）
  encrypts :ssn
end

# 通常通りCRUD操作が可能です（暗号化は透過的）

user = User.create!(email: "test@example.com", phone_number: "090-1234-5678")
user.email  # => "test@example.com"（復号された値）

```

### 内部アーキテクチャ

ActiveRecord Encryptionは以下のコンポーネントで構成されています。

```text

Application Layer
     |
     v
ActiveRecord::Encryption::EncryptedAttributeType
  (ActiveModel::Typeとしてcast/serialize/deserializeをフック)
     |
     v
ActiveRecord::Encryption::Encryptor
  (暗号化・復号のコア実装)
     |
     v
ActiveRecord::Encryption::Cipher::Aes256Gcm
  (AES-256-GCM暗号化エンジン)
     |
     v
ActiveRecord::Encryption::KeyProvider
  (鍵の取得・管理)
     |
     v
Database (暗号文が格納される)

```

## 鍵導出とエンベロープ暗号化

### 3つの鍵の役割

ActiveRecord Encryptionは以下の3つの鍵を設定で管理します。

| 鍵 | 用途 | 設定キー
| ---- | ------ | ---------
| プライマリキー | データ暗号化鍵（DEK）の暗号化に使用します | `primary_key`
| 決定的キー | 決定的暗号化で使用される鍵です | `deterministic_key`
| 鍵導出ソルト | PBKDF2による鍵導出に使用します | `key_derivation_salt`

### デフォルトの鍵導出（DerivedSecretKeyProvider）

ActiveRecord Encryptionのデフォルトの`KeyProvider`は`DerivedSecretKeyProvider`で、設定された`primary_key`と`key_derivation_salt`からPBKDF2で派生鍵を生成し、その派生鍵で直接データを暗号化します（レコードごとのDEK生成は行いません）。

### オプション: エンベロープ暗号化（EnvelopeEncryptionKeyProvider）

`ActiveRecord::Encryption::EnvelopeEncryptionKeyProvider`を明示的に設定すると、真のエンベロープ暗号化（暗号化鍵自体を別の鍵で暗号化する二層構造）が利用できます。これはデフォルトではありません。

```text

1. ランダムなデータ暗号化鍵（DEK）を生成します
2. DEKで平文データを暗号化して暗号文を得ます
3. マスター鍵（KEK）でDEKを暗号化して暗号化DEKを得ます
4. [暗号文 + 暗号化DEK + メタデータ]をデータベースに保存します

```

エンベロープ暗号化を採用するメリットは以下の通りです。

- 鍵ローテーションが容易です: マスター鍵を変更する際、データの再暗号化が不要です（DEKの再暗号化のみ）
- 鍵の階層管理が可能です: マスター鍵をHSMやKMSで管理し、DEKはアプリケーション側で管理できます
- 高速な暗号化を実現します: 大量のデータを暗号化する際も、対称鍵暗号で高速に処理できます

### 暗号文のJSONエンベロープ構造

データベースに格納される暗号文は、鍵導出方式に関わらずJSON形式のエンベロープに包まれています。なおこの「エンベロープ」はデータ構造の名称で、上述のエンベロープ暗号化（KEK/DEKパターン）とは別概念です。

```json

{
  "p": "Base64エンコードされた暗号文",
  "h": {
    "iv": "Base64エンコードされた初期化ベクトル",
    "at": "Base64エンコードされた認証タグ（GCM）",
    "k": "Base64エンコードされた暗号化DEK（エンベロープ使用時）"
  }
}

```

### PBKDF2による鍵導出

設定ファイルのプライマリキーとソルトから、実際の暗号化鍵をPBKDF2で導出します。

```text

実際の暗号化鍵 = PBKDF2(password=primary_key, salt=key_derivation_salt, iterations=2^16, length=32)

```

これにより、設定ファイルの鍵が直接暗号化に使われることはなく、鍵の強度が保証されます。

## 決定的暗号化と非決定的暗号化の使い分け

### 決定的暗号化（Deterministic Encryption）

```ruby

encrypts :email, deterministic: true

```

- 同じ平文からは常に同じ暗号文が生成されます（IVは平文と鍵から決定的に導出されるHMAC-SHA256ベース）
- WHERE句でのクエリが可能です
- `find_by`, `where`で検索できます
- 頻度分析に脆弱です（同じ暗号文パターンから推測される可能性があります）

適用すべき場面は以下の通りです。

- ログイン時のメールアドレス照合
- ユニーク制約が必要な属性
- 検索条件として使用される属性

### 非決定的暗号化（Non-deterministic / Randomized Encryption）

```ruby

encrypts :ssn  # デフォルトは非決定的

```

- 同じ平文でも毎回異なる暗号文が生成されます（ランダムIVを使用）
- WHERE句でのクエリはできません
- より強固なセキュリティを提供します（頻度分析が不可能）

適用すべき場面は以下の通りです。

- 社会保障番号、マイナンバーなどの高機密データ
- 検索する必要のない個人情報
- 医療情報、金融情報

### 使い分けの判断基準

```text

検索が必要か？ ─── Yes ──→ 決定的暗号化（deterministic: true）
       |
       No
       |
       v
非決定的暗号化（デフォルト）── より安全

```

注意事項は以下の通りです。

- 決定的暗号化ではLIKE検索やパーシャルマッチはできません（完全一致のみ）
- 大文字小文字を無視した検索には`ignore_case: true`オプションを使用します
- 決定的暗号化の属性には頻度分析のリスクがあることを認識してください

## GDPR対応

### 「忘れられる権利」への対応パターン

GDPRの第17条「忘れられる権利（Right to Erasure）」に対して、暗号化は3つの対応パターンを提供します。

#### パターン1: 物理削除

```ruby

user.destroy!  # レコード自体を削除します

```

最もシンプルですが、バックアップやレプリカにデータが残る可能性があります。

#### パターン2: 匿名化（Pseudonymization）

```ruby

user.update!(
  name: "匿名ユーザー",
  email: "anonymous-#{user.id}@deleted.local",
  phone_number: nil,
  ssn: nil
)

```

統計データとしてレコードを残しつつ、個人を特定できない状態にします。

#### パターン3: 暗号学的消去（Crypto-shredding）

ActiveRecord Encryptionのデフォルト構成（`DerivedSecretKeyProvider`）では、`primary_key` と `key_derivation_salt` から全レコード共通の鍵が導出されるため、**ユーザーごとに独立した鍵は存在しません**。暗号学的消去を実装するには、独自の `KeyProvider` を実装してユーザーIDごとに鍵を分離する必要があります。

```ruby

# 例: ユーザー単位の KeyProvider を定義し、ユーザー削除時に鍵レコードを破棄する
class PerUserKeyProvider
  def encryption_key
    # 現在のユーザーの鍵を返す（contextからuser_idを取得する設計）
    key = UserEncryptionKey.find_by!(user_id: ActiveRecord::Encryption.context.user_id)
    ActiveRecord::Encryption::Key.new(key.secret)
  end

  def decryption_keys(encrypted_message)
    [encryption_key]
  end
end

# ユーザー削除時に鍵レコードのみを物理削除する
class User < ApplicationRecord
  has_one :encryption_key_record, class_name: "UserEncryptionKey", dependent: :destroy
end

# user.destroy → UserEncryptionKey が削除され、バックアップ中の暗号文も復号不可能になる

```

鍵レコードを物理削除すれば、バックアップにデータが残っていても復号できないため、実質的にデータが「忘れられた」状態になります。設定例の詳細は[Active Record Encryption Guide #setting-up-custom-key-providers](https://guides.rubyonrails.org/active_record_encryption.html#setting-up-custom-key-providers) を参照してください。

### データ最小化の実装

```ruby

class User < ApplicationRecord
  encrypts :email, deterministic: true
  encrypts :phone_number
  encrypts :ssn

  # 一定期間後にPIIを自動パージします
  scope :pii_expired, -> { where("created_at < ?", 2.years.ago) }

  def purge_pii!
    update!(phone_number: nil, ssn: nil, medical_notes: nil)
  end
end

# 定期バッチでPIIをパージします

User.pii_expired.find_each(&:purge_pii!)

```

## 暗号化設定のベストプラクティス

### 鍵の生成

```bash

# Railsが提供する鍵生成コマンド

bin/rails db:encryption:init

```

### credentials.yml.encでの管理

```yaml

# rails credentials:editで編集します

active_record_encryption:
  primary_key: "EGY8WhulUOXixybod7ZWwMIL68R9o5kC"
  deterministic_key: "aPA5XyALhf75NNnMzaspW7akTfZp0lPY"
  key_derivation_salt: "xEY0dt6TZcAMg52K7O84wYzkjvbA62Hz"

```

### 鍵ローテーション

```yaml

active_record_encryption:
  primary_key: "新しいマスター鍵-世代2"
  deterministic_key: "新しい決定的鍵-世代2"
  key_derivation_salt: "ソルトは変更しない"
  previous:

    - primary_key: "旧マスター鍵-世代1"

      deterministic_key: "旧決定的鍵-世代1"

```

ActiveRecord Encryptionは復号時に `previous` を含むすべての鍵を順に試すため、設定を更新するだけで段階的な移行が可能です（**非決定的暗号化のみローテーション可能**。決定的暗号化はインデックス互換性のためローテーションできません）。

ローテーション後の再暗号化には、Rails標準のRakeタスクは存在しません。バッチで明示的に再暗号化する必要があります。

```ruby

# lib/tasks/encryption.rake などに定義
namespace :app do
  task reencrypt_users: :environment do
    User.find_each do |user|
      # Active Record Encryption は属性に値を再代入すると最新の primary_key で
      # 再暗号化されるため、ダミー代入で全レコードを書き直す。
      user.update_columns(
        name: user.name,
        phone_number: user.phone_number
      )
    end
  end
end

```

旧鍵を `previous` から削除できるのは、すべての暗号化済みレコードを新鍵で書き直し終えた後です。

### セキュリティチェックリスト

- [ ] 鍵はcredentials.yml.encまたは環境変数で管理されていますか
- [ ] 本番・ステージング・開発で異なる鍵を使用していますか
- [ ] 鍵のローテーション計画がありますか（90日ごと推奨）
- [ ] バックアップからの復元テストを実施していますか
- [ ] 鍵へのアクセス権限が最小限に制限されていますか
- [ ] 決定的暗号化と非決定的暗号化を適切に使い分けていますか

## パフォーマンスへの影響

### 暗号化・復号のオーバーヘッド

- 各レコードの読み書きに暗号化・復号の処理時間が加わります
- AES-256-GCMはハードウェア支援（AES-NI）があれば高速です
- 大量のレコードをバッチ処理する場合は影響が顕著になります

### インデックスへの影響

- 決定的暗号化の属性にはインデックスを作成できますが、暗号文に対するインデックスとなります
- LIKE検索や範囲検索ではインデックスが効きません
- 部分一致検索が必要な場合は、暗号化以外のアプローチ（トークン化など）を検討してください

### 推奨事項

```ruby

# 暗号化が不要な属性まで暗号化しないでください（パフォーマンスとのトレードオフ）

class User < ApplicationRecord
  encrypts :email, deterministic: true  # 検索が必要なPII
  encrypts :ssn                         # 高機密データ
  # name, ageなどは暗号化しません      # パフォーマンス優先
end

```

## 実行方法

```bash

# テストの実行

bundle exec rspec 23_activerecord_encryption/activerecord_encryption_spec.rb

# 個別のメソッドを試す

ruby -r ./23_activerecord_encryption/activerecord_encryption -e "pp ActiveRecordEncryption.demonstrate_transparent_encryption"

```
