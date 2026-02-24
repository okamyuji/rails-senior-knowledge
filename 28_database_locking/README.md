# データベースロック戦略

## なぜデータベースロックの理解が重要か

マルチユーザー環境のWebアプリケーションでは、同一レコードに対する同時アクセスが日常的に発生します。適切なロック戦略を選択しないと、以下のような深刻な問題が起きます。

- lost update（更新の消失）: 2つのトランザクションが同時に同じレコードを読み取り・更新すると、一方の更新が消失します
- データ不整合: 口座残高がマイナスになる、在庫が負の値になるなどの問題が起きます
- デッドロック: 2つのトランザクションが互いのロック解放を待ち続け、永遠にブロックされます

シニアエンジニアは、これらの問題を理解し、アプリケーションの特性に応じた適切なロック戦略を選択できなければなりません。

## 楽観的ロック（Optimistic Locking）の仕組み

### 楽観的ロックの基本概念

楽観的ロックは「ほとんどの場合、同時更新の競合は
起きない」という前提に基づく戦略です。
データ読み取り時にはロックを取得せず、更新時に
バージョン番号を検証することで競合を検出します。

### 楽観的ロックのActiveRecord実装

テーブルに`lock_version`カラム（integer、デフォルト0）を追加するだけで自動的に有効になります。

```ruby

# マイグレーション

class AddLockVersionToAccounts < ActiveRecord::Migration[8.0]
  def change
    add_column :accounts, :lock_version, :integer, default: 0, null: false
  end
end

```

ActiveRecordが生成するSQLは以下のようになります。

```sql

-- 更新時にlock_versionを検証し、同時にインクリメントします
UPDATE accounts
SET balance = 900, lock_version = 1
WHERE id = 1 AND lock_version = 0;

```

`WHERE lock_version =
0`が一致しない場合（他のトランザクションが先に更新した場合）、更新行数が0となり、`ActiveRecord::StaleObjectError`が発生します。

### 競合発生時の流れ

```sql

ユーザーA: Account.find(1)  → balance: 1000, lock_version: 0
ユーザーB: Account.find(1)  → balance: 1000, lock_version: 0

ユーザーA: account.update!(balance: 900)
  → UPDATE ... SET balance=900, lock_version=1 WHERE id=1 AND lock_version=0
  → 成功します（1行更新）

ユーザーB: account.update!(balance: 800)
  → UPDATE ... SET balance=800, lock_version=1 WHERE id=1 AND lock_version=0
  → 失敗します（0行更新）→ StaleObjectErrorが発生します

```

## 悲観的ロック（Pessimistic Locking）の仕組み

### 悲観的ロックの基本概念

悲観的ロックは「同時更新の競合が頻繁に起きる」という
前提に基づく戦略です。データを読み取る時点で排他ロック
を取得し、トランザクション終了まで他のトランザクション
をブロックします。

### 悲観的ロックのActiveRecord実装

```ruby

# with_lock: トランザクション + SELECT FOR UPDATEを一括で行います（推奨）

account.with_lock do
  account.balance -= 100
  account.save!
end

# lock!: 既存トランザクション内でロックを取得します

Account.transaction do
  account = Account.lock.find(1)  # SELECT ... FOR UPDATE
  account.balance -= 100
  account.save!
end

# NOWAIT: ロック取得できない場合は即座にエラーを返します

Account.lock("FOR UPDATE NOWAIT").find(1)

# SKIP LOCKED: ロック済みレコードをスキップします（キューパターンで有用）

Account.lock("FOR UPDATE SKIP LOCKED").where(status: "pending").first

```

### SELECT FOR UPDATEの動作

```sql

-- トランザクションA
BEGIN;
SELECT * FROM accounts WHERE id = 1 FOR UPDATE;  -- ロックを取得します
UPDATE accounts SET balance = 900 WHERE id = 1;
COMMIT;  -- ここでロックを解放します

-- トランザクションB（Aのロック中は待機します）
BEGIN;
SELECT * FROM accounts WHERE id = 1 FOR UPDATE;  -- Aの完了を待ちます
-- Aがコミット後にロックを取得し、最新のbalance = 900を読みます
UPDATE accounts SET balance = 800 WHERE id = 1;
COMMIT;

```

## 競合状態の防止

### lost update問題

ロックなしのread-modify-writeパターンはlost updateを引き起こします。

```ruby

# 危険なパターン: lost updateが発生します

account = Account.find(1)         # balance: 1000を読み取ります
account.balance -= 100            # アプリケーション側で計算します
account.save!                     # balance: 900を書き込みます

# → 同時に別のトランザクションが1000 - 200 = 800を書き込むと

#   こちらの-100が消失します

```

### 解決策1: アトミックSQL

最もシンプルで高速な方法です。DBレベルでアトミックに処理されます。

```ruby

# 安全: SQLレベルのアトミック操作

Account.where(id: 1).update_all("balance = balance - 100")

# ActiveRecordのカウンターキャッシュ

Account.update_counters(1, balance: -100)

```

### 解決策2: 楽観的ロック + リトライ

