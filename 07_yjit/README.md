# 07: YJIT - Ruby JITコンパイラの深層理解

## 概要

YJIT（Yet Another JIT）は、Ruby 3.1で実験的に導入され、Ruby
3.2で正式リリースされたJITコンパイラです。Shopifyのチームによって開発され、CRubyのインタプリタに直接組み込まれています。

Ruby 3.3以降ではデフォルトのJITコンパイラとして推奨されており、Rails 8ではYJITの有効化が公式に推奨されています。

## YJITの仕組み（Lazy Basic Block Versioning）

### LBBV（Lazy Basic Block Versioning）とは

YJITの中核となるコンパイル戦略で、従来のJITコンパイラとは異なるアプローチを取ります。

#### Basic Blockとは

制御フローにおいて、途中で分岐・合流がない連続した命令の列のことです。if文やループの各分岐がBasic Blockに対応します。

```ruby

# 例: 以下のメソッドは3つのBasic Blockに分解される

def classify(n)
  if n > 0       # Block 1: 条件評価
    "positive"   # Block 2: true側
  else
    "non-positive" # Block 3: false側
  end
end

```

#### 遅延（Lazy）コンパイル

メソッド全体を一度にコンパイルするのではなく、実際に実行されるBasic Blockのみを必要に応じてコンパイルします。

- 到達しないコードパスはコンパイルしません（メモリ節約）
- 最初の実行時に1ブロックずつコンパイルが進みます
- コンパイル対象が最小限のため、コンパイル時間が短くなります

#### バージョニング（Versioning）

同じBasic Blockに対して、異なる型コンテキストごとに別バージョンのネイティブコードを生成します。

```ruby

def add(a, b)
  a + b
end

# Integer版のadd: 整数加算に特化したネイティブコード

add(1, 2)

# String版のadd: 文字列連結に特化したネイティブコード

add("hello", " world")

```

### 型ガードとサイドイグジット

コンパイル済みコードには型ガード（型チェック）が挿入されます。実行時に想定外の型が来た場合、サイドイグジットによりインタプリタにフォールバックします。

```text

コンパイル済みコード（Integer版）:
  1. 型ガード: aがIntegerか？ → No → サイドイグジット（インタプリタへ）
  2. 型ガード: bがIntegerか？ → No → サイドイグジット（インタプリタへ）
  3. 整数加算（最適化済みネイティブコード）

```

## 本番環境での有効化判断基準

### YJITを有効化すべき条件

| 条件 | 説明
| ------ | ------
| Ruby 3.2以上 | YJITが正式リリースされたバージョンです
| x86_64またはARM64 | YJITがサポートするCPUアーキテクチャです
| メモリに余裕がある | YJITはコンパイル済みコードを保持するため追加メモリが必要です
| CPUバウンドな処理が多い | I/O待ちが支配的な場合は効果が限定的です

### 有効化方法

```bash

# コマンドラインオプション

ruby --yjit app.rb

# 環境変数（Ruby 3.3+、推奨）

RUBY_YJIT_ENABLE=1 bundle exec rails server

# Dockerfileでの設定例

ENV RUBY_YJIT_ENABLE=1

# config/application.rbでの確認

if defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
  Rails.logger.info "YJIT is enabled"
end

```

### チューニングパラメータ

```bash

# 実行可能メモリサイズの調整（デフォルト: 48MB）

# 大規模Railsアプリでは128MB以上を推奨

ruby --yjit --yjit-exec-mem-size=128 app.rb

# コンパイル閾値の調整（デフォルト: 30回）

# 値を小さくすると早期にコンパイルされるが、コンパイルコストが増加

ruby --yjit --yjit-call-threshold=10 app.rb

```

### 注意点

- メモリ使用量の増加: YJITはコンパイル済みネイティブコードをメモリに保持するため、YJIT無効時と比較して10〜30%程度メモリ使用量が増加します
- 起動時のオーバーヘッド: 初回コンパイル時にわずかなオーバーヘッドがありますが、ウォームアップ後は解消されます
- 互換性: 一部のgemでYJIT有効時に問題が発生する可能性があるため、テスト環境での検証が重要です

## パフォーマンス計測方法

### 基本的な計測アプローチ

```ruby

# 1. ウォームアップ → 計測のパターンを必ず使う

# 2. GCの影響を排除する

# 3. 複数回計測して中央値を取る

YjitOptimization.benchmark_with_warmup(
  warmup_iterations: 1000,
  measure_iterations: 10_000,
  measurement_rounds: 5
) { target_method }

```

