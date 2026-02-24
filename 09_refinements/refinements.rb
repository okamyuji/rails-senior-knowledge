# frozen_string_literal: true

# ============================================================================
# Ruby Refinements - 安全なモンキーパッチの仕組み
# ============================================================================
#
# Refinements は Ruby 2.0 で導入され、2.1 で正式化された機能である。
# 従来のモンキーパッチ（オープンクラス）がグローバルに影響を及ぼすのに対し、
# Refinements はレキシカルスコープ内でのみ有効な安全な拡張手段を提供する。
#
# シニアRailsエンジニアにとって、以下の理由で重要な知識である:
# - gem設計時にグローバル名前空間を汚染せずに便利メソッドを提供できる
# - テスト環境でのスタブやモックの代替手段となる
# - ActiveSupport のコア拡張の代替アプローチとして理解しておくべき
# ============================================================================

module RefinementsDemo
  # ==========================================================================
  # 1. 基本的な Refinement の定義と使用
  # ==========================================================================
  #
  # Module#refine でクラスを拡張し、using キーワードで有効化する。
  # refine ブロック内で定義したメソッドは、using を呼んだスコープでのみ利用可能。

  module StringExtensions
    refine String do
      # 文字列を真偽値に変換する便利メソッド
      def to_boolean
        case strip.downcase
        when 'true', 'yes', '1', 'on'
          true
        when 'false', 'no', '0', 'off'
          false
        end
      end

      # 文字列を叫び声に変換
      def shout
        "#{upcase}!!!"
      end
    end
  end

  # using を呼んだクラス/モジュールのレキシカルスコープ内でのみ有効
  class StringDemo
    using StringExtensions

    def self.convert_to_boolean(str)
      str.to_boolean
    end

    def self.shout(str)
      str.shout
    end

    # Refinement はこのクラス定義内でのみ有効
    def self.refinement_active?
      'test'.respond_to?(:to_boolean)
    end
  end

  # ==========================================================================
  # 2. レキシカルスコープの挙動
  # ==========================================================================
  #
  # Refinements の最も重要な特性: using を呼んだファイルまたはモジュール定義の
  # レキシカルスコープ内でのみ有効。動的ディスパッチ（send等）では無効。
  #
  # これは「安全性」の核心部分であり、他のコードへの影響を防ぐ。

  module IntegerExtensions
    refine Integer do
      # ActiveSupport の days メソッドに似た便利メソッド
      def days
        self * 86_400
      end

      def hours
        self * 3_600
      end

      def minutes
        self * 60
      end
    end
  end

  class ScopedDemo
    using IntegerExtensions

    # このクラス内では Integer#days が使える
    def self.one_week_in_seconds
      7.days
    end

    def self.two_hours_in_seconds
      2.hours
    end

    def self.thirty_minutes_in_seconds
      30.minutes
    end
  end

  # ScopedDemo の外では Integer#days は使えないことを確認する
  # （直接呼び出すと NoMethodError になる）
  def self.integer_days_available_outside?
    1.respond_to?(:days)
  end

  # ==========================================================================
  # 3. Refinement vs モンキーパッチの比較
  # ==========================================================================
  #
  # オープンクラスによるモンキーパッチはグローバルに影響を及ぼすため危険。
  # 特に gem がコアクラスを変更すると、他の gem やアプリケーションに
  # 予期しない影響を与える可能性がある。
  #
  # Refinements はこの問題を解決する。

  # 危険なモンキーパッチの例（このモジュール内では実行しない）
  # class String
  #   def to_boolean  # グローバルに影響 - 全コードで String#to_boolean が使える
  #     ...
  #   end
  # end

  # 安全な Refinement の例
  module SafeHashExtensions
    refine Hash do
      # ネストしたハッシュのキーをすべてシンボルに変換
      def deep_symbolize_keys
        each_with_object({}) do |(key, value), result|
          new_key = key.respond_to?(:to_sym) ? key.to_sym : key
          result[new_key] = value.is_a?(Hash) ? value.deep_symbolize_keys : value
        end
      end
    end
  end

  # deep_symbolize_keys を使いたいクラスだけが using する
  class ConfigLoader
    using SafeHashExtensions

    def self.load(raw_hash)
      raw_hash.deep_symbolize_keys
    end
  end

  # ==========================================================================
  # 4. Refinement と継承・super の関係
  # ==========================================================================
  #
  # Refinement 内で super を呼ぶと、元のクラスのメソッドが呼ばれる。
  # これにより、既存メソッドをラップする形で拡張できる。

  module InspectRefinement
    refine Array do
      # 元の inspect をラップして追加情報を付与
      def inspect
        "[Refined Array: size=#{size}] #{super}"
      end
    end
  end

  class ArrayInspector
    using InspectRefinement

    def self.inspect_array(arr)
      arr.inspect
    end
  end

  # ==========================================================================
  # 5. モジュール内での Refinement 使用
  # ==========================================================================
  #
  # Refinements はモジュール定義内でも using できる。
  # そのモジュールのレキシカルスコープ内で有効になる。

  module NumericFormatting
    refine Numeric do
      def to_currency(symbol: '$')
        "#{symbol}#{format('%.2f', self)}"
      end
    end
  end

  module PriceCalculator
    using NumericFormatting

    def self.format_price(amount)
      amount.to_currency
    end

    def self.format_price_yen(amount)
      # 日本円は小数点以下不要なので整数フォーマット
      "\u00A5#{amount.to_i}"
    end
  end

  # ==========================================================================
  # 6. 実践的なパターン: コアクラスの安全な拡張
  # ==========================================================================
  #
  # gem 作者が利用者に便利メソッドを提供する際、
  # Refinement として提供すれば名前空間を汚染しない。

  # gem が提供する Refinement モジュール（公開API）
  module CoreExtensions
    module StringPatching
      refine String do
        # 文字列をスネークケースに変換
        def to_snake_case
          gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
            .gsub(/([a-z\d])([A-Z])/, '\1_\2')
            .downcase
        end

        # 文字列をキャメルケースに変換
        def to_camel_case
          split('_').map(&:capitalize).join
        end

        # 文字列を切り詰めて省略記号を付ける
        def truncate_with_ellipsis(max_length)
          return self if length <= max_length

          "#{self[0...(max_length - 3)]}..."
        end
      end
    end

    module ArrayPatching
      refine Array do
        # 要素の出現回数をカウントしてハッシュで返す
        def frequency_map
          each_with_object(Hash.new(0)) { |item, counts| counts[item] += 1 }
        end

        # 平均値を計算（数値配列用）
        def mean
          return 0.0 if empty?

          sum.to_f / size
        end
      end
    end
  end

  # 利用者側: 必要なモジュールだけ using する
  class TextProcessor
    using CoreExtensions::StringPatching

    def self.normalize_class_name(name)
      name.to_snake_case
    end

    def self.to_class_style(name)
      name.to_camel_case
    end

    def self.preview(text, max: 50)
      text.truncate_with_ellipsis(max)
    end
  end

  class StatisticsCalculator
    using CoreExtensions::ArrayPatching

    def self.calculate_frequency(arr)
      arr.frequency_map
    end

    def self.calculate_mean(arr)
      arr.mean
    end
  end

  # ==========================================================================
  # 7. Refinements の制限事項
  # ==========================================================================
  #
  # Refinements には以下の重要な制限がある:
  #
  # (a) using はメソッド内では呼べない（トップレベルまたはモジュール/クラス定義内のみ）
  #     def some_method
  #       using StringExtensions  # => RuntimeError が発生する
  #     end
  #
  # (b) using のスコープ外では Refined メソッドは一切使えない
  #     # using していないファイルやクラスからは呼べない
  #     "hello".to_boolean  # => NoMethodError
  #
  # (c) ancestors に Refinement は表示されない
  #     using StringExtensions
  #     String.ancestors  # Refinement モジュールは含まれない
  #
  # === Ruby バージョンによる挙動の変化 ===
  #
  # Ruby 3.2 以降、Refinements の制限が大幅に緩和された:
  # - respond_to? が Refined メソッドを検出するようになった（3.2+）
  # - send / public_send が Refinement を経由するようになった（3.2+）
  # - method() で Refined メソッドの Method オブジェクトを取得可能になった（3.2+）
  #
  # Ruby 3.1 以前では上記はすべて制限事項であった。
  # 古いバージョンとの互換性が必要な場合は注意が必要。

  module LimitationDemo
    refine String do
      def refined_method
        'refined!'
      end
    end
  end

  class LimitationExplorer
    using LimitationDemo

    # 直接呼び出しは成功する
    def self.direct_call
      'test'.refined_method
    end

    # Ruby 3.2+ では respond_to? が Refined メソッドを検出する
    # （Ruby 3.1 以前では false を返していた）
    def self.respond_to_check
      'test'.respond_to?(:refined_method)
    end

    # Ruby 3.2+ では send も Refinement を経由する
    # （Ruby 3.1 以前では NoMethodError になっていた）
    def self.send_call
      'test'.send(:refined_method)
    end

    # Ruby 3.2+ では method() も Refined メソッドを返す
    # （Ruby 3.1 以前では NameError になっていた）
    def self.method_object_check
      'test'.method(:refined_method)
    end
  end

  # using スコープ外からの呼び出しを試みるクラス（制限の実証）
  class OutsideScopeExplorer
    # using LimitationDemo していないので Refined メソッドは使えない
    def self.try_direct_call
      'test'.refined_method
    rescue NoMethodError => e
      "NoMethodError: #{e.message}"
    end

    def self.try_send
      'test'.send(:refined_method)
    rescue NoMethodError => e
      "NoMethodError: #{e.message}"
    end

    # ancestors に Refinement は表示されない
    def self.refinement_in_ancestors?
      String.ancestors.any? { |a| a.to_s.include?('LimitationDemo') }
    end
  end

  # ==========================================================================
  # 8. Gem 設計パターン: オプショナル Refinements
  # ==========================================================================
  #
  # gem 作者は以下のパターンで Refinement を提供できる:
  # 1. 基本機能は通常のクラス/モジュールとして提供
  # 2. コアクラスの便利メソッドは Refinement として別途提供
  # 3. 利用者は using で明示的にオプトインする
  #
  # これにより、グローバル名前空間を汚染せずに便利なAPIを提供できる。

  # gem のメイン機能（通常のモジュール）
  module MyGem
    # 基本的な機能は通常のモジュールメソッドとして提供
    def self.parse_duration(string)
      case string
      when /\A(\d+)d\z/ then Regexp.last_match(1).to_i * 86_400
      when /\A(\d+)h\z/ then Regexp.last_match(1).to_i * 3_600
      when /\A(\d+)m\z/ then Regexp.last_match(1).to_i * 60
      else
        raise ArgumentError, "Invalid duration format: #{string}"
      end
    end

    # オプショナルな Refinement（利用者が明示的に using する）
    module StringRefinements
      refine String do
        def to_duration_seconds
          MyGem.parse_duration(self)
        end
      end
    end
  end

  # 利用者側の使い方
  class DurationCalculator
    using MyGem::StringRefinements

    def self.total_seconds(*duration_strings)
      duration_strings.sum(&:to_duration_seconds)
    end
  end
end
