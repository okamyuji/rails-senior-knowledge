# 09. Ruby Refinements - 安全なモンキーパッチ

## 概要

RefinementsはRuby 2.0で実験的に導入され、Ruby
2.1で正式機能となった仕組みです。従来のオープンクラス（モンキーパッチ）がグローバルに影響を及ぼすのに対し、Refinementsはレキシカルスコープ内でのみ有効な安全なクラス拡張手段を提供します。

## モンキーパッチの危険性

### グローバル汚染の問題

```ruby

# 危険: すべてのコードに影響する

class String
  def to_boolean
    self == "true"
  end
end

# アプリケーション全体でString#to_booleanが使えてしまう

# 他のgemが同名メソッドを定義していたら衝突する

```

### 具体的なリスク

1. 名前衝突: 複数のgemが同じメソッド名を異なる実装で定義する可能性があります
2. 暗黙的な依存: コードがモンキーパッチの存在に暗黙的に依存し、デバッグが困難になります
3. テストの不安定化: グローバルな変更がテスト間で干渉し、順序依存のテスト失敗を引き起こします
4. アップグレード困難: Rubyやgemのバージョンアップ時に、パッチしたメソッドが本体の変更と矛盾します

### Railsにおける実例

ActiveSupportはコアクラスを大量に拡張しています（`1.day`,
`"hello".blank?`など）。これは便利ですが、ActiveSupportを読み込んだ瞬間にグローバルに影響します。Refinementsはこの問題に対する言語レベルの解決策です。

## Refinementsによる安全な拡張

### 基本構文

```ruby

# 1. Refinementを定義する（Module#refineを使う）

module StringExtensions
  refine String do
    def to_boolean
      %w[true yes 1 on].include?(strip.downcase)
    end
  end
end

# 2. usingで有効化する（レキシカルスコープ内でのみ有効）

class MyService
  using StringExtensions

  def process(input)
    input.to_boolean  # ここでは使える
  end
end

# 3. スコープ外では使えない

"true".to_boolean  # => NoMethodError

```

### レキシカルスコープの仕組み

Refinementsが「安全」である理由は、レキシカルスコープに基づくからです。

```ruby

module MyRefinement
  refine String do
    def shout
      upcase + "!!!"
    end
  end
end

class A
  using MyRefinement
  def test
    "hello".shout  # => "HELLO!!!" (有効)
  end
end

class B
  def test
    "hello".shout  # => NoMethodError (無効)
  end
end

```

重要なポイントは以下の通りです。

- `using`を呼んだクラス/モジュール定義のレキシカルスコープ内でのみ有効です
- 継承やインクルードでは伝播しません
- ファイルのトップレベルで`using`した場合、そのファイル全体で有効になります

### superによる既存メソッドのラッピング

```ruby

module BetterInspect
  refine Array do
    def inspect
      "[size=#{size}] #{super}"
    end
  end
end

class Debugger
  using BetterInspect

  def show(arr)
    arr.inspect  # => "[size=3] [1, 2, 3]"
  end
end

```

## gem設計での活用

### 推奨パターン: オプショナルRefinements

```ruby

# gemのメインモジュール

module MyAwesomeGem
  # 基本機能は通常のクラス/モジュールで提供
  def self.format_currency(amount, symbol: "$")
    "#{symbol}#{'%.2f' % amount}"
  end

  # コアクラスの拡張はRefinementとして提供
  module CoreExtensions
    refine Numeric do
      def to_currency(symbol: "$")
        MyAwesomeGem.format_currency(self, symbol: symbol)
      end
    end
  end
end

# 利用者は明示的にオプトインする

class InvoiceCalculator
  using MyAwesomeGem::CoreExtensions

  def total
    (100.5).to_currency(symbol: "¥")
  end
end

```

### gem設計のベストプラクティス

1. 基本機能は通常のモジュールメソッドとして提供します。Refinementに依存しない使い方を常に用意してください
2. Refinementは便利なショートカットとして提供します。`using`しなくても機能は使える設計にしてください
3. Refinementモジュールは名前空間で整理します。`MyGem::CoreExtensions::StringMethods`のようにしてください
4. ドキュメントで`using`の使い方を明示してください。利用者が迷わないようにします

## 制限事項と回避策

### 制限1: メソッド内でusingできない

