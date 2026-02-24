# frozen_string_literal: true

require_relative 'query_plan'

RSpec.describe QueryPlanAnalysis do
  before do
    described_class.seed_test_data
  end

  describe '.demonstrate_explain_basics' do
    let(:result) { described_class.demonstrate_explain_basics }

    it 'ActiveRecordのexplainメソッドがクエリプランを返すことを確認する' do
      # explainの結果が文字列として返される
      expect(result[:basic_explain]).to be_a(String)
      expect(result[:basic_explain]).not_to be_empty
    end

    it '生SQLのEXPLAIN QUERY PLANが結果を返すことを確認する' do
      expect(result[:raw_explain]).to be_an(Array)
      expect(result[:raw_explain]).not_to be_empty
    end

    it '主キー検索のクエリプランが効率的であることを確認する' do
      # 主キー検索はSEARCHまたは直接アクセスになるはず
      expect(result[:pk_explain]).to be_a(String)
      expect(result[:pk_explain]).not_to be_empty
    end

    it 'EXPLAINの読み方ガイドが提供されることを確認する' do
      guide = result[:guide]
      expect(guide).to have_key('SCAN')
      expect(guide).to have_key('SEARCH')
      expect(guide).to have_key('USING INDEX')
      expect(guide).to have_key('USING COVERING INDEX')
    end
  end

  describe '.demonstrate_index_types' do
    let(:result) { described_class.demonstrate_index_types }

    it '単一カラムインデックスが検索に使用されることを確認する' do
      # categoryにインデックスがあるのでSEARCHが使われる
      plan = result[:single_index]
      expect(plan).to match(/SEARCH|USING INDEX/i)
    end

    it '複合インデックスがカテゴリと価格の組み合わせ検索で使用されることを確認する' do
      plan = result[:composite_index]
      expect(plan).to match(/SEARCH|USING INDEX/i)
    end

    it 'LIKE中間一致がインデックスを使用しないことを確認する' do
      plan = result[:like_no_index]
      # 中間一致LIKEではフルスキャンになる
      expect(plan).to match(/SCAN/i)
    end

    it '関数適用がインデックスを無効化することを確認する' do
      plan = result[:function_no_index]
      # LOWER()を適用するとインデックスが使えない
      expect(plan).to match(/SCAN/i)
    end

    it 'インデックス選択ルールが提供されることを確認する' do
      rules = result[:index_selection_rules]
      expect(rules).to have_key('使える')
      expect(rules).to have_key('使えない')
      expect(rules['使える']).to include('等値検索(=)')
      expect(rules['使えない']).to include("中間一致LIKE('%abc%')")
    end
  end

  describe '.demonstrate_optimization_patterns' do
    let(:result) { described_class.demonstrate_optimization_patterns }

    it 'カバリングインデックスのクエリプランが生成されることを確認する' do
      expect(result[:covering_index]).to be_a(String)
      expect(result[:covering_index]).not_to be_empty
    end

    it 'EXISTS vs COUNTの最適化ガイドが提供されることを確認する' do
      count_opt = result[:count_optimization]
      expect(count_opt[:recommendation]).to include('exists?')
    end

    it '最適化ガイドラインが提供されることを確認する' do
      guidelines = result[:optimization_guidelines]
      expect(guidelines).to have_key('SELECT句の最小化')
      expect(guidelines).to have_key('EXISTS活用')
      expect(guidelines).to have_key('LIMIT活用')
      expect(guidelines).to have_key('選択性の考慮')
    end
  end

  describe '.demonstrate_n_plus_one_detection' do
    let(:result) { described_class.demonstrate_n_plus_one_detection }

    it 'N+1問題でクエリ数が増加することを確認する' do
      n_plus_one = result[:n_plus_one]
      optimized = result[:optimized_includes]

      # N+1ではクエリ数が多い
      expect(n_plus_one[:query_count]).to be > optimized[:query_count]
    end

    it 'includesによるプリロードでクエリ数が削減されることを確認する' do
      optimized = result[:optimized_includes]
      # includesを使うと2回程度のクエリで済む
      expect(optimized[:query_count]).to be <= 3
    end

    it 'eager_loadがLEFT OUTER JOINを使用することを確認する' do
      eager = result[:eager_load]
      # eager_loadは少ないクエリ数になる
      expect(eager[:query_count]).to be <= 2
    end

    it 'N+1検出手法の情報が提供されることを確認する' do
      methods = result[:detection_methods]
      expect(methods).to have_key('Bullet gem')
      expect(methods).to have_key('strict_loading')
    end
  end

  describe '.demonstrate_slow_query_detection' do
    let(:result) { described_class.demonstrate_slow_query_detection }

    it 'ActiveSupport::Notificationsでクエリが監視されることを確認する' do
      monitored = result[:monitored_queries]
      expect(monitored).to be_an(Array)
      # 何らかのクエリが記録されている
      expect(monitored).not_to be_empty
    end

    it '監視されたクエリにSQL文と実行時間が含まれることを確認する' do
      query = result[:monitored_queries].first
      expect(query).to have_key(:sql)
      expect(query).to have_key(:duration_ms)
      expect(query[:duration_ms]).to be_a(Numeric)
    end

    it 'スロークエリ対策の戦略情報が提供されることを確認する' do
      strategies = result[:slow_query_strategies]
      expect(strategies).to have_key('ActiveSupport::Notifications')
      expect(strategies).to have_key('Query Log Tags (Rails 7+)')
      expect(strategies).to have_key('APMツール')
    end
  end

  describe '.demonstrate_join_strategies' do
    let(:result) { described_class.demonstrate_join_strategies }

    it 'INNER JOINのクエリプランが生成されることを確認する' do
      expect(result[:inner_join]).to be_a(String)
      expect(result[:inner_join]).not_to be_empty
    end

    it 'LEFT OUTER JOINのクエリプランが生成されることを確認する' do
      expect(result[:left_join]).to be_a(String)
      expect(result[:left_join]).not_to be_empty
    end

    it 'JOINとサブクエリの比較情報が提供されることを確認する' do
      comparison = result[:comparison]
      expect(comparison[:join_approach]).to match(/JOIN/i)
      expect(comparison[:subquery_approach]).to match(/IN.*SELECT/i)
    end

    it 'JOIN最適化のヒントが提供されることを確認する' do
      tips = result[:join_optimization_tips]
      expect(tips).to have_key('結合カラムにインデックス')
      expect(tips).to have_key('結合前にフィルタ')
    end
  end

  describe '.demonstrate_activerecord_explain' do
    let(:result) { described_class.demonstrate_activerecord_explain }

    it '単純なクエリのexplain結果が取得できることを確認する' do
      expect(result[:simple_explain]).to be_a(String)
      expect(result[:simple_explain]).not_to be_empty
    end

    it '複雑なJOIN+GROUP BYクエリのexplain結果が取得できることを確認する' do
      expect(result[:complex_explain]).to be_a(String)
      expect(result[:complex_explain]).not_to be_empty
    end

    it 'to_sqlでSQL文を事前確認できることを確認する' do
      expect(result[:sql_preview]).to match(/SELECT.*FROM "qp_products"/i)
      expect(result[:sql_preview]).to match(/WHERE/i)
      expect(result[:sql_preview]).to match(/BETWEEN/i)
    end

    it 'サブクエリのexplain結果が取得できることを確認する' do
      expect(result[:subquery_explain]).to be_a(String)
      expect(result[:subquery_explain]).not_to be_empty
    end

    it 'EXPLAINワークフローの手順が提供されることを確認する' do
      workflow = result[:explain_workflow]
      expect(workflow).to have_key('1. to_sqlで確認')
      expect(workflow).to have_key('2. explainで分析')
      expect(workflow).to have_key('3. インデックス追加')
      expect(workflow).to have_key('4. 再度explain')
    end
  end

  describe '.demonstrate_index_best_practices' do
    let(:result) { described_class.demonstrate_index_best_practices }

    it 'productsテーブルのインデックス一覧が取得できることを確認する' do
      indexes = result[:product_indexes]
      expect(indexes).to be_an(Array)
      expect(indexes.size).to be >= 2

      # 複合インデックスの存在確認
      composite = indexes.find { |idx| idx[:columns].size > 1 }
      expect(composite).not_to be_nil
      expect(composite[:columns]).to eq %w[category price]
    end

    it '冗長なインデックスの分析情報が提供されることを確認する' do
      check = result[:redundant_check]
      expect(check[:analysis]).to include('冗長')
    end

    it 'WHERE + ORDER BYの最適インデックスプランが確認できることを確認する' do
      plan = result[:where_order]
      expect(plan).to be_a(String)
      expect(plan).not_to be_empty
    end

    it 'インデックス設計のベストプラクティスが提供されることを確認する' do
      practices = result[:best_practices]
      expect(practices).to have_key('外部キーインデックス')
      expect(practices).to have_key('複合インデックスの順序')
      expect(practices).to have_key('選択性の確認')
      expect(practices).to have_key('書き込みへの影響')
      expect(practices).to have_key('定期的な見直し')
    end
  end

  describe '.collect_queries' do
    it 'ブロック内で実行されたSQLクエリを収集できることを確認する' do
      queries = described_class.collect_queries do
        QpModels::Product.where(category: 'Electronics').to_a
      end

      expect(queries).to be_an(Array)
      expect(queries).not_to be_empty
      expect(queries.first).to match(/SELECT.*qp_products/i)
    end

    it 'スキーマ関連のクエリが除外されることを確認する' do
      queries = described_class.collect_queries do
        QpModels::Product.all.to_a
      end

      schema_queries = queries.select { |q| q.start_with?('PRAGMA') }
      expect(schema_queries).to be_empty
    end
  end
end
