# Rubyオブジェクトモデル

## Rubyオブジェクトモデルの理解が重要な理由

Rubyは「すべてがオブジェクト」という設計哲学に基づいています。整数、文字列、クラス、モジュール、さらには`true`や`nil`でさえオブジェクトです。この一貫した設計がRubyの柔軟性とメタプログラミング能力の源泉となっています。

シニアエンジニアがオブジェクトモデルを深く理解すべき理由は以下の通りです。

- デバッグ能力の向上: メソッド探索の仕組みを理解していれば、`NoMethodError`や予期しない挙動の原因を素早く特定できます
- メタプログラミングの基盤:
  `define_method`、`method_missing`、`include`/`prepend`などの高度な手法はオブジェクトモデルの知識なしには正しく使えません
- パフォーマンス最適化: 即値やフリーズの仕組みを理解することで、メモリ効率の良いコードを書けます
- Railsの内部理解:
  ActiveRecord、ActiveSupportのコアとなる仕組み（`concern`、`class_attribute`など）はオブジェクトモデルに依存しています

## 実務での活用場面

### DSL（Domain Specific Language）の設計

Railsの`routes.rb`や`migration`のようなDSLを設計する際、シングルトンクラスやクラスマクロの知識が不可欠です。

```ruby

class ApplicationRecord < ActiveRecord::Base
  # これはクラスメソッド（シングルトンメソッド）の呼び出し
  self.abstract_class = true

  # scopeはクラスマクロ（define_methodを内部で使用）
  scope :recent, -> { order(created_at: :desc) }
end

```

### プラグインシステムの構築

`include`と`prepend`を使ったモジュールの挿入順序を理解することで、堅牢なプラグインシステムを構築できます。

```ruby

module Auditable
  def save
    puts "監査ログを記録"
    super  # prependの場合、元のsaveが呼ばれる
  end
end

class User < ApplicationRecord
  prepend Auditable  # ancestorsチェーンの先頭に挿入
end

User.ancestors

# => [Auditable, User, ApplicationRecord, ActiveRecord::Base, ...]

```

### テスト用のモックとスタブ

RSpecのモック機構はシングルトンクラスを活用してメソッドを一時的に差し替えます。

```ruby

allow(user).to receive(:admin?).and_return(true)

# 内部的にはuserのシングルトンクラスにadmin?を定義している

```

## 各概念の内部動作についての解説

### BasicObject → Object → クラス階層

Rubyのクラス階層は以下のようになっています。

```text

BasicObject          ← すべてのクラスの祖先（最小限のメソッドのみ）
  └── Object         ← Kernelをインクルード（puts, requireなどを提供）
        └── Module   ← モジュール機能を提供
              └── Class  ← クラス生成機能を提供

```

メソッド呼び出し時、Ruby VMは以下の順序でメソッドを探索します。

1. オブジェクトのシングルトンクラス
2. オブジェクトのクラス
3. `prepend`されたモジュール（新しいものが先）
4. `include`されたモジュール（新しいものが先）
5. スーパークラス（同じ手順を繰り返す）
6. 最終的に`BasicObject`まで到達

```ruby

class Animal; end
class Dog < Animal; end

Dog.ancestors

# => [Dog, Animal, Object, Kernel, BasicObject]

```

### シングルトンクラス（特異クラス / eigenclass）

すべてのオブジェクトには「シングルトンクラス」と呼ばれる隠れたクラスが存在します。これはそのオブジェクト固有のメソッドを格納する場所です。

```ruby

obj = Object.new

# 特異メソッドの定義（3つの方法）

def obj.method_a; "a"; end

obj.define_singleton_method(:method_b) { "b" }

class << obj
  def method_c; "c"; end
end

# シングルトンクラスの確認

obj.singleton_class          # => #<Class:#<Object:0x...>>
obj.singleton_class.superclass  # => Object
obj.singleton_methods        # => [:method_a, :method_b, :method_c]

```

クラスメソッドは実はクラスオブジェクトのシングルトンメソッドです。

```ruby

class User
  def self.count  # これはUserのシングルトンクラスにメソッドを定義している
    42
  end
end

# 以下と等価

class << User
  def count
    42
  end
end

User.singleton_class.instance_methods(false)  # => [:count]

```

