# 29: バッチ処理パターン

## 概要

大量のレコードを処理する際、全件を一度にメモリに読み込むと
メモリ不足やパフォーマンス劣化を引き起こします。
ActiveRecordはバッチ処理のための複数のAPIを提供しており、
シニアRailsエンジニアはユースケースに応じて適切な手法を選択する必要があります。

## バッチ処理のメモリ効率

### なぜバッチ処理が必要か

```ruby

# 危険: 全レコードをメモリに一括ロードします

Record.all.each do |record|
  # 100万件あれば100万個のActiveRecordオブジェクトがメモリに載ります
  process(record)
end

# 安全: バッチ処理でメモリ使用量を制限します

Record.find_each(batch_size: 1000) do |record|
  # 常に最大1000件分のメモリしか使用しません
  process(record)
end

```

### メモリ使用量の比較

| 手法 | 100万件処理時のメモリ | 説明
| ------ | ---------------------- | ------
| `all.each` | 数GB | 全レコードをインスタンス化します
| `find_each` | 数十MB | batch_size分のみ保持します
| `in_batches + update_all` | 最小 | インスタンス化しません

### メモリ監視のポイント

```ruby

# GC.statでヒープの状態を確認します

GC.start
before = GC.stat[:heap_live_slots]

Record.find_each(batch_size: 1000) do |record|
  process(record)
end

GC.start
after = GC.stat[:heap_live_slots]
puts "ヒープスロット増加: #{after - before}"

```

## find_each / find_in_batches / in_batchesの使い分け

### find_each

レコードを1件ずつyieldするイテレータで、最も基本的なバッチ処理APIです。

```ruby

# 基本使用法

Record.find_each(batch_size: 1000) do |record|
  record.update!(processed: true)
end

# start/finishでID範囲を指定します（再開や並列処理に有用）

Record.find_each(start: 10001, finish: 20000) do |record|
  process(record)
end

```

内部動作は以下の通りです。

1. `SELECT * FROM records WHERE id > ? ORDER BY id ASC LIMIT 1000`を発行します
2. 各レコードを1件ずつブロックにyieldします
3. バッチの最後のIDを記録し、次のバッチのWHERE条件に使用します

適したユースケースは以下の通りです。

- 各レコードに個別の処理を行う場合
- レコード単位でコールバックを実行したい場合

### find_in_batches

バッチ単位でArrayをyieldします。バッチ全体に対する処理に適しています。

```ruby

# バッチ単位での外部APIコール

Record.find_in_batches(batch_size: 100) do |batch|
  # batchはArray（ActiveRecordオブジェクトの配列）
  ids = batch.map(&:id)
  ExternalApi.bulk_update(ids)
end

```

適したユースケースは以下の通りです。

- 外部APIへのバルクリクエスト
- バッチ単位での集約処理
- プログレス表示（バッチ数でカウント）

### in_batches

バッチ単位でActiveRecord::Relationをyieldします。最も柔軟なAPIです。

```ruby

# バッチ単位のupdate_all（コールバックなし、高速）

Record.where(processed: false).in_batches(of: 1000) do |batch|
  batch.update_all(processed: true)
end

# バッチ単位の削除

Record.where(expired: true).in_batches(of: 5000) do |batch|
  batch.delete_all
end

# Relationなのでpluck等も使用可能です

Record.in_batches(of: 1000) do |batch|
  ids = batch.pluck(:id)
  SomeJob.perform_later(ids)
end

```

適したユースケースは以下の通りです。

- `update_all` / `delete_all`をバッチ単位で実行する場合（最も推奨）
- SQL操作をバッチ単位で実行したい場合
- メモリ使用量を最小限にしたい場合

### 比較表

| 特徴 | find_each | find_in_batches | in_batches
| ------ | ----------- | ----------------- | ------------
| yieldの単位 | 1レコード | Arrayバッチ | Relation
| インスタンス化 | します | します | しません（遅延評価）
| update_all使用 | できません | できません | 可能です
| メモリ効率 | 良いです | 良いです | 最も良いです
| 柔軟性 | 低いです | 中程度です | 最も高いです

## 一括操作のパフォーマンス

### insert_all / upsert_all

モデルのインスタンス化、バリデーション、コールバックをスキップして一括挿入します。

