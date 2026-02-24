# frozen_string_literal: true

require_relative 'routing_internals'

RSpec.describe RoutingInternals do
  describe '.demonstrate_route_definition_dsl' do
    let(:result) { described_class.demonstrate_route_definition_dsl }

    it 'ルート定義 DSL が正しくルートオブジェクトを生成することを確認する' do
      expect(result[:route_count]).to be >= 3
      expect(result[:route_class]).to include('Route')
    end

    it '各ルートが正しいパス・コントローラー・アクション情報を持つことを確認する' do
      hello_route = result[:route_entries].find { |r| r[:name] == 'hello' }
      expect(hello_route).not_to be_nil
      expect(hello_route[:path]).to include('/hello')
      expect(hello_route[:controller]).to eq 'users'
      expect(hello_route[:action]).to eq 'index'
    end

    it '名前空間付きルートが正しく定義されることを確認する' do
      admin_route = result[:route_entries].find { |r| r[:controller] == 'admin/dashboard' }
      expect(admin_route).not_to be_nil
      expect(admin_route[:path]).to include('/admin/dashboard')
    end
  end

  describe '.demonstrate_journey_nfa_concepts' do
    let(:result) { described_class.demonstrate_journey_nfa_concepts }

    it 'Journey エンジンの内部構造が存在することを確認する' do
      expect(result[:router_class]).to include('Router')
      expect(result[:journey_routes_count]).to eq 3
      expect(result[:router_has_routes]).to be true
    end

    it '各ルートが AST 情報を持つことを確認する' do
      expect(result[:ast_info]).to be_an(Array)
      result[:ast_info].each do |info|
        expect(info[:path]).to be_a(String)
        expect(info[:ast_class]).to be_a(String)
      end
    end
  end

  describe '.demonstrate_route_recognition' do
    let(:result) { described_class.demonstrate_route_recognition }

    it '基本的なパスが正しくルートとして認識されることを確認する' do
      expect(result[:index_params][:controller]).to eq 'users'
      expect(result[:index_params][:action]).to eq 'index'
    end

    it '動的セグメントからパラメータが正しく抽出されることを確認する' do
      expect(result[:show_id]).to eq '42'
      expect(result[:show_params][:controller]).to eq 'users'
      expect(result[:show_params][:action]).to eq 'show'
    end

    it 'HTTP メソッドによって異なるルートにマッチすることを確認する' do
      expect(result[:create_params][:action]).to eq 'create'
      expect(result[:index_params][:action]).to eq 'index'
    end

    it '複数の動的セグメントが正しく抽出されることを確認する' do
      expect(result[:archive_year]).to eq '2024'
      expect(result[:archive_month]).to eq '12'
    end

    it 'グロブルートがスラッシュを含むパスにマッチすることを確認する' do
      expect(result[:glob_path]).to eq 'tech/ruby/rails'
    end

    it '存在しないパスで RoutingError が発生することを確認する' do
      expect(result[:unrecognized_error]).to be_a(String)
      expect(result[:unrecognized_error]).not_to be_empty
    end
  end

  describe '.demonstrate_route_generation' do
    let(:result) { described_class.demonstrate_route_generation }

    it '名前付きルートヘルパーが正しいパスを生成することを確認する' do
      expect(result[:users_path]).to eq '/users'
      expect(result[:user_path]).to eq '/users/42'
      expect(result[:edit_user_path]).to eq '/users/42/edit'
    end

    it '複数パラメータのパスが正しく生成されることを確認する' do
      expect(result[:archive_path]).to eq '/posts/2024/12'
    end

    it '余剰パラメータがクエリ文字列として付加されることを確認する' do
      expect(result[:user_path_with_query]).to include('/users/42')
      expect(result[:user_path_with_query]).to include('extra=value')
    end
  end

  describe '.demonstrate_route_constraints' do
    let(:result) { described_class.demonstrate_route_constraints }

    it '数字制約を満たす ID が正しくマッチすることを確認する' do
      expect(result[:numeric_id_matched]).to be true
      expect(result[:numeric_id_result][:controller]).to eq 'users'
    end

    it '数字制約を満たさない ID がルーティングエラーになることを確認する' do
      expect(result[:non_numeric_error]).to be_a(String)
    end

    it '年月制約のバリデーションが機能することを確認する' do
      expect(result[:valid_archive][:year]).to eq '2024'
      expect(result[:valid_archive][:month]).to eq '12'
    end
  end

  describe '.demonstrate_route_globbing' do
    let(:result) { described_class.demonstrate_route_globbing }

    it 'グロブルートが単一セグメントにマッチすることを確認する' do
      expect(result[:page_path]).to eq 'about'
    end

    it 'グロブルートが複数セグメント（スラッシュ含む）にマッチすることを確認する' do
      expect(result[:deep_page_path]).to eq 'tech/ruby/rails'
    end

    it 'グロブルート + サフィックスの組み合わせが正しくマッチすることを確認する' do
      expect(result[:file_path]).to eq 'documents/report.pdf'
    end

    it 'フォーマット付きルートが .json 拡張子を認識することを確認する' do
      expect(result[:doc_params][:id]).to eq '42'
      expect(result[:doc_json_params][:id]).to eq '42'
      expect(result[:doc_json_params][:format]).to eq 'json'
    end

    it 'パスヘルパーがグロブルートのパスを正しく生成することを確認する' do
      expect(result[:generated_page_path]).to include('tech/ruby/rails')
      expect(result[:generated_file_path]).to include('docs/report.pdf')
    end
  end

  describe '.demonstrate_mounted_engines' do
    let(:result) { described_class.demonstrate_mounted_engines }

    it 'エンジンが独立したルートテーブルを持つことを確認する' do
      expect(result[:engine_route_count]).to eq 3
      expect(result[:separate_route_sets]).to be true
    end

    it 'エンジン内のルートが正しく認識されることを確認する' do
      expect(result[:engine_post_params][:controller]).to eq 'blog/posts'
      expect(result[:engine_post_params][:id]).to eq '5'
      expect(result[:engine_comments_params][:controller]).to eq 'blog/comments'
      expect(result[:engine_comments_params][:post_id]).to eq '5'
    end

    it 'ホストアプリがエンジンのマウントポイントを含むことを確認する' do
      expect(result[:host_route_count]).to be >= 2
    end
  end

  describe '.demonstrate_route_inspection' do
    let(:result) { described_class.demonstrate_route_inspection }

    it 'ルートテーブルの詳細情報が正しく取得できることを確認する' do
      expect(result[:total_routes]).to be >= 7
      expect(result[:route_details]).to be_an(Array)

      user_show = result[:route_details].find { |r| r[:action] == 'show' && r[:controller] == 'users' }
      expect(user_show).not_to be_nil
      expect(user_show[:path]).to include(':id')
      expect(user_show[:required_parts]).to include(:id)
    end

    it '名前付きルートの一覧が取得できることを確認する' do
      expect(result[:named_routes]).to be_a(Hash)
      expect(result[:named_routes]).to have_key(:users)
      expect(result[:named_routes]).to have_key(:user)
    end

    it 'rails routes 相当のフォーマット済み出力が取得できることを確認する' do
      expect(result[:formatted_output]).to be_a(String)
      expect(result[:formatted_output]).to include('users')
    end

    it 'ルート検査用のメソッドが利用可能であることを確認する' do
      expect(result[:inspection_methods][:routes_method]).to be true
      expect(result[:inspection_methods][:named_routes_method]).to be true
      expect(result[:inspection_methods][:recognize_path_method]).to be true
    end
  end
end
