# Railsキャッシング戦略

## 概要

Railsは`ActiveSupport::Cache::Store`による統一キャッシュインターフェースを提供しており、MemoryStore、FileStore、RedisCacheStore、MemCacheStore、SolidCacheStoreなど複数のバックエンドを透過的に切り替えることができます。シニアRailsエンジニアにとって、キャッシング戦略の深い理解は以下の場面で不可欠です。

- 大規模トラフィックにおけるレスポンスタイムを最適化する場面
- Thundering herd（集団暴走）問題を防止する場面
- キャッシュ無効化戦略を設計する場面
- マルチサーバー環境でキャッシュの整合性を確保する場面

## キャッシュストア統一API

全キャッシュバックエンドが実装する共通インターフェースは以下の通りです。

| メソッド | 説明 | 戻り値
| ---------- | ------ | --------
| `read(key)` | キャッシュ値を読み取ります | 値 or nil
| `write(key, value, options)` | キャッシュ値を書き込みます | true/false
| `fetch(key, options) { }` | 読み取り、またはブロックを計算して書き込みます | 値
| `delete(key)` | エントリを削除します | true/false
| `exist?(key)` | キーの存在を確認します | true/false
| `increment(key, amount)` | カウンタを増加させます | 新しい値
| `decrement(key, amount)` | カウンタを減少させます | 新しい値
| `clear` | 全エントリを削除します | -

```ruby

# バックエンドに依存しない統一的なコード

Rails.cache.fetch("user:#{user.id}", expires_in: 1.hour) do
  user.expensive_computation
end

```

## Cache-asideパターン（fetch）

`fetch`メソッドはCache-asideパターンを実装しています。

```text

1. キャッシュにキーが存在するか確認します（read）
2. 存在すればキャッシュ値を返します（ヒット）
3. 存在しなければブロックを実行し、結果をキャッシュに書き込んで返します（ミス）

```

```ruby

# 基本的な使い方

result = Rails.cache.fetch("expensive_query", expires_in: 1.hour) do
  User.includes(:posts, :comments).where(active: true).to_a
end

# force: trueで強制更新します

Rails.cache.fetch("data", force: true) { recompute_data }

# skip_nil: trueでnil結果のキャッシュ汚染を防止します（Rails 7.1+）

Rails.cache.fetch("api_response", skip_nil: true) do
  ExternalApi.fetch_data rescue nil
end

```

## Thundering Herd対策としてのrace_condition_ttl

キャッシュが期限切れになった瞬間、大量のリクエストが同時にキャッシュを再構築しようとする問題（thundering
herd）を`race_condition_ttl`で防止できます。

### 問題のシナリオ

```text

[期限切れ直後]
リクエストA → キャッシュミス → DBクエリ実行
リクエストB → キャッシュミス → DBクエリ実行  ← 重複！
リクエストC → キャッシュミス → DBクエリ実行  ← 重複！
... 100リクエストが同時にDBクエリを発行 → サーバー過負荷

```

### race_condition_ttlによる解決方法

```text

[期限切れ直後]
リクエストA → キャッシュミス → 古い値の有効期限を延長 → DBクエリ実行
リクエストB → 延長された古い値を返します（ヒット）
リクエストC → 延長された古い値を返します（ヒット）
リクエストA → DBクエリ完了 → 新しい値でキャッシュ更新

```

```ruby

Rails.cache.fetch("popular_page",
  expires_in: 5.minutes,
  race_condition_ttl: 10.seconds
) do
  Page.generate_expensive_content
end

```

## キャッシュバージョニング（Rails 5.2+）

### 従来のキャッシュキーと新方式の比較

| 項目 | 従来方式 | 新方式（Rails 5.2+）
| --- | --- | ---
| キー | `users/1-20241001120000` | `users/1`
| バージョン | キーに含まれます | `20241001120000`として別管理されます
| 更新時 | 新しいキーが生成されます | 同じキーでバージョンが変わります
| 古いエントリ | ゴミとして残ります | 上書きされます（recyclable）

```ruby

# ActiveRecordモデルが自動生成するキーとバージョン

user = User.find(1)
user.cache_key         # => "users/1"（安定キー）
user.cache_version     # => "20241001120000000000"（バージョン）
user.cache_key_with_version  # => "users/1-20241001120000000000"

# fetchでバージョン付きキャッシュを使用します

Rails.cache.fetch(user) do
  # cache_key + cache_versionが内部で自動使用されます
  expensive_render(user)
end

```

## ロシアンドールキャッシング（Russian Doll Caching）

キャッシュフラグメントを入れ子にする戦略です。外側のキャッシュがヒットすれば、内側の個別チェックが不要になります。

### 構造