```ruby

def withdraw(account_id, amount, max_retries: 3)
  retries = 0
  begin
    account = Account.find(account_id)
    account.balance -= amount
    account.save!
  rescue ActiveRecord::StaleObjectError
    retries += 1
    retry if retries <= max_retries
    raise
  end
end

```

### 解決策3: 悲観的ロック

```ruby

def withdraw(account_id, amount)
  Account.transaction do
    account = Account.lock.find(account_id)
    raise "残高不足" if account.balance < amount
    account.balance -= amount
    account.save!
  end
end

```

## デッドロック対策

### デッドロックの発生条件

デッドロックは、2つ以上のトランザクションが互いのロック解放を待ち続ける状態です。

```text

トランザクションA: 口座1をロック → 口座2のロック待ち
トランザクションB: 口座2をロック → 口座1のロック待ち
→ 永遠に待ち続けます（デッドロック）

```

### 防止策1: ロック順序の固定

常にIDの昇順でロックを取得することで、デッドロックを構造的に防止します。

```ruby

def transfer(from_id, to_id, amount)
  # 常にID昇順でロックします（デッドロック防止の鍵）
  first_id, second_id = [from_id, to_id].sort

  Account.transaction do
    first = Account.lock.find(first_id)
    second = Account.lock.find(second_id)

    from = from_id == first_id ? first : second
    to = to_id == first_id ? first : second

    from.balance -= amount
    to.balance += amount
    from.save!
    to.save!
  end
end

```

### 防止策2: タイムアウトの設定

```sql

-- PostgreSQL
SET lock_timeout = '5s';

-- MySQL
SET innodb_lock_wait_timeout = 5;

```

```ruby

# Railsでの設定

ActiveRecord::Base.connection.execute("SET lock_timeout = '5s'")

```

### 防止策3: リトライパターン

デッドロック検出後にリトライします。

```ruby

def with_deadlock_retry(max_retries: 3)
  retries = 0
  begin
    yield
  rescue ActiveRecord::Deadlocked
    retries += 1
    raise if retries > max_retries
    sleep(0.01 * (2 ** retries) * rand)  # 指数バックオフ
    retry
  end
end

```

## 実務でのロック戦略選択

### 判断フレームワーク

| 状況 | 推奨戦略 | 理由
| ------ | --------- | ------
| 読み取り多、書き込み競合少 | 楽観的ロック | ロック不要でスループットが高いです
| フォーム送信（人間操作） | 楽観的ロック | 競合は稀で、UIでリトライ可能です
| 金融取引 | 悲観的ロック | lost updateは絶対に許容できません
| カウンター更新 | アトミックSQL | 最もシンプルで最速です
| バッチ二重実行防止 | アドバイザリーロック | プロセスレベルの排他制御を実現します
| 在庫管理 | 悲観的ロック/アトミックSQL | 高競合で正確性が重要です

### 実務シナリオ別の推奨

#### ECサイトの在庫管理

```ruby

# 在庫の減算: 悲観的ロックまたはアトミックSQLを使用します

Product.transaction do
  product = Product.lock.find(product_id)
  raise "在庫不足" if product.stock < quantity
  product.stock -= quantity
  product.save!
end

# またはアトミックSQL（シンプルな場合）

result = Product.where(id: product_id)
                .where("stock >= ?", quantity)
                .update_all("stock = stock - #{quantity.to_i}")
raise "在庫不足" if result == 0

```

#### ユーザープロフィール編集

```ruby

# 楽観的ロック: lock_versionカラムを追加します

# フォーム側にhidden fieldとしてlock_versionを含めます

def update
  @user = User.find(params[:id])
  @user.assign_attributes(user_params)
  @user.save!
rescue ActiveRecord::StaleObjectError
  flash[:alert] = "他のユーザーが先に更新しました。最新の内容を確認してください。"
  redirect_to edit_user_path(@user)
end

```

#### バッチ処理の二重実行防止

```ruby

# PostgreSQLのアドバイザリーロックを使用します

def run_daily_batch
  lock_key = Zlib.crc32("daily_batch_#{Date.today}")
  result = ActiveRecord::Base.connection.execute(
    "SELECT pg_try_advisory_lock(#{lock_key})"
  )
  unless result.first["pg_try_advisory_lock"]
    Rails.logger.info("バッチ処理は既に実行中です")
    return
  end

  begin
    # バッチ処理の実行
    process_daily_data
  ensure
    ActiveRecord::Base.connection.execute(
      "SELECT pg_advisory_unlock(#{lock_key})"
    )
  end
end

```

## 実行方法

```bash

# テストの実行

bundle exec rspec 28_database_locking/database_locking_spec.rb

# 個別のメソッドを試す

ruby -r ./28_database_locking/database_locking -e "pp DatabaseLocking::OptimisticLocking.demonstrate_basic_optimistic_lock"
ruby -r ./28_database_locking/database_locking -e "pp DatabaseLocking::DeadlockPrevention.demonstrate_lock_ordering"
ruby -r ./28_database_locking/database_locking -e "pp DatabaseLocking::LockStrategyDecision.demonstrate_decision_framework"

```
