# frozen_string_literal: true

require_relative '../spec/spec_helper'
require_relative 'refinements'

RSpec.describe RefinementsDemo do
  # ==========================================================================
  # 1. 基本的な Refinement の動作確認
  # ==========================================================================
  describe '基本的な Refinement' do
    describe RefinementsDemo::StringDemo do
      it 'using スコープ内で to_boolean が動作する' do
        expect(described_class.convert_to_boolean('true')).to be true
        expect(described_class.convert_to_boolean('yes')).to be true
        expect(described_class.convert_to_boolean('1')).to be true
        expect(described_class.convert_to_boolean('on')).to be true
      end

      it '偽値の文字列を false に変換する' do
        expect(described_class.convert_to_boolean('false')).to be false
        expect(described_class.convert_to_boolean('no')).to be false
        expect(described_class.convert_to_boolean('0')).to be false
        expect(described_class.convert_to_boolean('off')).to be false
      end

      it '不明な文字列に対して nil を返す' do
        expect(described_class.convert_to_boolean('maybe')).to be_nil
        expect(described_class.convert_to_boolean('unknown')).to be_nil
      end

      it 'shout メソッドが動作する' do
        expect(described_class.shout('hello')).to eq('HELLO!!!')
      end
    end
  end

  # ==========================================================================
  # 2. レキシカルスコープの隔離
  # ==========================================================================
  describe 'レキシカルスコープ' do
    it 'using スコープ外では Refined メソッドが使えない' do
      # StringExtensions の to_boolean はこのスコープでは使えない
      expect('true'.respond_to?(:to_boolean)).to be false
    end

    it 'using スコープ外で Refined メソッドを呼ぶと NoMethodError になる' do
      expect { 'true'.to_boolean }.to raise_error(NoMethodError)
    end

    describe RefinementsDemo::ScopedDemo do
      it 'Integer#days が using スコープ内で動作する' do
        expect(described_class.one_week_in_seconds).to eq(604_800)
      end

      it 'Integer#hours が using スコープ内で動作する' do
        expect(described_class.two_hours_in_seconds).to eq(7_200)
      end

      it 'Integer#minutes が using スコープ内で動作する' do
        expect(described_class.thirty_minutes_in_seconds).to eq(1_800)
      end
    end

    it 'ScopedDemo の外では Integer#days が使えない' do
      # ActiveSupport がロードされている場合は Integer#days がグローバルに定義されるためスキップ
      skip 'ActiveSupport が Integer#days をグローバルに定義しているため' if defined?(ActiveSupport)
      expect(described_class.integer_days_available_outside?).to be false
    end
  end

  # ==========================================================================
  # 3. Refinement と super（既存メソッドのラッピング）
  # ==========================================================================
  describe 'Refinement 内での super' do
    describe RefinementsDemo::ArrayInspector do
      it 'super を使って元の inspect をラップできる' do
        result = described_class.inspect_array([1, 2, 3])
        expect(result).to include('Refined Array: size=3')
        expect(result).to include('[1, 2, 3]')
      end

      it '空配列でも正しく動作する' do
        result = described_class.inspect_array([])
        expect(result).to include('Refined Array: size=0')
      end
    end
  end

  # ==========================================================================
  # 4. モジュール内での Refinement 使用
  # ==========================================================================
  describe 'モジュール内での Refinement' do
    describe RefinementsDemo::PriceCalculator do
      it '通貨フォーマットに変換できる' do
        expect(described_class.format_price(19.99)).to eq('$19.99')
      end

      it '日本円フォーマットに変換できる' do
        expect(described_class.format_price_yen(1980.5)).to eq("\u00A51980")
      end

      it '整数値も正しくフォーマットされる' do
        expect(described_class.format_price(100)).to eq('$100.00')
      end
    end
  end

  # ==========================================================================
  # 5. 実践パターン: コアクラスの安全な拡張
  # ==========================================================================
  describe 'コアクラスの安全な拡張' do
    describe RefinementsDemo::TextProcessor do
      it 'キャメルケースをスネークケースに変換できる' do
        expect(described_class.normalize_class_name('UserAccount')).to eq('user_account')
        expect(described_class.normalize_class_name('HTTPClient')).to eq('http_client')
        expect(described_class.normalize_class_name('MyXMLParser')).to eq('my_xml_parser')
      end

      it 'スネークケースをキャメルケースに変換できる' do
        expect(described_class.to_class_style('user_account')).to eq('UserAccount')
        expect(described_class.to_class_style('http_client')).to eq('HttpClient')
      end

      it '文字列を切り詰めて省略記号を付ける' do
        long_text = 'これは非常に長いテキストです。切り詰めが必要です。'
        result = described_class.preview(long_text, max: 20)
        expect(result.length).to eq(20)
        expect(result).to end_with('...')
      end

      it '最大長以下の文字列はそのまま返す' do
        short_text = '短い'
        expect(described_class.preview(short_text, max: 50)).to eq('短い')
      end
    end

    describe RefinementsDemo::StatisticsCalculator do
      it '要素の出現回数をカウントする' do
        result = described_class.calculate_frequency(%w[a b a c b a])
        expect(result).to eq('a' => 3, 'b' => 2, 'c' => 1)
      end

      it '平均値を計算する' do
        expect(described_class.calculate_mean([10, 20, 30])).to eq(20.0)
      end

      it '空配列の平均値は 0.0 を返す' do
        expect(described_class.calculate_mean([])).to eq(0.0)
      end
    end
  end

  # ==========================================================================
  # 6. Refinement の制限事項と Ruby 3.2+ での改善
  # ==========================================================================
  describe '制限事項と Ruby 3.2+ での改善' do
    describe RefinementsDemo::LimitationExplorer do
      it '直接呼び出しは成功する' do
        expect(described_class.direct_call).to eq('refined!')
      end

      # Ruby 3.2+ で改善: respond_to? が Refined メソッドを検出する
      it 'Ruby 3.2+ では respond_to? が Refined メソッドを検出する' do
        expect(described_class.respond_to_check).to be true
      end

      # Ruby 3.2+ で改善: send が Refinement を経由する
      it 'Ruby 3.2+ では send が Refinement を経由する' do
        expect(described_class.send_call).to eq('refined!')
      end

      # Ruby 3.2+ で改善: method() で Method オブジェクトを取得できる
      it 'Ruby 3.2+ では method() で Refined メソッドの Method オブジェクトを取得できる' do
        method_obj = described_class.method_object_check
        expect(method_obj).to be_a(Method)
        expect(method_obj.call).to eq('refined!')
      end
    end

    describe RefinementsDemo::OutsideScopeExplorer do
      it 'using スコープ外からの直接呼び出しは失敗する' do
        result = described_class.try_direct_call
        expect(result).to include('NoMethodError')
      end

      it 'using スコープ外からの send も失敗する' do
        result = described_class.try_send
        expect(result).to include('NoMethodError')
      end

      it 'ancestors に Refinement は表示されない' do
        expect(described_class.refinement_in_ancestors?).to be false
      end
    end

    it 'using をメソッド内で呼ぶことはできない' do
      # using はトップレベルまたはクラス/モジュール定義内でのみ有効
      # メソッド内で呼ぶと RuntimeError が発生する
      expect do
        Class.new do
          define_method(:try_using) do
            self.class.send(:using, RefinementsDemo::StringExtensions)
          end
        end.new.try_using
      end.to raise_error(RuntimeError)
    end
  end

  # ==========================================================================
  # 7. Gem 設計パターンでの活用
  # ==========================================================================
  describe 'Gem 設計パターン' do
    describe RefinementsDemo::MyGem do
      it '通常のモジュールメソッドとして duration をパースできる' do
        expect(described_class.parse_duration('3d')).to eq(259_200)
        expect(described_class.parse_duration('2h')).to eq(7_200)
        expect(described_class.parse_duration('30m')).to eq(1_800)
      end

      it '不正なフォーマットで ArgumentError を発生させる' do
        expect { described_class.parse_duration('invalid') }.to raise_error(ArgumentError)
      end
    end

    describe RefinementsDemo::DurationCalculator do
      it 'Refinement 経由で String#to_duration_seconds を使える' do
        # 1d=86400 + 2h=7200 + 30m=1800 = 95400
        expect(described_class.total_seconds('1d', '2h', '30m')).to eq(95_400)
      end

      it '直接 String#to_duration_seconds は使えない（スコープ外）' do
        expect('1d'.respond_to?(:to_duration_seconds)).to be false
      end
    end
  end

  # ==========================================================================
  # 8. Hash の安全な拡張（ConfigLoader）
  # ==========================================================================
  describe 'Hash の安全な拡張' do
    describe RefinementsDemo::ConfigLoader do
      it '文字列キーをシンボルに変換する' do
        input = { 'name' => 'Alice', 'age' => 30 }
        expect(described_class.load(input)).to eq(name: 'Alice', age: 30)
      end

      it 'ネストしたハッシュも再帰的に変換する' do
        input = { 'user' => { 'name' => 'Bob', 'address' => { 'city' => 'Tokyo' } } }
        expected = { user: { name: 'Bob', address: { city: 'Tokyo' } } }
        expect(described_class.load(input)).to eq(expected)
      end

      it 'テストスコープでは Hash#deep_symbolize_keys は使えない' do
        # ActiveSupport がロードされている場合は Hash#deep_symbolize_keys がグローバルに定義されるためスキップ
        skip 'ActiveSupport が Hash#deep_symbolize_keys をグローバルに定義しているため' if defined?(ActiveSupport)
        expect({}.respond_to?(:deep_symbolize_keys)).to be false
      end
    end
  end
end