```ruby

# エラーになる

def some_method
  using StringExtensions  # => RuntimeError
end

# 回避策: クラスまたはモジュールレベルでusingする

class MyClass
  using StringExtensions  # OK

  def some_method
    "test".to_boolean  # 使える
  end
end

```

### 制限2: usingスコープ外では一切使えない

Refinementsの最も基本的な制限として、`using`を呼んでいないスコープからはRefinedメソッドを一切利用できません。

```ruby

module StringExtensions
  refine String do
    def to_boolean
      self == "true"
    end
  end
end

class WithUsing
  using StringExtensions
  def check = "true".to_boolean  # => true (成功)
end

class WithoutUsing
  def check = "true".to_boolean  # => NoMethodError (失敗)
end

```

### 制限3: ancestorsに表示されない

Refinementsは`ancestors`メソッドの結果に含まれません。デバッグ時にメソッド探索チェーンを確認してもRefinementの存在は見えません。

```ruby

class Demo
  using StringExtensions
  # String.ancestorsにはStringExtensionsは含まれない
end

```

### Ruby 3.2以降で解消された旧制限事項

Ruby 3.1以前では以下の制限がありましたが、Ruby 3.2以降で改善されました。

#### respond_to?がRefinedメソッドを検出するようになりました

```ruby

class Demo
  using StringExtensions

  def check
    "true".to_boolean               # => true
    "true".respond_to?(:to_boolean) # Ruby 3.1以前: false / Ruby 3.2+: true
  end
end

```

#### send / public_sendがRefinementを経由するようになりました

```ruby

class Demo
  using StringExtensions

  def via_send
    "true".send(:to_boolean)  # Ruby 3.1以前: NoMethodError / Ruby 3.2+: true
  end
end

```

#### method()でMethodオブジェクトを取得できるようになりました

```ruby

class Demo
  using StringExtensions

  def get_method
    "test".method(:to_boolean)  # Ruby 3.1以前: NameError / Ruby 3.2+: Methodオブジェクト
  end
end

```

### 古いバージョンとの互換性が必要な場合の回避策

Ruby 3.1以前をサポートする必要がある場合は、以下の回避策を検討してください。

```ruby

# respond_to?の代替: 定数フラグを用意する

module StringExtensions
  AVAILABLE = true

  refine String do
    def to_boolean
      # ...
    end
  end
end

if defined?(StringExtensions::AVAILABLE)
  # Refinementが利用可能であることを示す
end

# sendの代替: ラッパーメソッドを定義する

class Demo
  using StringExtensions

  def call_refined(str, method_name)
    case method_name
    when :to_boolean then str.to_boolean
    else str.send(method_name)
    end
  end
end

# method()の代替: lambdaでラップする

class Demo
  using StringExtensions

  def get_callable
    ->(str) { str.to_boolean }  # lambdaでラップ
  end
end

```

## Refinementsとメソッド探索の関係

Refinementsは通常のメソッド探索チェーン（`ancestors`）には現れません。`using`が有効なレキシカルスコープ内でのみ、通常の探索よりも先にRefinedメソッドが探索されます。

```text

探索順序（usingが有効な場合）:
1. Refinements（レキシカルスコープ内のみ）
2. レシーバのシングルトンクラス
3. レシーバのクラス
4. prependされたモジュール
5. includeされたモジュール
6. スーパークラス
7. ... → BasicObject

```

## ファイル構成

```text

09_refinements/
├── README.md              # このファイル
├── refinements.rb         # Refinementsの実装例
└── refinements_spec.rb    # テストコード

```

## 実行方法

```bash

# テストの実行

bundle exec rspec 09_refinements/refinements_spec.rb

# 特定のテストグループのみ実行

bundle exec rspec 09_refinements/refinements_spec.rb -e "レキシカルスコープ"
bundle exec rspec 09_refinements/refinements_spec.rb -e "制限事項"

```

## 参考資料

- [Ruby公式ドキュメント -
  Refinements](https://docs.ruby-lang.org/ja/latest/method/Module/i/refine.html)
- [Rubyリファレンスマニュアル -
  using](https://docs.ruby-lang.org/ja/latest/method/main/i/using.html)
- [RubyKaigi発表資料 - Refinementsの設計思想](https://rubykaigi.org/)
