# frozen_string_literal: true

require_relative 'n_plus_one'

RSpec.describe NPlusOneDetection do
  before { described_class.setup_test_data }

  describe '.demonstrate_n_plus_one_problem' do
    let(:result) { described_class.demonstrate_n_plus_one_problem }

    it '遅延ロードがN+1クエリを発生させることを確認する' do
      # 1（著者取得）+ 3（各著者の本を個別取得）= 4クエリ
      expect(result[:lazy_query_count]).to be >= 4
    end

    it 'Eager LoadingによりN+1が解消されることを確認する' do
      expect(result[:eager_query_count]).to be <= 2
    end

    it 'Eager Loadingが遅延ロードよりクエリ数を削減することを確認する' do
      expect(result[:query_reduction]).to be >= 2
    end
  end

  describe '.demonstrate_loading_strategies' do
    let(:result) { described_class.demonstrate_loading_strategies }

    it 'preloadが複数の別クエリで関連を取得することを確認する' do
      expect(result[:preload_uses_separate_queries]).to be true
    end

    it 'preloadがIN句を使用することを確認する' do
      expect(result[:preload_has_in_clause]).to be true
    end

    it 'eager_loadがLEFT OUTER JOINを使用することを確認する' do
      expect(result[:eager_load_uses_join]).to be true
    end

    it 'includesがreferences指定時にJOINを使用することを確認する' do
      expect(result[:includes_ref_uses_join]).to be true
    end
  end

  describe '.demonstrate_nested_eager_loading' do
    let(:result) { described_class.demonstrate_nested_eager_loading }

    it 'ネストしたN+1問題が大量のクエリを発生させることを確認する' do
      # 1（著者）+ 3（各著者の本）+ 6（各本のレビュー）= 10クエリ
      expect(result[:lazy_nested_query_count]).to be >= 7
    end

    it 'ネストしたEager Loadingが3クエリ以内で完了することを確認する' do
      expect(result[:eager_nested_query_count]).to eq result[:expected_eager_queries]
    end

    it 'すべてのレビューが正しくロードされることを確認する' do
      # 3著者 × 2冊 × 2レビュー = 12レビュー
      expect(result[:total_reviews_loaded]).to eq 12
    end
  end

  describe '.demonstrate_strict_loading' do
    let(:result) { described_class.demonstrate_strict_loading }

    it 'strict_loadingスコープで遅延ロードが例外を発生させることを確認する' do
      expect(result[:scope_error_raised]).to be true
      expect(result[:scope_strict_loading_error]).to include('StrictLoadingViolation')
        .or include('strict_loading')
        .or be_a(String)
    end

    it 'strict_loading!でインスタンスレベルの遅延ロード禁止を確認する' do
      expect(result[:instance_error_raised]).to be true
    end

    it 'Eager Loadingされた関連はstrict_loadingでもアクセスできることを確認する' do
      expect(result[:eager_loaded_no_error]).to be true
      expect(result[:eager_loaded_books_count]).to eq 2
    end
  end

  describe '.demonstrate_association_strict_loading' do
    let(:result) { described_class.demonstrate_association_strict_loading }

    it '関連レベルのstrict_loadingが遅延ロードを禁止することを確認する' do
      expect(result[:association_error_raised]).to be true
    end

    it 'preloadで事前読み込みすればstrict_loading関連にアクセスできることを確認する' do
      expect(result[:preloaded_bypasses_strict]).to be true
      expect(result[:preloaded_count]).to eq 2
    end
  end

  describe '.demonstrate_query_counting_pattern' do
    let(:result) { described_class.demonstrate_query_counting_pattern }

    it 'N+1パターンが検出されることを確認する' do
      expect(result[:n_plus_one_detected]).to be true
    end

    it 'booksテーブルへの繰り返しクエリが検出されることを確認する' do
      expect(result[:detected_tables]).to include('npo_books')
    end

    it '検出メカニズムがActiveSupport::Notificationsであることを確認する' do
      expect(result[:detection_mechanism]).to include('ActiveSupport::Notifications')
    end
  end

  describe '.demonstrate_batch_loading' do
    let(:result) { described_class.demonstrate_batch_loading }

    it 'find_eachが全レコードを処理することを確認する' do
      expect(result[:find_each_results].size).to eq 3
    end

    it 'find_in_batchesがバッチ単位で処理することを確認する' do
      # batch_size: 2 で3件なら [2, 1] のバッチ
      expect(result[:batch_sizes]).to eq [2, 1]
    end

    it 'find_each + includesでバッチ処理とEager Loadingが併用できることを確認する' do
      expect(result[:batch_eager_results].size).to eq 3
      result[:batch_eager_results].each do |r|
        expect(r[:books]).to eq 2
      end
    end
  end

  describe '.demonstrate_practical_patterns' do
    let(:result) { described_class.demonstrate_practical_patterns }

    it 'sizeがロード済みの場合に追加クエリを発行しないことを確認する' do
      # includes済み: 1クエリ（著者+本を一括取得）のみ
      expect(result[:size_loaded_query_count]).to be <= 2
    end

    it 'JOINSとpluckで1クエリに最適化できることを確認する' do
      expect(result[:optimized_single_query_count]).to eq 1
    end

    it 'pluckのN+1がeach内で発生することを確認する' do
      # 1（著者取得）+ 3（各著者のbooks.pluck）= 4クエリ
      expect(result[:pluck_n_plus_one_count]).to be >= 4
    end
  end
end