### YJIT統計情報の活用

```bash

# --yjit-statsで詳細な統計を取得

ruby --yjit --yjit-stats app.rb

```

```ruby

# プログラム内からの統計取得

if defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?
  stats = RubyVM::YJIT.runtime_stats

  # コンパイル済みISEQ数（命令シーケンス）
  puts "Compiled ISEQs: #{stats[:compiled_iseq_count]}"

  # インラインコードサイズ
  puts "Inline code size: #{stats[:inline_code_size]} bytes"

  # 無効化回数（少ないほど良い）
  puts "Invalidations: #{stats[:invalidation_count]}"
end

```

### A/Bテストのアプローチ

本番環境でのYJIT効果を正確に測定するには、以下のアプローチを推奨します。

1. カナリアデプロイ: 一部のサーバーのみYJITを有効化し、レスポンスタイム・スループットを比較します
2. 段階的ロールアウト: 10% → 25% → 50% → 100%と段階的に有効化範囲を広げます
3. メトリクスの監視項目は以下の通りです

   - p50/p95/p99レスポンスタイム
   - スループット（RPM）
   - メモリ使用量
   - CPU使用率

## Rails 8でのYJIT効果

### 公式サポート

Rails 7.2以降、`rails new`で生成されるDockerfileにYJITの有効化設定が含まれるようになりました。Rails
8ではYJITの使用が公式に推奨されています。

### 期待される効果

Rails 8アプリケーションにおけるYJITの効果は、ワークロードによって異なりますが、一般的に以下の改善が報告されています。

| ワークロード | 期待される改善幅
| --- | ---
| JSONシリアライゼーション | 15〜25%高速化
| テンプレートレンダリング(ERB) | 10〜20%高速化
| ActiveRecordクエリ構築 | 5〜15%高速化
| ルーティング処理 | 10〜20%高速化
| 全体的なRPSスループット | 10〜20%向上

効果はアプリケーションの特性に大きく依存します。I/OバウンドなアプリではCPU改善の恩恵が限定的です。

### YJITが特に効果的なRailsの処理パターン

```ruby

# 1. ビューのレンダリング（同じテンプレートの繰り返し実行）

# ERBテンプレートのコンパイル済みコードが型特化される

# 2. シリアライゼーション（同じ構造のHashの繰り返し処理）

records.map do |record|
  { id: record.id, name: record.name, email: record.email }
end

# 3. バリデーション（同じモデルの繰り返し検証）

# ActiveModelのバリデーションチェーンが最適化される

# 4. ルーティング（パスマッチングの繰り返し）

# ActionDispatchのルーティングテーブル走査が高速化

```

### YJIT最適化のためのコーディング指針

#### 推奨パターン

```ruby

# frozen_string_literal: true を必ず使用する

# → String再アロケーションの削減

# 型を一貫させる

def process_items(items)
  items.each do |item|
    # 局所変数に型を固定して使用
    name = item.name     # 常にString
    count = item.count   # 常にInteger
    # ...
  end
end

# メソッドの戻り値の型を統一する

def find_value(key)
  result = cache[key]
  result || ""  # nilの代わりに空文字列を返す（型の統一）
end

```

#### 避けるべきパターン

```ruby

# 定数の再定義（invalidationの原因）

# × CONFIG = load_config  # 再代入を避ける

# ○ CONFIG = load_config.freeze  # 一度だけ設定してfreezeする

# method_missingの過度な使用

# × 動的なプロキシオブジェクト（型が不安定）

# ○ 明示的なメソッド定義（delegateメソッドの使用）

# sendによる動的ディスパッチの回避

# × obj.send(method_name)

# ○ case文やif文で明示的に分岐

```

## ファイル構成

| ファイル | 内容
| --------- | ------
| `yjit.rb` | YJIT最適化モジュール（可用性チェック、型特化デモ、ベンチマーク）
| `yjit_spec.rb` | RSpecテスト
| `README.md` | 本ドキュメント

## 参考資料

- [YJIT公式ドキュメント（Ruby）](https://docs.ruby-lang.org/en/master/RubyVM/YJIT.html)
- [YJIT
  GitHub（Shopify/ruby）](https://github.com/ruby/ruby/blob/master/doc/yjit/yjit.md)
- [Lazy Basic Block
  Versioning論文](https://dl.acm.org/doi/10.1145/2784731.2784738)
- [Rails 8 Release Notes](https://guides.rubyonrails.org/8_0_release_notes.html)