### インスタンス変数の格納

Rubyのインスタンス変数はクラス定義には含まれず、各オブジェクトが独自に保持します。CRubyの内部では、各オブジェクト構造体（`RObject`）がインスタンス変数のテーブルを持ちます。

```ruby

class Person
  def initialize(name)
    @name = name
  end
end

alice = Person.new("Alice")
bob = Person.new("Bob")

# aliceに動的にインスタンス変数を追加（bobには影響しない）

alice.instance_variable_set(:@role, "admin")

alice.instance_variables  # => [:@name, :@role]
bob.instance_variables    # => [:@name]

```

Ruby 3.2以降では「Object
Shapes」最適化により、同じ順序でインスタンス変数が設定されたオブジェクトはメモリレイアウトを共有し、アクセスが高速化されます。

## 即値最適化の仕組み

CRubyでは、すべてのRubyオブジェクトはCレベルでは`VALUE`型（ポインタサイズの整数）で表現されます。通常のオブジェクトは`VALUE`がヒープ上のオブジェクト構造体へのポインタとなりますが、一部の値は`VALUE`自体に値を埋め込みます。これが「即値」（immediate
value）です。

### 即値の種類とエンコーディング

| 値の種類 | VALUEのビットパターン | object_id |
| --- | --- | --- |
| 小さな整数 | `(n << 1) or 1` | `2n + 1` |
| Symbol | タグ付きポインタ | 固定値 |
| `true` | タグ付き即値 | `20` |
| `false` | `0x00` | `0` |
| `nil` | タグ付き即値 | `4` |

```ruby

# 整数のobject_idパターン

0.object_id   # => 1
1.object_id   # => 3
2.object_id   # => 5
42.object_id  # => 85  (42 * 2 + 1)

# 同じ値は常に同じオブジェクト

42.equal?(42)       # => true
:hello.equal?(:hello)  # => true

```

### パフォーマンスへの影響

即値はヒープ割り当てが不要なため、以下の利点があります。

- GCの負荷軽減: ヒープに存在しないためGCの対象になりません
- メモリ効率: ポインタ1つ分のサイズで値を表現できます
- 比較の高速化: `equal?`がポインタ比較だけで完了します

```ruby

# Symbolをハッシュキーに使うべき理由

# Symbolは即値なので比較がO(1)

hash = { status: "active" }  # :statusは即値
hash[:status]                 # ポインタ比較のみで高速にルックアップ

```

## シングルトンクラスの活用パターン

### パターン1: テンプレートメソッドの個別カスタマイズ

```ruby

class Report
  def generate
    header + body + footer
  end

  def header; "=== レポート ===\n"; end
  def body; raise NotImplementedError; end
  def footer; "=== 終了 ===\n"; end
end

report = Report.new

# このインスタンスだけbodyを実装

def report.body
  "売上データ: 100万円\n"
end

report.generate

# => "=== レポート ===\n売上データ: 100万円\n=== 終了 ===\n"

```

### パターン2: クラスレベルの設定（class_attribute的パターン）

```ruby

class Base
  class << self
    def config
      @config ||= {}
    end

    def set(key, value)
      config[key] = value
    end
  end
end

class ServiceA < Base
  set :timeout, 30
end

class ServiceB < Base
  set :timeout, 60
end

# 各クラスのシングルトンクラスに独立した@configが格納される

ServiceA.config  # => { timeout: 30 }
ServiceB.config  # => { timeout: 60 }

```

### パターン3: `class << self`による名前空間の整理

```ruby

class UserService
  class << self
    private

    def validate(user)
      # プライベートクラスメソッド
    end

    def notify(user)
      # プライベートクラスメソッド
    end
  end

  def self.create(params)
    user = User.new(params)
    validate(user)
    user.save!
    notify(user)
    user
  end
end

```

## 実行方法

```bash

# テストの実行

bundle exec rspec 01_ruby_object_model/ruby_object_model_spec.rb

# 個別のメソッドを試す

ruby -r ./01_ruby_object_model/ruby_object_model -e "pp RubyObjectModel.demonstrate_class_hierarchy"

```
