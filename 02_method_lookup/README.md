# 02: メソッド探索チェーン（Method Lookup Chain）

## 概要

Rubyのメソッド探索チェーンは、オブジェクトに対してメソッドが呼び出された際に、Rubyインタプリタがどの順序でメソッドを探すかを決定する仕組みです。
この仕組みを深く理解することは、シニアRailsエンジニアにとって不可欠なスキルです。

## メソッド探索の理解が重要な理由

### Railsにおける実践的な必要性

1. ActiveSupport::Concernの動作原理:

Railsで頻繁に使われる`ActiveSupport::Concern`は、
`include`と`extend`を内部で巧みに使い分けています。
その動作を理解するには、
メソッド探索チェーンの知識が必要です。

1. ミックスインの設計:

Railsアプリケーションでは、
共通機能をモジュールとして切り出し`include`するパターンが
多用されます。探索順序を理解していないと、
意図しないメソッド衝突が発生します。

1. メソッド衝突のデバッグ:
複数のgemが同名のメソッドを定義している場合、
どのメソッドが実際に呼ばれるかは
ancestorsチェーンで決まります。

1. パフォーマンスの考慮:
`method_missing`に依存した実装は、
探索チェーン全体を走査した後に呼ばれるため、
パフォーマンスへの影響があります。

## メソッド探索の基本順序

```text

receiverのクラス
  → prependされたモジュール（最後にprependされたものが先）
  → クラス自身
  → includeされたモジュール（最後にincludeされたものが先・LIFO）
  → スーパークラス
  → ... （同じパターンでスーパークラスを辿る）
  → Object
  → Kernel
  → BasicObject

```

`Module#ancestors`メソッドで、この探索チェーン全体を配列として確認できます。

## includeとprependの使い分け

### includeを使うべき場面

- 共通機能の追加: クラスに新しい機能を追加するとき
- デフォルト実装の提供: サブクラスでオーバーライド可能なデフォルト動作を提供するとき
- ActiveSupport::Concernパターン: Railsの慣習に従ったモジュール設計

```ruby

module Searchable
  def search(query)
    # デフォルトの検索実装
  end
end

class Product
  include Searchable
  # 必要に応じてsearchをオーバーライド可能
end

```

### prependを使うべき場面

- 既存メソッドのラッピング（デコレータパターン）: メソッドの前後に処理を追加したいとき
- AOP（アスペクト指向）的なパターン: ロギング、キャッシュ、認可チェックなど横断的関心事の追加
- alias_method_chainの代替: Rails 5以降、`alias_method_chain`は非推奨となり`prepend`が推奨されます

```ruby

module CacheDecorator
  def expensive_calculation
    cache_key = "calc_#{id}"
    Rails.cache.fetch(cache_key) { super }
  end
end

class Report
  prepend CacheDecorator

  def expensive_calculation
    # 重い計算処理
  end
end

```

### 判断基準のまとめ

| 観点 | include | prepend
| ------ | --------- | ---------
| 探索順序 | クラスの後ろ | クラスの前
| クラスのメソッド | 優先される | モジュールが優先
| superの方向 | モジュール → スーパークラス | クラス → スーパークラス
| 主な用途 | 機能の追加 | 既存メソッドの修飾
| Railsでの例 | Concern | コールバック、デコレータ

## method_missingの注意点

### 必ず守るべきルール

1. respond_to_missing?を必ず実装してください

   `method_missing`だけ実装して`respond_to_missing?`を実装しないと、以下の問題が発生します。

   - `respond_to?`が`false`を返すのにメソッドが呼べる、という矛盾した状態になります
   - `method(:dynamic_method)`でMethodオブジェクトが取得できません
   - デバッグツールやフレームワークが正しく動作しません

2. 処理対象外のメソッドは必ずsuperに委譲してください

   ```ruby

   def method_missing(name, *args)
     if handle?(name)
       # 処理
     else
       super # これを忘れるとNoMethodErrorが発生しなくなる
     end
   end

   ```

3. 可能であればdefine_methodを検討してください

   `method_missing`よりも`define_method`でメソッドを動的に定義する方が以下の点で優れています。

   - パフォーマンスが良い（探索チェーン全体を走査しない）
   - デバッグが容易（メソッドが実際に存在する）
   - Methodオブジェクトが自然に取得できる

### パフォーマンスへの影響

`method_missing`は探索チェーンの最後に呼ばれるため、呼び出しのたびにチェーン全体を走査するコストが発生します。
頻繁に呼ばれるメソッドには不向きです。

```ruby

# 改善パターン: 初回呼び出し時にメソッドを定義してキャッシュする

def method_missing(name, *args)
  if name.to_s.start_with?("find_by_")
    attribute = name.to_s.delete_prefix("find_by_")
    self.class.define_method(name) do |value|
      find_by_attribute(attribute, value)
    end
    send(name, *args)
  else
    super
  end
end

```

## メソッド衝突のデバッグ手法

### 1. ancestorsチェーンの確認

```ruby

MyClass.ancestors

# => [MyClass, ModuleC, ModuleB, ModuleA, Object, Kernel, BasicObject]

```

### 2. メソッドの定義元を特定する方法

```ruby

obj.method(:some_method).owner

# => メソッドが定義されているクラスまたはモジュール

obj.method(:some_method).source_location

# => ["ファイルパス", 行番号]

```

### 3. 特定メソッドの探索チェーンにおける全定義を確認する方法

```ruby

# ancestorsチェーン上でsome_methodを定義しているモジュール/クラスを全て表示

MyClass.ancestors.select { |a| a.instance_methods(false).include?(:some_method) }

```

## Refinementsとの関係

Refinementsはメソッド探索チェーンに影響を与えますが、`ancestors`には表示されない特殊な仕組みです。
詳細はトピック09「Refinements」で扱います。

## 関連トピック

- トピック01: オブジェクトモデル（クラスとモジュールの基本構造）
- トピック09: Refinements（スコープ限定のメソッド探索変更）
- トピック03: ブロック・Proc・Lambda（メソッドとブロックの関係）

## 参考資料

- [Rubyリファレンスマニュアル -
  メソッド呼び出し](https://docs.ruby-lang.org/ja/latest/doc/spec=2fcall.html)
- [Rubyリファレンスマニュアル -
  Module#ancestors](https://docs.ruby-lang.org/ja/latest/method/Module/i/ancestors.html)
- [Rubyリファレンスマニュアル -
  BasicObject#method_missing](https://docs.ruby-lang.org/ja/latest/method/BasicObject/i/method_missing.html)