```erb

<%# 外側: コレクション全体のキャッシュ %>
<% cache @category do %>
  <h2><%= @category.name %></h2>

  <% @category.products.each do |product| %>
    <%# 内側: 個別アイテムのキャッシュ %>
    <% cache product do %>
      <div class="product">
        <h3><%= product.name %></h3>
        <p><%= product.description %></p>
      </div>
    <% end %>
  <% end %>
<% end %>

```

### touchによるカスケード無効化

```ruby

class Product < ApplicationRecord
  belongs_to :category, touch: true
  # → productが更新されるとcategory.updated_atも自動更新されます
  # → categoryのキャッシュバージョンが変わります
  # → 外側キャッシュが無効化されます
end

```

### 動作フロー

```text

1. 初回アクセス: 外側ミス → 内側3つミス → 4回のレンダリングが実行されます
2. 2回目アクセス: 外側ヒット → 内側チェック不要 → 0回のレンダリングで済みます
3. 子要素更新: touch → 外側ミス → 変更された内側1つミス → 2回のレンダリングが実行されます
   （変更されていない内側2つはキャッシュヒットします）

```

## HTTPキャッシング

### ETagベースの実装

```ruby

class ArticlesController < ApplicationController
  def show
    @article = Article.find(params[:id])

    # stale?は以下を行います
    # 1. @articleからETagとLast-Modifiedを生成します
    # 2. リクエストのIf-None-Match / If-Modified-Sinceと比較します
    # 3. 一致すれば304 Not Modifiedを返します（ブロック内はスキップされます）
    if stale?(@article)
      render json: @article
    end
  end
end

```

### Cache-Controlヘッダー

```ruby

class StaticPagesController < ApplicationController
  def about
    # ブラウザとCDNの両方でキャッシュ可能で、1時間有効です
    expires_in 1.hour, public: true
    # ...
  end

  def dashboard
    # ブラウザのみキャッシュ可能です（ユーザー固有データ）
    expires_in 15.minutes, private: true
    # ...
  end
end

```

### HTTPキャッシュの判断フローチャート

```text

リソースは全ユーザーで同一か？
├── Yes → publicキャッシュ（CDN可）
│         └── expires_in 1.hour, public: true
└── No  → privateキャッシュ（ブラウザのみ）
          └── ユーザー固有データが含まれるか？
              ├── Yes → stale? + private
              └── No  → no-store（キャッシュ禁止）

```

## マルチレベルキャッシング

本番環境では複数レベルのキャッシュを組み合わせて最適化します。

```text

L1: プロセス内メモリ（MemoryStore）
    → 最速（マイクロ秒）、プロセスローカルです
    └── TTL: 5-15分、サイズ: 32-128MB/プロセス

L2: 分散キャッシュ（Redis / SolidCache）
    → 高速（ミリ秒）、全サーバーで共有されます
    └── TTL: 1-24時間、サイズ: 数GB-数TB

L3: データベース
    → 低速（数十ミリ秒）、永続データです

```

### リクエスト処理フロー

```text

1. L1チェック → ヒット → 即座に返却します
2. L1ミス → L2チェック → ヒット → L1に書き戻して返却します
3. L2ミス → DBクエリ → L2に書き込み → L1に書き込み → 返却します

```

### 注意点

- L1-L2の不整合に注意してください。L1に古いデータが残る可能性があるため、短いTTLで緩和します
- キャッシュ無効化の際は、`delete`時にL1とL2の両方から削除する必要があります
- メモリ監視として、L1のメモリ消費量を監視し、適切なサイズ上限を設定してください

## キャッシング戦略の選定ガイド

| 戦略 | スコープ | 適用場面 | 無効化方法
| ------ | --------- | ---------- | ------------
| ページキャッシュ | ページ全体 | 完全静的ページ | ファイル削除
| アクションキャッシュ | アクション出力 | フィルタ通過+同一出力 | expire_action
| フラグメントキャッシュ | ビュー部分 | 動的ページの部分 | cache_key変更
| ロシアンドール | ネストされたビュー | リスト+個別表示 | touch: true
| 低レベルキャッシュ | 任意オブジェクト | DBクエリ、API応答 | delete / expires_in
| HTTPキャッシュ | HTTPレスポンス | API、静的寄りページ | ETag / Last-Modified

## 実行方法

```bash

# テストの実行

bundle exec rspec 31_caching_strategies/caching_strategies_spec.rb

# 個別テストの実行

bundle exec rspec 31_caching_strategies/caching_strategies_spec.rb -e "fetch"

```

## 参考資料

- [Rails Guides - Caching with
  Rails](https://guides.rubyonrails.org/caching_with_rails.html)
- [ActiveSupport::Cache::Store
  API](https://api.rubyonrails.org/classes/ActiveSupport/Cache/Store.html)
- [Russian Doll Caching in
  Rails](https://signalvnoise.com/posts/3113-how-key-based-cache-expiration-works)
- [HTTP Caching - MDN Web
  Docs](https://developer.mozilla.org/ja/docs/Web/HTTP/Caching)
