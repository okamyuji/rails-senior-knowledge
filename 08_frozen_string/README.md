# 08: Frozen String LiteralとChilled String

## 概要

Ruby 3.4で導入されたChilled
Stringの概念を中心に、`frozen_string_literal`プラグマの仕組み、メモリ最適化効果、そして将来のRubyにおけるデフォルトフリーズへの移行戦略を解説します。

## 目次

1. [frozen_string_literalプラグマ](#1-frozen_string_literalプラグマ)
2. [Chilled String（Ruby 3.4）](#2-chilled-stringruby-34)
3. [文字列デデュプリケーション](#3-文字列デデュプリケーション)
4. [メモリ最適化効果](#4-メモリ最適化効果)
5. [ミュータブル文字列パターン](#5-ミュータブル文字列パターン)
6. [Hashキーへの影響](#6-hashキーへの影響)
7. [移行戦略](#7-移行戦略)
8. [実務での注意点](#8-実務での注意点)

---

## 1. frozen_string_literalプラグマ

### 基本的な仕組み

ファイル先頭に`# frozen_string_literal: true`を記述すると、そのファイル内のすべての文字列リテラルが自動的にフリーズされます。

```ruby

# frozen_string_literal: true

str = "hello"
str.frozen?     # => true
str << " world" # => FrozenError: can't modify frozen String: "hello"

```

### コンパイル時の最適化

プラグマはRubyのコンパイラ（パーサー）レベルで作用します。ランタイムでの`freeze`呼び出しとは異なり、コンパイル時点で文字列リテラルがフリーズ済みとしてマークされるため、オーバーヘッドがありません。

```ruby

# frozen_string_literal: true

# 以下は全て同等（プラグマ有効時）

a = "hello"
b = "hello".freeze  # 冗長だが害はない
c = -"hello"        # デデュプリケーション付き

```

## 2. Chilled String（Ruby 3.4）

### Chilled（冷却された）文字列という新概念

Ruby 3.4では、`frozen_string_literal`プラグマが指定されていないファイルの文字列リテラルが新しい「Chilled」状態になります。

```ruby

# frozen_string_literalプラグマなし（Ruby 3.4）

str = "hello"
str.frozen?     # => true（Chilled状態）

str << " world" # => warning: literal string will be frozen in the future
                #    操作自体は成功する

str.frozen?     # => false（unfreezeされた）
str             # => "hello world"

```

### Chilled Stringの設計意図

| バージョン | プラグマなし | プラグマtrue | プラグマfalse
| ----------- | ------------- | -------------- | ---------------
| Ruby 3.3以前 | ミュータブル | フリーズ | ミュータブル
| Ruby 3.4 | Chilled（警告付き） | フリーズ | ミュータブル
| 将来のRuby | フリーズ（予定） | フリーズ | ミュータブル

Chilled
Stringは、将来のRubyで文字列リテラルがデフォルトでフリーズされることへの移行パスとして設計されています。破壊的操作時に即座にエラーにするのではなく、警告を出してから操作を許可することで、既存コードの段階的な修正を可能にします。

### `frozen_string_literal: false`との違い

`# frozen_string_literal: false`を明示的に指定した場合、そのファイルの文字列リテラルはRuby
3.4でも従来通りミュータブルのままです（Chilledにはなりません）。これは意図的にミュータブル文字列が必要な場合のオプトアウト手段となります。

## 3. 文字列デデュプリケーション

### 単項マイナス（`-@`）の活用

`-"string"`は、フリーズされたデデュプリケーション済み文字列を返します。VM内部のフリーズ文字列テーブルから同一内容の文字列を検索し、存在すれば既存のオブジェクトを返します。

```ruby

a = -"hello"
b = -"hello"
a.equal?(b)     # => true（同一オブジェクト）
a.object_id == b.object_id  # => true

```

### 単項プラス（`+@`）の活用

`+"string"`は、ミュータブルなコピーを返します。`frozen_string_literal:
true`環境でミュータブルな文字列が必要な場合に最も簡潔な記法です。

```ruby

# frozen_string_literal: true

frozen = "hello"
mutable = +"hello"

frozen.frozen?   # => true
mutable.frozen?  # => false
mutable << "!"   # => "hello!"

```

### 動的文字列のデデュプリケーション

動的に生成された文字列も`-@`でデデュプリケーションできます。

```ruby

dynamic = +"hel" + "lo"
deduped = -dynamic
literal = -"hello"

deduped.equal?(literal)  # => true（内容が同じならデデュプ）

```

## 4. メモリ最適化効果

### オブジェクト共有

`frozen_string_literal: true`環境下では、同一内容の文字列リテラルが同一のRubyオブジェクトを参照します。

```ruby

# frozen_string_literal: true

ids = 1000.times.map { "shared".object_id }
ids.uniq.size  # => 1（全て同一オブジェクト）

```

### メモリ削減の実際の効果

大規模Railsアプリケーションでの一般的な効果は以下の通りです。

- 文字列オブジェクト数: 10-30%削減
- メモリ使用量: 数MB〜数十MB削減（アプリケーション規模による）
- GC負荷: 短寿命の文字列オブジェクトが減少し、GCの頻度が低下します

### ObjectSpaceによる計測

```ruby

GC.start
before = ObjectSpace.count_objects[:T_STRING]

# フリーズされたリテラル（新しいオブジェクトは生成されない）

100.times { "frozen_literal" }

GC.start
after = ObjectSpace.count_objects[:T_STRING]

puts "増加したStringオブジェクト数: #{after - before}"  # => 0に近い値

```

## 5. ミュータブル文字列パターン

`frozen_string_literal: true`環境下でミュータブルな文字列が必要な場合の3つのパターンを示します。

```ruby

# frozen_string_literal: true

# パターン1: String.new（最も明示的）

buffer = String.new("")
buffer << "data"

# パターン2: 単項プラス（最も簡潔）

mutable = +"template"
mutable.gsub!("template", "actual")

# パターン3: dup（既存オブジェクトから）

original = "base"
copy = original.dup
copy << " extended"

```

### 使い分けの指針

| パターン | 用途 | 特徴
| --------- | ------ | ------
| `String.new` | バッファ構築、エンコーディング指定 | 明示的で、エンコーディング指定が可能です
| `+"..."` | 一時的なミュータブル文字列 | 簡潔で、Rubyist向けです
| `.dup` | 既存文字列のコピー | 汎用的ですが、`clone`との違いに注意してください

## 6. Hashキーへの影響

RubyのHashは、文字列キーを自動的に`dup` + `freeze`します。`frozen_string_literal:
true`環境下では文字列が既にフリーズ済みのため、`dup`のコストを省略できます。

```ruby

# frozen_string_literal: true

key = "my_key"
hash = { key => "value" }

stored_key = hash.keys.first
key.equal?(stored_key)  # => true（dupされない、同一オブジェクト）

```

```ruby

# frozen_string_literal: false

key = String.new("my_key")
hash = { key => "value" }

stored_key = hash.keys.first
key.equal?(stored_key)  # => false（dupされて別オブジェクト）
stored_key.frozen?      # => true（自動freeze）

```

## 7. 移行戦略

### ステップ1: 現状把握

```bash

# プラグマなしのファイルを特定

grep -rL 'frozen_string_literal' app/ lib/ --include='*.rb'

# Ruby 3.4でChilled String警告を収集

RUBYOPT='-W:deprecated' bundle exec rspec

```

### ステップ2: 警告の捕捉

```ruby

# config/initializers/chilled_string_warnings.rb

if RUBY_VERSION >= "3.4"
  original_warn = Warning.method(:warn)

  Warning.define_method(:warn) do |message, **kwargs|
    if message.include?("literal string will be frozen")
      Rails.logger.warn("[ChilledString] #{message.chomp} at #{caller(1, 1)&.first}")
    end
    original_warn.call(message, **kwargs)
  end
end

```

### ステップ3: RuboCopの活用

```yaml

# .rubocop.yml

Style/FrozenStringLiteralComment:
  Enabled: true
  EnforcedStyle: always
  SafeAutoCorrect: true

```

```bash

# 自動修正で一括追加

rubocop -a --only Style/FrozenStringLiteralComment

```

### ステップ4: CI/CDでの検証

```bash

# テスト環境でフリーズをグローバルに有効化

RUBYOPT='--enable-frozen-string-literal' bundle exec rspec

# 段階的に本番環境にも適用

```

## 8. 実務での注意点

### プラグマの影響を受けないケース

| ケース | 理由
| -------- | ------
| テンプレートエンジン（ERB/Haml/Slim） | テンプレートは別途コンパイルされるためです
| `File.read`の返値 | リテラルではなくメソッドの返値です
| `ENV['KEY']`の返値 | 環境変数の読み取り結果です
| `$1`, `$~`等の正規表現マッチ結果 | グローバル変数に格納される値です
| `eval`で生成される文字列 | 動的に評価されるコードです

### ジェムの互換性

古いジェムがミュータブルな文字列を前提としている場合があります。特に以下のパターンに注意してください。

```ruby

# 古いジェムのコード例（問題あり）

def configure(options = {})
  @name = options[:name] || "default"
  @name << " (configured)"  # frozen_string_literal: trueでFrozenError
end

```

### パフォーマンス計測のTips

```ruby

require "benchmark/ips"

Benchmark.ips do |x|
  x.report("frozen literal") { "hello" }
  x.report("String.new")     { String.new("hello") }
  x.report("+literal")       { +"hello" }
  x.compare!
end

```

## 実行方法

```bash

# テストの実行

bundle exec rspec 08_frozen_string/frozen_string_spec.rb

# 特定のテストグループのみ実行

bundle exec rspec 08_frozen_string/frozen_string_spec.rb -e "Chilled"

```

## 参考資料

- [Ruby
  3.4リリースノート](https://www.ruby-lang.org/en/news/2024/12/25/ruby-3-4-0-released/)
- [Feature #20205: Chilled strings](https://bugs.ruby-lang.org/issues/20205)
- [RuboCop
  Style/FrozenStringLiteralComment](https://docs.rubocop.org/rubocop/cops_style.html#stylefrozenstringliteralcomment)
