# frozen_string_literal: true

# ============================================================================
# Ruby メソッド探索チェーン（Method Lookup Chain）
# ============================================================================
#
# Rubyがメソッド呼び出しを解決する際の探索順序を理解することは、
# シニアRailsエンジニアにとって必須のスキルである。
#
# 探索順序: クラス → prepend されたモジュール（クラスの前） →
#          include されたモジュール（逆順・LIFO） → スーパークラス →
#          ... → BasicObject
#
# この知識は以下の場面で必要となる:
# - ActiveSupport::Concern の動作原理の理解
# - デコレータパターンやミックスインの設計
# - メソッド衝突のデバッグ
# - method_missing を使った動的ディスパッチの実装
# ============================================================================

module MethodLookup
  # ==========================================================================
  # 1. 基本的なメソッド探索順序
  # ==========================================================================
  #
  # Rubyのメソッド探索はクラスから始まり、include されたモジュール、
  # スーパークラスの順に辿る。Module#ancestors でチェーン全体を確認できる。

  module Greetable
    def greeting
      'Greetable#greeting'
    end
  end

  module Printable
    def greeting
      'Printable#greeting'
    end
  end

  class BaseEntity
    def greeting
      'BaseEntity#greeting'
    end
  end

  # include の順序: 最後に include されたモジュールが先に探索される（LIFO）
  class User < BaseEntity
    include Greetable
    include Printable

    def greeting
      'User#greeting'
    end
  end

  # ancestors チェーンを返す（検証可能な配列）
  def self.user_ancestors
    User.ancestors
  end

  # クラス自身のメソッドが最優先であることを確認
  def self.user_greeting
    User.new.greeting
  end

  # ==========================================================================
  # 2. include vs prepend
  # ==========================================================================
  #
  # include: モジュールをクラスの「後ろ」（ancestors チェーン上でクラスの次）に挿入
  # prepend: モジュールをクラスの「前」（ancestors チェーン上でクラスの前）に挿入
  #
  # prepend は AOP（アスペクト指向）的なパターンに有用。
  # Railsでは ActiveSupport の alias_method_chain の代替として使われる。

  module LoggingInclude
    def action
      'LoggingInclude#action'
    end
  end

  module LoggingPrepend
    def action
      'LoggingPrepend#action'
    end
  end

  # include の場合: クラスのメソッドが優先される
  class ServiceWithInclude
    include LoggingInclude

    def action
      'ServiceWithInclude#action'
    end
  end

  # prepend の場合: モジュールのメソッドが優先される
  class ServiceWithPrepend
    prepend LoggingPrepend

    def action
      'ServiceWithPrepend#action'
    end
  end

  def self.include_ancestors
    ServiceWithInclude.ancestors
  end

  def self.prepend_ancestors
    ServiceWithPrepend.ancestors
  end

  def self.include_action
    ServiceWithInclude.new.action
  end

  def self.prepend_action
    ServiceWithPrepend.new.action
  end

  # ==========================================================================
  # 3. prepend + super による元メソッドのラッピング
  # ==========================================================================
  #
  # prepend の真価は super を使って元のメソッドをラップできること。
  # これにより、メソッドの前後に処理を追加できる（デコレータパターン）。

  module TimingDecorator
    def process(value)
      result = super # 元の process メソッドを呼び出す
      { original_result: result, decorated: true }
    end
  end

  class DataProcessor
    prepend TimingDecorator

    def process(value)
      value * 2
    end
  end

  def self.decorated_process(value)
    DataProcessor.new.process(value)
  end

  # ==========================================================================
  # 4. 複数 include の探索順序（LIFO）
  # ==========================================================================
  #
  # 複数のモジュールを include した場合、最後に include したものが
  # ancestors チェーンでクラスの直後に来る（Last In, First Out）。

  module ModuleA
    def identity
      'ModuleA'
    end
  end

  module ModuleB
    def identity
      'ModuleB'
    end
  end

  module ModuleC
    def identity
      'ModuleC'
    end
  end

  class MultiIncluder
    include ModuleA
    include ModuleB
    include ModuleC

    # ancestors: [MultiIncluder, ModuleC, ModuleB, ModuleA, Object, ...]
    # ModuleC が最後に include されたので、最初に探索される
  end

  def self.multi_include_ancestors
    MultiIncluder.ancestors
  end

  # クラス自身にメソッドがない場合、最後に include した ModuleC が呼ばれる
  def self.multi_include_identity
    MultiIncluder.new.identity
  end

  # ==========================================================================
  # 5. super キーワードの動作
  # ==========================================================================
  #
  # super: 引数をそのまま親に転送（暗黙的引数転送）
  # super(): 引数なしで親を呼び出す
  # super(args): 明示的に引数を指定して親を呼び出す
  #
  # この違いを理解していないと、意図しない引数が渡されるバグの原因となる。

  module SuperBase
    def calculate(x, y)
      x + y
    end
  end

  module SuperMiddle
    def calculate(x, y)
      # super は x, y をそのまま転送する
      super * 2
    end
  end

  class SuperDemo
    include SuperBase
    include SuperMiddle
  end

  def self.super_chain_result(x, y)
    SuperDemo.new.calculate(x, y)
  end

  # super() vs super の違いを示すクラス
  module DefaultProvider
    def config(options = {})
      { defaults: true }.merge(options)
    end
  end

  class ExplicitSuperDemo
    include DefaultProvider

    # super() は引数なしで呼び出す → options はデフォルト値 {} になる
    def config(_options = {})
      result = super() # 引数なしで呼び出し
      result.merge(custom: true)
    end
  end

  class ImplicitSuperDemo
    include DefaultProvider

    # super は引数をそのまま転送する
    def config(options = {})
      result = super # options をそのまま転送
      result.merge(custom: true)
    end
  end

  def self.explicit_super_config(options = {})
    ExplicitSuperDemo.new.config(options)
  end

  def self.implicit_super_config(options = {})
    ImplicitSuperDemo.new.config(options)
  end

  # ==========================================================================
  # 6. method_missing と respond_to_missing?
  # ==========================================================================
  #
  # method_missing を使う場合は、必ず respond_to_missing? も実装すること。
  # これを怠ると respond_to? が正しく動作せず、予期しない動作の原因となる。
  #
  # 注意点:
  # - method_missing は探索チェーンの最後に呼ばれるため、パフォーマンスに影響
  # - NoMethodError を適切に raise すること（対象外のメソッドは super に委譲）
  # - デバッグが困難になるため、可能であれば define_method を検討すること

  class DynamicFinder
    ALLOWED_ATTRIBUTES = %i[name email age].freeze

    def method_missing(method_name, *args)
      # find_by_xxx パターンにマッチするか確認
      if method_name.to_s =~ /\Afind_by_(\w+)\z/
        attribute = Regexp.last_match(1).to_sym
        return find_by_attribute(attribute, args.first) if ALLOWED_ATTRIBUTES.include?(attribute)
      end

      # マッチしないメソッドは super に委譲（NoMethodError を発生させる）
      super
    end

    def respond_to_missing?(method_name, include_private = false)
      if method_name.to_s =~ /\Afind_by_(\w+)\z/
        attribute = Regexp.last_match(1).to_sym
        return ALLOWED_ATTRIBUTES.include?(attribute)
      end

      super
    end

    private

    def find_by_attribute(attribute, value)
      { attribute: attribute, value: value, found: true }
    end
  end

  def self.dynamic_finder_example
    finder = DynamicFinder.new
    {
      find_by_name: finder.find_by_name('Alice'),
      find_by_email: finder.find_by_email('alice@example.com'),
      responds_to_find_by_name: finder.respond_to?(:find_by_name),
      responds_to_find_by_age: finder.respond_to?(:find_by_age),
      responds_to_find_by_unknown: finder.respond_to?(:find_by_unknown),
      method_object_available: finder.method(:find_by_name).is_a?(Method)
    }
  end

  # ==========================================================================
  # 7. Module#ancestors による探索チェーンの可視化
  # ==========================================================================
  #
  # ancestors メソッドは、メソッド探索チェーン全体を配列として返す。
  # デバッグ時に非常に有用。

  module Serializable
    def serialize
      'serialized'
    end
  end

  module Cacheable
    def cache_key
      'cache_key'
    end
  end

  class ApplicationRecord
    include Serializable
  end

  class Product < ApplicationRecord
    include Cacheable
  end

  def self.product_ancestors
    Product.ancestors
  end

  # ancestors チェーンにおけるモジュールの位置を確認するヘルパー
  def self.module_position_in_ancestors(klass, mod)
    klass.ancestors.index(mod)
  end

  # ==========================================================================
  # 8. Refinements による探索順序の変更（プレビュー）
  # ==========================================================================
  #
  # Refinements はファイルスコープでメソッドの探索順序を変更する仕組み。
  # 詳細はトピック09で扱う。ここでは基本的な概念のみ紹介。
  #
  # Refinements の特徴:
  # - using で有効化したスコープ内でのみ適用される
  # - グローバルな影響を与えないため、モンキーパッチより安全
  # - ancestors には表示されない（Ruby の仕様）

  module StringRefinement
    refine String do
      def shout
        "#{upcase}!!!"
      end
    end
  end

  # Refinements のデモ用クラス
  # using はクラス/モジュール定義内、またはトップレベルで使用する
  class RefinementDemo
    using StringRefinement

    def self.shout(text)
      text.shout
    end

    # Refinements は ancestors に表示されない
    def self.string_ancestors
      String.ancestors
    end
  end

  def self.refinement_shout(text)
    RefinementDemo.shout(text)
  end

  def self.refinement_not_in_ancestors
    # StringRefinement は String.ancestors には含まれない
    RefinementDemo.string_ancestors.include?(StringRefinement)
  end
end
