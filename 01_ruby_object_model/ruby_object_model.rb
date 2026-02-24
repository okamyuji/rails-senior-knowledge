# frozen_string_literal: true

# Rubyオブジェクトモデルの内部構造を解説するモジュール
#
# Rubyでは「すべてがオブジェクト」であり、クラス自体もオブジェクトである。
# このモジュールでは、シニアエンジニアが知るべきオブジェクトモデルの
# 内部動作を実例を通じて学ぶ。
module RubyObjectModel
  module_function

  # === BasicObject → Object → クラス階層 ===
  #
  # Rubyのすべてのオブジェクトは BasicObject を頂点とする
  # 継承チェーンに属する。通常のクラスは暗黙的に Object を継承し、
  # Object は Kernel モジュールをインクルードして BasicObject を継承する。
  #
  # ancestors メソッドで継承チェーン全体を確認できる。
  # これはメソッド探索順序（Method Resolution Order）でもある。
  def demonstrate_class_hierarchy
    # 独自クラスを定義して継承チェーンを確認
    sample_class = Class.new
    ancestors = sample_class.ancestors

    {
      # すべてのクラスの祖先に BasicObject が含まれる
      has_basic_object: ancestors.include?(BasicObject),
      # Object も含まれる（BasicObject を直接継承しない限り）
      has_object: ancestors.include?(Object),
      # Kernel モジュールも継承チェーンに含まれる
      has_kernel: ancestors.include?(Kernel),
      # 継承チェーンの末端は常に BasicObject
      root_ancestor: ancestors.last,
      # Object の直接のスーパークラスは BasicObject
      object_superclass: Object.superclass,
      # BasicObject のスーパークラスは nil（頂点）
      basic_object_superclass: BasicObject.superclass,
      # Integer の完全な継承チェーン
      integer_ancestors: Integer.ancestors
    }
  end

  # === シングルトンクラス（eigenclass / 特異クラス） ===
  #
  # Rubyでは個々のオブジェクトに対してメソッドを定義できる。
  # これはオブジェクト固有の「シングルトンクラス」（特異クラス）に
  # メソッドが追加されることで実現される。
  #
  # シングルトンクラスはメソッド探索チェーンにおいて、
  # オブジェクトの実際のクラスよりも先に探索される。
  def demonstrate_singleton_class
    obj_a = Object.new
    obj_b = Object.new

    # obj_a にだけ特異メソッドを定義
    def obj_a.greet
      'hello from singleton'
    end

    # シングルトンクラスは通常のクラスとは別のオブジェクト
    singleton = obj_a.singleton_class

    {
      # 特異メソッドは定義したオブジェクトだけが持つ
      obj_a_responds: obj_a.respond_to?(:greet),
      obj_b_responds: obj_b.respond_to?(:greet),
      # シングルトンクラスはそのオブジェクト固有
      singleton_class_name: singleton.to_s,
      # シングルトンクラスは Class のインスタンス
      singleton_is_class: singleton.is_a?(Class),
      # シングルトンクラスのスーパークラスはオブジェクトの元のクラス
      singleton_superclass: singleton.superclass,
      # シングルトンメソッドの一覧を取得できる
      singleton_methods: obj_a.singleton_methods
    }
  end

  # === インスタンス変数の格納 ===
  #
  # インスタンス変数はクラスではなく、個々のオブジェクトに格納される。
  # 同じクラスのインスタンスでも、それぞれ異なるインスタンス変数を持てる。
  # これはJavaなどの静的型付け言語とは大きく異なる点である。
  def demonstrate_instance_variable_storage
    klass = Class.new do
      def initialize(name)
        @name = name
      end

      # age は一部のインスタンスにだけ設定される
      def assign_age(age)
        @age = age
      end
    end

    alice = klass.new('Alice')
    bob = klass.new('Bob')
    bob.assign_age(30)

    {
      # alice は @name のみ、bob は @name と @age を持つ
      alice_vars: alice.instance_variables.sort,
      bob_vars: bob.instance_variables.sort,
      # instance_variable_get で動的にアクセス可能
      alice_name: alice.instance_variable_get(:@name),
      bob_age: bob.instance_variable_get(:@age),
      # instance_variable_set で動的に設定可能（カプセル化を破る）
      alice_dynamic: begin
        alice.instance_variable_set(:@dynamic, 'set dynamically')
        alice.instance_variable_get(:@dynamic)
      end,
      # 設定後はインスタンス変数一覧にも反映される
      alice_vars_after: alice.instance_variables.sort
    }
  end

  # === 即値（Immediate Values） ===
  #
  # Rubyでは小さな整数（Fixnum）、Symbol、true、false、nil は
  # ヒープにオブジェクトを確保せず、値自体がポインタに埋め込まれる。
  # これを「即値」（immediate value）と呼ぶ。
  #
  # 即値の特徴：
  # - 同じ値は常に同じ object_id を返す
  # - dup や clone ができない（する必要がない）
  # - freeze 状態は常に true
  def demonstrate_immediate_values
    # 整数の object_id は 2n + 1 のパターンに従う（CRuby実装）
    int_ids = (0..4).map { |n| [n, n.object_id] }

    # Symbol は同じ名前なら常に同じ object_id
    sym_a = :hello
    sym_b = :hello

    {
      # 整数は即値なので object_id にパターンがある
      integer_object_ids: int_ids,
      # 同じ整数値は常に同一オブジェクト
      same_integer_identity: 42.equal?(42),
      # Symbol も即値（同じ名前 = 同じオブジェクト）
      symbol_same_object: sym_a.equal?(sym_b),
      symbol_same_id: sym_a.equal?(sym_b),
      # true, false, nil も即値
      true_frozen: true.frozen?,
      false_frozen: false.frozen?,
      nil_frozen: nil.frozen?,
      # 即値の固定 object_id（Ruby 3.4 での値）
      true_id: true.object_id, # => 20
      false_id: false.object_id, # => 0
      nil_id: nil.object_id      # => 4
    }
  end

  # === オブジェクトの同一性と等価性 ===
  #
  # Rubyには4つの比較メソッドがあり、それぞれ意味が異なる：
  # - equal?  : オブジェクト同一性（同じ object_id か）。再定義してはならない。
  # - ==      : 値の等価性。多くのクラスで再定義される。
  # - eql?    : Hash キーとしての等価性。== より厳密（型変換しない）。
  # - hash    : eql? と対になるハッシュ値。eql? が true なら hash も同じでなければならない。
  def demonstrate_identity_vs_equality
    str_a = +'hello'
    str_b = +'hello'

    {
      # == は値が同じなら true（String#== は内容を比較）
      value_equal: str_a == str_b,
      # equal? はオブジェクトが同一（同じメモリ上のオブジェクト）でないと false
      identity_equal: str_a.equal?(str_b),
      # eql? は Hash のキー比較に使われる（型変換なし）
      eql_same_type: str_a.eql?(str_b),
      # 整数と浮動小数点数: == は型変換して比較、eql? はしない
      int_float_equal: 1 == 1.0, # rubocop:disable Lint/FloatComparison
      int_float_eql: 1.eql?(1.0), # rubocop:disable Lint/FloatComparison
      # eql? が true なら hash も一致しなければならない（Hash の契約）
      hash_contract: str_a.eql?(str_b) && str_a.hash == str_b.hash,
      # Symbol は即値なので equal? も true
      symbol_identity: :test.equal?(:test)
    }
  end

  # === フリーズとイミュータビリティ ===
  #
  # freeze メソッドでオブジェクトを凍結すると、
  # そのオブジェクトへの破壊的変更が禁止される。
  # 凍結は不可逆で、一度凍結したオブジェクトは解凍できない。
  #
  # frozen_string_literal: true プラグマは、ファイル内のすべての
  # 文字列リテラルを自動的にフリーズする。
  def demonstrate_frozen_objects
    # frozen_string_literal: true の影響で文字列リテラルはフリーズ済み
    frozen_str = 'frozen by pragma'
    mutable_str = +'mutable string' # 単項+でフリーズを回避

    # 配列のフリーズ
    arr = [1, 2, 3]
    arr.freeze

    # フリーズされたオブジェクトへの変更は FrozenError を発生させる
    frozen_error_raised = begin
      arr << 4
      false
    rescue FrozenError
      true
    end

    # dup はフリーズを解除したコピーを返す
    duped = arr.dup

    {
      # frozen_string_literal プラグマの効果
      literal_frozen: frozen_str.frozen?,
      mutable_not_frozen: !mutable_str.frozen?,
      # フリーズされたオブジェクトへの変更は例外
      frozen_error_raised: frozen_error_raised,
      # dup はフリーズを解除する
      duped_not_frozen: !duped.frozen?,
      duped_content: duped,
      # clone はフリーズ状態を保持する
      cloned_frozen: arr.clone.frozen?,
      # freeze は不可逆
      still_frozen_after: arr.frozen?
    }
  end

  # === クラスもオブジェクトである ===
  #
  # Rubyではクラスは Class クラスのインスタンスである。
  # Class.new で動的にクラスを生成でき、メタプログラミングの基盤となる。
  #
  # クラス階層:
  #   クラス → Class のインスタンス
  #   Class → Module のサブクラス
  #   Module → Object のサブクラス
  def demonstrate_class_as_object
    # Class.new で無名クラスを動的に生成
    dynamic_class = Class.new do
      def hello
        'dynamic hello'
      end
    end

    instance = dynamic_class.new

    # クラスにメソッドを動的に追加
    dynamic_class.define_method(:world) do
      'dynamic world'
    end

    {
      # クラスは Class のインスタンス
      string_is_class_instance: String.is_a?(Class),
      class_is_class_instance: Class.is_a?(Class),
      # Class のスーパークラスは Module
      class_superclass: Class.superclass,
      # Module のスーパークラスは Object
      module_superclass: Module.superclass,
      # 動的に生成したクラスも正常に動作する
      dynamic_instance_hello: instance.hello,
      dynamic_instance_world: instance.world,
      # クラスの class メソッドは常に Class を返す
      class_of_string: String.class,
      class_of_class: Class.class,
      # クラスもオブジェクトなので object_id を持つ
      class_has_object_id: String.object_id.is_a?(Integer)
    }
  end
end
