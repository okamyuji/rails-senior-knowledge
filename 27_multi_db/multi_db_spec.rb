# frozen_string_literal: true

require_relative 'multi_db'

RSpec.describe MultiDbSharding do
  describe MultiDbSharding::MultipleConnections do
    describe '.demonstrate_connection_config' do
      let(:result) { described_class.demonstrate_connection_config }

      it 'connects_toの基本構文とロール定義が正しく説明されていることを確認する' do
        expect(result[:basic_syntax]).to include('connects_to')
        expect(result[:roles]).to have_key(:writing)
        expect(result[:roles]).to have_key(:reading)
        expect(result[:roles][:writing]).to include('書き込み')
        expect(result[:roles][:reading]).to include('読み取り')
      end

      it '内部メカニズムの説明にConnectionHandlerとプール情報が含まれることを確認する' do
        mechanism = result[:internal_mechanism]
        expect(mechanism[:connection_handler]).to include('ConnectionHandler')
        expect(mechanism[:pool_per_role]).to include('コネクションプール')
        expect(mechanism[:thread_safe]).to include('スレッドローカル')
      end
    end

    describe '.demonstrate_current_connection_info' do
      let(:result) { described_class.demonstrate_current_connection_info }

      it '現在のデータベース接続情報が正しく取得されることを確認する' do
        expect(result[:adapter]).to eq 'sqlite3'
        expect(result[:pool_size]).to be_a(Integer)
        expect(result[:pool_size]).to be_positive
        expect(result[:current_role]).to eq :writing
        expect(result[:current_shard]).to eq :default
      end
    end
  end

  describe MultiDbSharding::AutomaticRoleSwitching do
    describe '.demonstrate_auto_switching_concept' do
      let(:result) { described_class.demonstrate_auto_switching_concept }

      it '自動ロールスイッチングのルーティングルールが正しく定義されていることを確認する' do
        rules = result[:routing_rules]
        expect(rules).to have_key('GET/HEAD')
        expect(rules).to have_key('POST/PUT/DELETE/PATCH')
        expect(rules['GET/HEAD']).to include('reading')
        expect(rules['POST/PUT/DELETE/PATCH']).to include('writing')
      end

      it 'レプリカ遅延対策のdelayメカニズムが説明されていることを確認する' do
        delay = result[:delay_mechanism]
        expect(delay[:purpose]).to include('レプリケーション遅延')
        expect(delay[:behavior]).to include('プライマリ')
      end
    end

    describe '.demonstrate_connected_to_role' do
      let(:result) { described_class.demonstrate_connected_to_role }

      it 'writingロールでのCRUD操作が正しく動作することを確認する' do
        expect(result[:writing_count]).to be >= 1
        expect(result[:writing_role]).to eq :writing
      end

      it 'preventing_writesの概念が正しく説明されていることを確認する' do
        concept = result[:preventing_writes_concept]
        expect(concept[:reading_role]).to include('ブロック')
        expect(concept[:error_class]).to include('ReadOnlyError')
      end
    end
  end

  describe MultiDbSharding::ConnectedToBlock do
    describe '.demonstrate_basic_connected_to' do
      let(:result) { described_class.demonstrate_basic_connected_to }

      it 'writingロールで記事が読み書きできることを確認する' do
        expect(result[:writing_articles]).to eq %w[記事1 記事2]
        expect(result[:current_role_writing]).to eq :writing
      end

      it 'prevent_writes: trueで書き込みがReadOnlyErrorになることを確認する' do
        expect(result[:prevented_flag]).to be true
        expect(result[:read_during_prevent]).to be_a(Integer)
        expect(result[:readonly_error_class]).to eq 'ActiveRecord::ReadOnlyError'
        expect(result[:prevent_writes_demo]).to include('書き込みブロック')
      end
    end

    describe '.demonstrate_nested_connected_to' do
      let(:result) { described_class.demonstrate_nested_connected_to }

      it 'ネストしたconnected_toがコンテキストを正しく復帰させることを確認する' do
        expect(result[:nesting_supported]).to be true
        transitions = result[:role_transitions]
        expect(transitions).to include(:writing)
        expect(transitions).to include('writing_with_prevent_writes')
        # prevent_writes がネスト内でtrueになっていること
        expect(transitions).to include('preventing: true')
        # ネスト終了後にprevent_writesが解除されていること
        expect(transitions).to include('preventing: false')
      end
    end
  end

  describe MultiDbSharding::HorizontalSharding do
    describe '.demonstrate_sharding_concept' do
      let(:result) { described_class.demonstrate_sharding_concept }

      it '3種類のシャーディング戦略が説明されていることを確認する' do
        strategies = result[:strategies]
        expect(strategies).to have_key(:tenant_based)
        expect(strategies).to have_key(:range_based)
        expect(strategies).to have_key(:hash_based)
        expect(strategies[:tenant_based][:use_case]).to include('SaaS')
      end

      it 'connects_toのシャード設定構文が含まれていることを確認する' do
        expect(result[:connects_to_syntax]).to include('shards:')
        expect(result[:connects_to_syntax]).to include('shard_one')
        expect(result[:selection_syntax]).to include('connected_to')
      end
    end

    describe '.demonstrate_shard_selection_simulation' do
      let(:result) { described_class.demonstrate_shard_selection_simulation }

      it 'テナントからシャードへのマッピングが正しく動作することを確認する' do
        expect(result[:acme_shard]).to eq :shard_one
        expect(result[:globex_shard]).to eq :shard_two
      end

      it '各シャードにテナントデータが正しく配置されていることを確認する' do
        shard_data = result[:shard_data]
        expect(shard_data[:shard_one].first[:tenant]).to eq 'acme_corp'
        expect(shard_data[:shard_two].first[:tenant]).to eq 'globex_inc'
        expect(shard_data[:shard_three].first[:tenant]).to eq 'initech'
      end
    end
  end

  describe MultiDbSharding::ShardSelection do
    describe '.demonstrate_shard_middleware_pattern' do
      let(:result) { described_class.demonstrate_shard_middleware_pattern }

      it 'ShardSelectorミドルウェアの設定が説明されていることを確認する' do
        expect(result[:configuration]).to include('shard_selector')
        expect(result[:configuration]).to include('shard_resolver')
      end

      it 'シャード選択のフローが正しく定義されていることを確認する' do
        flow = result[:flow]
        expect(flow.size).to be >= 4
        expect(flow.first).to include('リクエスト')
        expect(flow.any? { |step| step.include?('shard_resolver') }).to be true
      end
    end

    describe '.demonstrate_dynamic_shard_switching' do
      let(:result) { described_class.demonstrate_dynamic_shard_switching }

      it 'デフォルトシャードとconnected_toによるシャード指定が動作することを確認する' do
        expect(result[:default_shard]).to eq :default
        expect(result[:explicit_shard]).to eq :default
        expect(result[:explicit_role]).to eq :writing
        expect(result[:shard_article_count]).to be >= 1
      end

      it 'クロスシャードクエリのパターンが説明されていることを確認する' do
        pattern = result[:cross_shard_pattern]
        expect(pattern[:description]).to include('集約')
        expect(pattern[:approach]).to be_an(Array)
        expect(pattern[:approach].size).to be >= 2
      end
    end
  end

  describe MultiDbSharding::MigrationPerDatabase do
    describe '.demonstrate_migration_structure' do
      let(:result) { described_class.demonstrate_migration_structure }

      it 'マルチDBマイグレーションコマンドが正しく説明されていることを確認する' do
        commands = result[:commands]
        expect(commands[:all_databases]).to include('db:migrate')
        expect(commands[:specific_db]).to include('primary')
        expect(commands[:rollback]).to include('rollback')
      end

      it 'マイグレーションディレクトリの分離が説明されていることを確認する' do
        dirs = result[:directory_structure]
        expect(dirs).to have_key('db/migrate/')
        expect(dirs.values.any? { |v| v.include?('プライマリ') }).to be true
      end
    end

    describe '.demonstrate_migration_status' do
      let(:result) { described_class.demonstrate_migration_status }

      it '現在のテーブル情報が正しく取得されることを確認する' do
        expect(result[:current_tables]).to include('articles')
        expect(result[:current_tables]).to include('tenants')
      end

      it 'テーブルのカラム情報が取得できることを確認する' do
        articles_columns = result[:table_columns]['articles']
        column_names = articles_columns.map { |c| c[:name] }
        expect(column_names).to include('title', 'body', 'status')
      end
    end
  end

  describe MultiDbSharding::ConnectionHandling do
    describe '.demonstrate_connection_pool_management' do
      let(:result) { described_class.demonstrate_connection_pool_management }

      it 'ConnectionHandlerのプール情報が正しく取得されることを確認する' do
        expect(result[:handler_class]).to include('ConnectionHandler')
        expect(result[:all_connection_pools]).to be >= 1
        expect(result[:pool_details]).to be_an(Array)
        expect(result[:pool_details].first[:adapter]).to eq 'sqlite3'
      end

      it 'プール管理の概念が正しく説明されていることを確認する' do
        concept = result[:management_concept]
        expect(concept[:pool_creation]).to include('独立プール')
        expect(concept[:pool_isolation]).to include('独立')
        expect(concept[:recommendation]).to include('Puma')
      end
    end

    describe '.demonstrate_connection_lifecycle' do
      let(:result) { described_class.demonstrate_connection_lifecycle }

      it '接続のライフサイクルが正しく説明されていることを確認する' do
        lifecycle = result[:lifecycle]
        expect(lifecycle).to be_an(Array)
        expect(lifecycle.size).to be >= 5
        expect(lifecycle.any? { |step| step.include?('チェックアウト') }).to be true
        expect(lifecycle.any? { |step| step.include?('チェックイン') }).to be true
      end

      it 'マルチDB固有の注意点が説明されていることを確認する' do
        considerations = result[:multi_db_considerations]
        expect(considerations).to be_an(Array)
        expect(considerations.any? { |c| c.include?('トランザクション') }).to be true
        expect(considerations.any? { |c| c.include?('スレッドローカル') }).to be true
      end
    end
  end

  describe MultiDbSharding::PracticalPatterns do
    describe '.demonstrate_replica_for_reports' do
      let(:result) { described_class.demonstrate_replica_for_reports }

      it 'レポートデータが正しく集計されることを確認する' do
        report = result[:report_data]
        expect(report[:total_articles]).to eq 10
        expect(report[:published_count]).to eq 7
        expect(report[:draft_count]).to eq 3
        expect(report[:recent_articles].size).to eq 3
      end

      it 'レプリカ利用パターンの説明と注意点が含まれていることを確認する' do
        pattern = result[:pattern_description]
        expect(pattern[:purpose]).to include('レプリカ')
        expect(pattern[:caveats]).to be_an(Array)
        expect(pattern[:caveats].any? { |c| c.include?('遅延') }).to be true
      end
    end

    describe '.demonstrate_tenant_sharding_pattern' do
      let(:result) { described_class.demonstrate_tenant_sharding_pattern }

      it 'テナント情報が正しく作成されていることを確認する' do
        tenants = result[:tenants]
        expect(tenants.size).to eq 3
        expect(tenants.map { |t| t[:subdomain] }).to contain_exactly('acme', 'globex', 'initech')
      end

      it 'シャード解決ロジックとベストプラクティスが説明されていることを確認する' do
        resolver = result[:shard_resolver]
        expect(resolver[:description]).to include('テナント')
        expect(resolver[:code]).to include('SHARD_MAP')

        practices = result[:best_practices]
        expect(practices).to be_an(Array)
        expect(practices.size).to be >= 3
        expect(practices.any? { |p| p.include?('グローバルDB') }).to be true
      end
    end

    describe '.demonstrate_production_checklist' do
      let(:result) { described_class.demonstrate_production_checklist }

      it '読み書き分離とシャーディングのチェックリストが含まれていることを確認する' do
        expect(result).to have_key(:read_write_splitting)
        expect(result).to have_key(:sharding)
        expect(result).to have_key(:connection_pool)

        rw = result[:read_write_splitting]
        expect(rw[:setup]).to be_an(Array)
        expect(rw[:testing]).to be_an(Array)

        sharding = result[:sharding]
        expect(sharding[:setup]).to be_an(Array)
        expect(sharding[:operations]).to be_an(Array)
      end

      it 'コネクションプールのサイジング指針が含まれていることを確認する' do
        pool = result[:connection_pool]
        expect(pool[:sizing]).to include('Puma')
        expect(pool[:monitoring]).to include('監視')
      end
    end
  end
end
