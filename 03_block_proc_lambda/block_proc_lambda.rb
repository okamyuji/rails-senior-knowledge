# frozen_string_literal: true

# Block、Proc、Lambda の違いを理解するための教材モジュール
#
# Ruby における無名関数（クロージャ）の3つの形態：
# - Block: メソッド呼び出しに付随する特殊な構文
# - Proc: Block をオブジェクト化したもの
# - Lambda: 厳密な引数チェックを行う Proc の一種
module BlockProcLambda
  module_function

  # === ブロック基礎 ===

  # yield でブロックを呼び出す暗黙的ブロック
  # ブロックはメソッド呼び出し時に do...end や {...} で渡される
  def implicit_block_with_yield
    results = []
    results << yield(1)
    results << yield(2)
    results << yield(3)
    results
  end

  # block_given? でブロックの有無を確認する
  # ブロックが渡されない場合の安全なフォールバックパターン
  def safe_block_check
    if block_given?
      yield(42)
    else
      :no_block_given
    end
  end

  # &block で明示的にブロックを Proc オブジェクトとして受け取る
  # ブロックを変数として保持・他メソッドに渡す場合に使用
  def explicit_block_capture(&block)
    {
      class_name: block.class.name,
      is_lambda: block.lambda?,
      call_result: block.call(10)
    }
  end

  # 暗黙的ブロックと明示的ブロックの比較
  # &block は Proc オブジェクトに変換されるため、若干のオーバーヘッドがある
  def implicit_vs_explicit_demo
    # 暗黙的：yield は内部的にブロックを呼び出す（高速）
    implicit_result = implicit_block_with_yield { |n| n * 10 }

    # 明示的：&block で Proc オブジェクトに変換して呼び出す
    explicit_result = explicit_block_capture { |n| n * 10 }

    { implicit: implicit_result, explicit: explicit_result }
  end

  # === Proc vs Lambda ===

  # Proc.new と lambda と ->（スタビーラムダ記法）の生成方法を比較する
  # それぞれの特性の違いを確認する
  def proc_vs_lambda_creation
    # Proc.new で生成（lambda? は false）
    my_proc = Proc.new { |x| x.to_s } # rubocop:disable Style/Proc,Style/SymbolProc

    # Kernel#lambda で生成（lambda? は true）
    my_lambda = lambda { |x| x.to_s } # rubocop:disable Style/Lambda,Style/SymbolProc

    # ->（スタビーラムダ記法）で生成（Ruby 1.9+、lambda? は true）
    my_stabby = ->(x) { x.to_s } # rubocop:disable Style/SymbolProc

    {
      proc_class: my_proc.class.name,
      proc_is_lambda: my_proc.lambda?,
      lambda_class: my_lambda.class.name,
      lambda_is_lambda: my_lambda.lambda?,
      stabby_class: my_stabby.class.name,
      stabby_is_lambda: my_stabby.lambda?,
      proc_result: my_proc.call(:hello),
      lambda_result: my_lambda.call(:world),
      stabby_result: my_stabby.call(:ruby)
    }
  end

  # === 引数チェック（アリティ）の違い ===

  # Lambda は引数の数を厳密にチェックし、合わないと ArgumentError を発生させる
  # Proc は寛容で、余分な引数は無視し、不足分は nil で埋める
  def arity_checking_demo
    my_proc = proc { |a, b| [a, b] }
    my_lambda = ->(a, b) { [a, b] }

    results = {}

    # Proc: 引数が多くてもエラーにならない（余分は無視）
    results[:proc_extra_args] = my_proc.call(1, 2, 3)

    # Proc: 引数が少なくてもエラーにならない（不足分は nil）
    results[:proc_missing_args] = my_proc.call(1)

    # Lambda: 引数が合わないと ArgumentError
    results[:lambda_correct_args] = my_lambda.call(1, 2)

    begin
      my_lambda.call(1, 2, 3)
    rescue ArgumentError => e
      results[:lambda_extra_args_error] = e.message
    end

    begin
      my_lambda.call(1)
    rescue ArgumentError => e
      results[:lambda_missing_args_error] = e.message
    end

    # アリティ値の確認
    # Proc のアリティは負数（必須引数の数の反転 - 1）になる場合がある
    results[:proc_arity] = my_proc.arity
    results[:lambda_arity] = my_lambda.arity

    results
  end

  # === return の挙動の違い ===

  # Proc 内の return はそれを囲むメソッドから抜ける
  # これは Proc がブロックの延長である性質による
  def return_in_proc_demo
    my_proc = proc { return :from_proc }
    my_proc.call
    # ここには到達しない（Proc の return がメソッドを抜ける）
    :after_proc
  end

  # Lambda 内の return は Lambda 自身からのみ抜ける
  # Lambda はメソッドに近い振る舞いをする
  def return_in_lambda_demo
    my_lambda = -> { :from_lambda }
    my_lambda.call
    # ここに到達する（Lambda の return は Lambda 内で完結）
    :after_lambda
  end

  # Proc と Lambda の return 挙動を比較する
  def return_behavior_comparison
    {
      proc_return: return_in_proc_demo,
      lambda_return: return_in_lambda_demo
    }
  end

  # === クロージャとしての性質 ===

  # ブロック・Proc・Lambda は定義された時点のスコープ（束縛）をキャプチャする
  # これにより外側の変数にアクセスし続けることができる
  def closure_demo
    counter = 0

    incrementer = -> { counter += 1 }
    reader = -> { counter }

    incrementer.call
    incrementer.call
    incrementer.call

    {
      counter_value: reader.call,
      same_binding: true
    }
  end

  # クロージャが束縛（Binding）を保持することを示す
  # Proc は定義時のローカル変数への参照を保持する
  def binding_capture_demo
    local_var = 'captured'
    my_proc = proc { local_var }

    # Proc 経由で元のスコープの変数にアクセス
    result_from_proc = my_proc.call

    # binding 経由でもアクセス可能（教材用のデモ）
    # 注意: Binding#eval は任意コード実行が可能なため、本番コードでは避けること
    proc_binding = my_proc.binding
    result_from_binding = proc_binding.local_variable_get(:local_var)

    {
      from_proc: result_from_proc,
      from_binding: result_from_binding,
      binding_class: proc_binding.class.name
    }
  end

  # === Method オブジェクト ===

  # method(:name) でメソッドを Method オブジェクトとして取得する
  # & で Proc に変換してブロック引数として渡せる
  def method_object_demo
    # method(:name) で Method オブジェクト取得
    upcase_method = 'hello'.method(:upcase)

    results = {
      method_class: upcase_method.class.name,
      method_call: upcase_method.call,
      method_arity: upcase_method.arity
    }

    # & で Proc に変換して使う
    words = %w[hello world ruby]
    results[:map_with_method] = words.map(&method(:itself_helper))

    # Method#to_proc で明示的に変換
    results[:to_proc_class] = upcase_method.to_proc.class.name

    results
  end

  # method_object_demo のヘルパー
  def itself_helper(str)
    str.upcase
  end

  # UnboundMethod の実演
  # インスタンスに束縛されていないメソッドオブジェクト
  def unbound_method_demo
    unbound = String.instance_method(:length)

    # bind_call で特定のインスタンスに束縛して呼び出す（Ruby 2.7+）
    result = unbound.bind_call('hello')

    {
      unbound_class: unbound.class.name,
      bound_result: result,
      owner: unbound.owner.name
    }
  end

  # === カリー化 ===

  # Proc#curry で部分適用（カリー化）を実現する
  # 引数を段階的に渡して最終的に実行する関数型プログラミングのパターン
  def currying_demo
    # 3引数の Lambda をカリー化
    multiply_add = ->(a, b, c) { (a * b) + c }
    curried = multiply_add.curry

    # 段階的に引数を適用
    step1 = curried.call(2) # a = 2 を固定
    step2 = step1.call(3)          # b = 3 を固定
    final_result = step2.call(4)   # c = 4 で実行: 2 * 3 + 4 = 10

    # 一度に全部渡すことも可能
    direct_result = curried.call(2, 3, 4)

    # 部分適用のユースケース：設定値の固定
    add_tax = ->(rate, price) { (price * (1 + rate)).round(2) }
    add_tax_10 = add_tax.curry.call(0.1)

    {
      step_by_step: final_result,
      direct: direct_result,
      tax_100: add_tax_10.call(100),
      tax_250: add_tax_10.call(250),
      is_curried: curried.class.name
    }
  end

  # === メモリに関する考慮事項 ===

  # クロージャは外側のスコープへの参照を保持し続ける
  # これにより、意図せず大きなオブジェクトが GC されないことがある
  def memory_leak_pattern_demo
    # 悪い例：巨大な文字列への参照を保持してしまう
    large_data = 'x' * 1000
    leaky_proc = proc { large_data.length }

    # 良い例：必要な値だけをキャプチャする
    captured_length = large_data.length
    safe_proc = proc { captured_length }

    # leaky_proc の binding は large_data への参照を保持している
    leaky_binding = leaky_proc.binding
    has_large_data = leaky_binding.local_variable_defined?(:large_data)

    {
      leaky_result: leaky_proc.call,
      safe_result: safe_proc.call,
      leaky_captures_large_data: has_large_data,
      safe_captures_only_length: safe_proc.binding.local_variable_get(:captured_length)
    }
  end

  # コールバック登録パターンにおけるメモリリーク防止
  # コールバックの寿命管理を意識する
  def callback_lifecycle_demo
    callbacks = []

    # コールバックの登録
    register = ->(name, &block) { callbacks << { name: name, callback: block } }

    register.call('on_save') { :saved }
    register.call('on_load') { :loaded }

    # コールバックの実行
    results = callbacks.map { |cb| [cb[:name], cb[:callback].call] }

    # コールバックの解除（メモリリーク防止）
    callbacks.clear

    {
      callback_results: results,
      callbacks_cleared: callbacks.empty?
    }
  end
end