```ruby

# insert_all: 一括挿入

records = 10_000.times.map { |i| { data: "item_#{i}", category: "A" } }
Record.insert_all(records)

# upsert_all: 挿入or更新（UPSERT）

Record.upsert_all(
  [{ id: 1, data: "updated", category: "B" }],
  unique_by: :id
)

```

パフォーマンスの比較は以下の通りです。

- `create`のN回呼び出し: N個のINSERT文 + N回のコールバックを実行します
- `insert_all`: 1つのINSERT文で、コールバックは実行しません
- 10,000件で数十倍の速度差が出ることがあります

### update_all

```ruby

# 一括更新（コールバック、バリデーションなし）

Record.where(category: "pending").update_all(category: "completed")

# SQL式も使用可能です

Record.update_all("view_count = view_count + 1")

```

注意点は以下の通りです。

- `updated_at`は自動更新されません（明示的に指定が必要です）
- `before_update` / `after_update`コールバックは実行されません
- カウンターキャッシュも更新されません

### delete_allとdestroy_allの違い

```ruby

# delete_all: DELETE SQL1回、コールバックなし

Record.where(expired: true).delete_all

# => 削除された行数（Integer）

# destroy_all: 各レコードをロードしてdestroy、コールバックあり

Record.where(expired: true).destroy_all

# => 削除されたオブジェクトの配列（Array）

```

| 特徴 | delete_all | destroy_all
| ------ | ----------- | -------------
| 速度 | 高速です（SQL 1回） | 低速です（N+1 DELETE）
| コールバック | 実行されません | 実行されます
| dependent: :destroy | 動作しません | 正しく動作します
| 戻り値 | 行数（Integer） | オブジェクト配列
| メモリ | 最小です | 全レコードをロードします

## 大量データ処理パターン

### プログレス追跡

```ruby

total = Record.where(processed: false).count
processed = 0

Record.where(processed: false).find_each(batch_size: 1000) do |record|
  process(record)
  record.update_column(:processed, true)
  processed += 1

  if (processed % 1000).zero?
    percent = (processed.to_f / total * 100).round(1)
    Rails.logger.info "進捗: #{processed}/#{total} (#{percent}%)"
  end
end

```

### エラーハンドリング（個別エラーで全体を止めない）

```ruby

failures = []

Record.find_each(batch_size: 1000) do |record|
  process(record)
  record.update!(processed: true)
rescue StandardError => e
  failures << { id: record.id, error: e.message }
  Rails.logger.error "レコード#{record.id}の処理失敗: #{e.message}"
end

Rails.logger.info "完了: 失敗#{failures.size}件"

```

### 再開可能なバッチ処理

```ruby

# processedフラグで未処理レコードのみ対象にします

# 中断後に同じコマンドを実行すれば自動的に続きから処理されます

Record.where(processed: false).find_each(batch_size: 1000) do |record|
  process(record)
  record.update_column(:processed, true)
end

```

### 並列バッチ処理（IDレンジ分割）

```ruby

# ワーカー1: ID 1〜50000

Record.find_each(start: 1, finish: 50_000) { |r| process(r) }

# ワーカー2: ID 50001〜100000

Record.find_each(start: 50_001, finish: 100_000) { |r| process(r) }

```

## 実行方法

```bash

# テストの実行

bundle exec rspec 29_batch_processing/batch_processing_spec.rb

# 個別メソッドの動作確認

ruby -r ./29_batch_processing/batch_processing -e "pp BatchProcessing::FindEach.demonstrate_basic_find_each"
ruby -r ./29_batch_processing/batch_processing -e "pp BatchProcessing::BulkInsert.demonstrate_insert_all"
ruby -r ./29_batch_processing/batch_processing -e "pp BatchProcessing::BatchPatterns.api_comparison"

```

## 参考リンク

- [Active Record Query Interface - Batch
  Processing](https://guides.rubyonrails.org/active_record_querying.html#retrieving-multiple-objects-in-batches)
- [insert_all / upsert_all (Rails
  API)](https://api.rubyonrails.org/classes/ActiveRecord/Persistence/ClassMethods.html#method-i-insert_all)
-
  [ActiveRecord::Batches](https://api.rubyonrails.org/classes/ActiveRecord/Batches.html)
- [The Practical Effects of the GVL on Scaling in
  Ruby](https://www.speedshop.co/2020/05/11/the-practical-effects-of-the-gvl-on-scaling-in-ruby.html)
