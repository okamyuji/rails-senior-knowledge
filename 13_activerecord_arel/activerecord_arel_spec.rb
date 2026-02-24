# frozen_string_literal: true

require_relative 'activerecord_arel'

RSpec.describe ActiveRecordArel do
  describe '.demonstrate_arel_table_and_nodes' do
    let(:result) { described_class.demonstrate_arel_table_and_nodes }

    it 'Arel::Tableがテーブル名とカラム属性を正しく返すことを確認する' do
      expect(result[:table_name]).to eq 'arel_users'
      expect(result[:same_table]).to be true
      expect(result[:name_attr_name]).to eq 'name'
    end

    it 'SELECTクエリのSQLが正しく生成されることを確認する' do
      expect(result[:select_sql]).to match(/SELECT.*"arel_users"\."name".*"arel_users"\."age".*FROM "arel_users"/i)
    end
  end

  describe '.demonstrate_arel_predicates' do
    let(:result) { described_class.demonstrate_arel_predicates }

    it 'eq/not_eqの述語が正しいSQLを生成することを確認する' do
      expect(result[:eq_sql]).to match(/"arel_users"\."name" = 'Alice'/i)
      expect(result[:not_eq_sql]).to match(/"arel_users"\."name" != 'Bob'/i)
    end

    it 'gt/lt比較述語が正しいSQLを生成することを確認する' do
      expect(result[:gt_sql]).to match(/"arel_users"\."age" > 25/i)
      expect(result[:lt_sql]).to match(/"arel_users"\."age" < 60/i)
    end

    it 'matches/in/between/NULLの述語が正しいSQLを生成することを確認する' do
      expect(result[:matches_sql]).to match(/LIKE '%@example.com'/i)
      expect(result[:in_sql]).to match(/IN \(25, 30, 35\)/i)
      expect(result[:between_sql]).to match(/BETWEEN 20 AND 40/i)
      expect(result[:null_sql]).to match(/IS NULL/i)
      expect(result[:not_null_sql]).to match(/IS NOT NULL/i)
    end
  end

  describe '.demonstrate_arel_composability' do
    let(:result) { described_class.demonstrate_arel_composability }

    it 'AND条件が正しいSQLを生成することを確認する' do
      expect(result[:and_sql]).to match(/"arel_users"\."age" >= 20 AND "arel_users"\."age" <= 40/i)
    end

    it 'OR条件が正しいSQLを生成することを確認する' do
      expect(result[:or_sql]).to match(/"arel_users"\."name" = 'Alice' OR "arel_users"\."name" = 'Bob'/i)
    end

    it '複合条件（AND + OR）が正しくネストされたSQLを生成することを確認する' do
      sql = result[:complex_sql]
      # ANDとORが両方含まれている
      expect(sql).to include('AND')
      expect(sql).to include('OR')
      # OR条件がグループ化されていることを確認
      expect(sql).to match(/Alice.*OR.*Bob/i)
    end

    it 'NOT条件が正しいSQLを生成することを確認する' do
      expect(result[:not_sql]).to match(/NOT.*"arel_users"\."name" = 'Charlie'/i)
    end
  end

  describe '.demonstrate_activerecord_to_arel' do
    let(:result) { described_class.demonstrate_activerecord_to_arel }

    it 'ActiveRecordのwhereチェーンがSQLに変換されることを確認する' do
      expect(result[:where_sql]).to match(/WHERE.*"arel_users"\."name" = 'Alice'/i)
      expect(result[:where_sql]).to match(/age > 25/i)
    end

    it 'HashのwhereがAND条件のSQLに変換されることを確認する' do
      expect(result[:hash_where_sql]).to match(/"arel_users"\."name" = 'Alice'/i)
      expect(result[:hash_where_sql]).to match(/"arel_users"\."age" = 30/i)
    end

    it 'orderが正しいORDER BY句を生成することを確認する' do
      expect(result[:order_sql]).to match(/ORDER BY.*"arel_users"\."age" DESC.*"arel_users"\."name" ASC/i)
    end

    it 'joinsがINNER JOIN句を生成することを確認する' do
      expect(result[:join_sql]).to match(/INNER JOIN "arel_posts"/i)
    end
  end

  describe '.demonstrate_arel_sql_generation' do
    let(:result) { described_class.demonstrate_arel_sql_generation }

    it 'Visitorパターンによる正しいSQL生成を確認する' do
      expect(result[:generated_sql]).to match(/"arel_users"\."name" = 'Alice'/i)
      expect(result[:visitor_class]).to include('Visitor')
    end

    it 'SelectManagerが完全なSELECTクエリを生成することを確認する' do
      sql = result[:manager_sql]
      expect(sql).to match(/SELECT.*"arel_users"\."name".*FROM "arel_users"/i)
      expect(sql).to match(/WHERE.*"arel_users"\."age" > 20/i)
      expect(sql).to match(/ORDER BY.*"arel_users"\."name" ASC/i)
    end

    it 'Arel.sqlでリテラルSQLが挿入されることを確認する' do
      expect(result[:count_sql]).to match(/SELECT COUNT\(\*\) FROM "arel_users"/i)
    end
  end

  describe '.demonstrate_subqueries' do
    let(:result) { described_class.demonstrate_subqueries }

    it 'EXISTS句のサブクエリが正しいSQLを生成することを確認する' do
      expect(result[:exists_sql]).to match(/WHERE EXISTS.*SELECT 1 FROM "arel_posts"/i)
      expect(result[:exists_sql]).to match(/"arel_posts"\."arel_user_id" = "arel_users"\."id"/i)
    end

    it 'NOT EXISTS句のサブクエリが正しいSQLを生成することを確認する' do
      expect(result[:not_exists_sql]).to match(/NOT.*EXISTS/i)
    end

    it 'INサブクエリが正しいSQLを生成することを確認する' do
      expect(result[:in_subquery_sql]).to match(/WHERE.*"arel_users"\."id" IN.*SELECT.*"arel_posts"\."arel_user_id"/i)
    end

    it 'ActiveRecordのサブクエリとArelのサブクエリが同等であることを確認する' do
      # 両方ともINサブクエリを生成する
      expect(result[:ar_subquery_sql]).to match(/IN.*SELECT/i)
      expect(result[:in_subquery_sql]).to match(/IN.*SELECT/i)
    end
  end

  describe '.demonstrate_injection_prevention' do
    let(:result) { described_class.demonstrate_injection_prevention }

    it 'Arel述語が悪意のある入力を安全にエスケープすることを確認する' do
      # シングルクォートがエスケープされている（''にエスケープ）
      expect(result[:injection_prevented]).to be true
      # SQLは値全体がクォートされた文字列として扱われている
      # 攻撃文字列がSQL構文として解釈されないことを確認
      # （値は '...''...' のように1つの文字列リテラル内に収まる）
      expect(result[:safe_sql]).to match(/= '.*''.*DROP TABLE/)
    end

    it 'ActiveRecordのプレースホルダ方式も安全であることを確認する' do
      expect(result[:ar_safe_sql]).to include("''")
      expect(result[:ar_hash_sql]).to include("''")
    end

    it '危険なパターンが文字列として説明されていることを確認する' do
      expect(result[:dangerous_example]).to include('DROP TABLE')
      expect(result[:dangerous_arel_sql_usage]).to include('絶対にやってはいけない')
    end
  end

  describe '.demonstrate_custom_arel_nodes' do
    let(:result) { described_class.demonstrate_custom_arel_nodes }

    it 'ウィンドウ関数のSQLが正しく生成されることを確認する' do
      expect(result[:window_sql]).to match(/ROW_NUMBER\(\) OVER.*ORDER BY.*"arel_users"\."age" DESC/i)
    end

    it 'COALESCE関数のSQLが正しく生成されることを確認する' do
      expect(result[:coalesce_sql]).to match(/COALESCE\("arel_users"\."email", 'unknown'\)/i)
    end

    it 'CASE WHEN文のSQLが正しく生成されることを確認する' do
      expect(result[:case_sql]).to match(/CASE WHEN.*"arel_users"\."age" >= 30 THEN 'senior' ELSE 'junior' END/i)
    end

    it 'UNION操作が正しいノードを生成することを確認する' do
      expect(result[:union_node_class]).to eq 'Arel::Nodes::Union'
    end
  end

  describe '.demonstrate_query_execution' do
    let(:result) { described_class.demonstrate_query_execution }

    it '年齢フィルタが正しく動作することを確認する' do
      # age >= 25 のユーザー: Alice(28), Bob(35)
      expect(result[:age_filtered]).to eq %w[Alice Bob]
    end

    it 'LIKEパターンマッチが正しく動作することを確認する' do
      # @example.com のメール: Alice, Bob
      expect(result[:email_filtered]).to contain_exactly('Alice', 'Bob')
    end

    it 'EXISTS句で公開済み投稿を持つユーザーが正しく取得されることを確認する' do
      # published: true の投稿を持つのは Alice のみ
      expect(result[:users_with_published]).to eq ['Alice']
    end

    it 'OR条件の実行結果が正しいことを確認する' do
      # name = 'Alice' OR age < 25: Alice(28), Charlie(22)
      expect(result[:or_result]).to eq %w[Alice Charlie]
    end

    it 'テストデータが正しく投入されたことを確認する' do
      expect(result[:total_users]).to eq 3
      expect(result[:total_posts]).to eq 3
    end
  end
end
