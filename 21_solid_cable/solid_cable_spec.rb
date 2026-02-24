# frozen_string_literal: true

require_relative 'solid_cable'

RSpec.describe SolidCableInternals do
  # 各テストの前にメッセージテーブルをクリーンアップ
  before { CableMessage.delete_all }

  describe '.demonstrate_architecture' do
    let(:result) { described_class.demonstrate_architecture }

    it 'メッセージがデータベースに永続化されることを確認する' do
      expect(result[:message_persisted]).to be true
      expect(result[:message_channel]).to eq 'chat_room_1'
      expect(result[:message_payload]).to include('こんにちは')
    end

    it '複数チャンネルへのメッセージ発行を確認する' do
      expect(result[:total_messages]).to eq 2
      expect(result[:channels]).to include('chat_room_1' => 1, 'notifications' => 1)
    end
  end

  describe '.demonstrate_message_lifecycle' do
    let(:result) { described_class.demonstrate_message_lifecycle }

    it 'メッセージライフサイクルの各段階を確認する' do
      expect(result[:lifecycle_events]).to include(
        a_string_matching(/published/),
        a_string_matching(/stored/),
        a_string_matching(/delivered/)
      )
    end

    it 'IDベースの差分取得が正しく機能することを確認する' do
      expect(result[:incremental_delivery_works]).to be true
      expect(result[:last_message_payload]).to eq '{"step":2}'
    end
  end

  describe '.demonstrate_polling_mechanism' do
    let(:result) { described_class.demonstrate_polling_mechanism }

    it 'ポーリングサイクルごとにメッセージが正しく取得されることを確認する' do
      # 最初のポーリングではメッセージがない
      expect(result[:poll_cycle_1][:new_messages]).to eq 0
      # 2回目のポーリングで2件取得
      expect(result[:poll_cycle_2][:new_messages]).to eq 2
      # 3回目のポーリングで差分の1件だけ取得
      expect(result[:poll_cycle_3][:new_messages]).to eq 1
    end

    it 'メッセージの重複がないことを確認する' do
      expect(result[:no_duplicates]).to be true
      expect(result[:total_received]).to eq 3
    end
  end

  describe '.demonstrate_message_trimming' do
    let(:result) { described_class.demonstrate_message_trimming }

    it '古いメッセージがトリミングされることを確認する' do
      expect(result[:before_trim_count]).to eq 5
      # 2日前のメッセージ3件が削除される
      expect(result[:trimmed_count]).to eq 3
      expect(result[:after_trim_count]).to eq 2
    end

    it '保持期間内のメッセージが残ることを確認する' do
      retained = result[:retained_messages]
      expect(retained).to include('{"recent":true}')
      expect(retained).to include('{"current":true}')
      expect(retained).not_to include('{"old":true}')
    end
  end

  describe '.demonstrate_channel_subscription' do
    let(:result) { described_class.demonstrate_channel_subscription }

    it 'チャンネルごとにメッセージが分離されることを確認する' do
      expect(result[:channel_isolation]).to be true
      expect(result[:subscriber_a_count]).to eq 2
      expect(result[:subscriber_b_count]).to eq 1
      expect(result[:subscriber_c_count]).to eq 1
    end

    it '複数サブスクライバーが独立してメッセージを追跡できることを確認する' do
      # サブスクライバー2は遅れてポーリングしたので全3件を取得
      expect(result[:sub2_sees_all]).to be true
      # サブスクライバー1は差分の1件だけ取得
      expect(result[:sub1_sees_incremental]).to be true
    end

    it '正しい数のチャンネルが存在することを確認する' do
      expect(result[:total_channels]).to eq 4
    end
  end

  describe '.demonstrate_comparison_with_redis' do
    let(:result) { described_class.demonstrate_comparison_with_redis }

    it '全メッセージが正しく発行・取得されることを確認する' do
      expect(result[:messages_published]).to eq 50
      expect(result[:all_fetched]).to be true
    end

    it 'Solid CableとRedisの比較情報が含まれることを確認する' do
      comparison = result[:comparison]
      expect(comparison[:solid_cable][:delivery_model]).to include('ポーリング')
      expect(comparison[:redis_adapter][:delivery_model]).to include('プッシュ')
      expect(comparison[:solid_cable][:infrastructure]).to include('不要')
      expect(comparison[:redis_adapter][:infrastructure]).to include('Redis')
    end
  end

  describe '.demonstrate_configuration' do
    let(:result) { described_class.demonstrate_configuration }

    it '設定キーが網羅されていることを確認する' do
      expect(result[:configuration_keys]).to include(
        'polling_interval',
        'message_retention',
        'connects_to',
        'silence_polling',
        'autotrim'
      )
    end

    it 'ポーリング間隔の設定パターンが含まれることを確認する' do
      intervals = result[:polling_intervals]
      expect(intervals[:default][:interval]).to eq 0.1
      expect(intervals[:aggressive][:db_queries_per_second]).to be > intervals[:default][:db_queries_per_second]
    end
  end

  describe '.demonstrate_integrated_pubsub' do
    let(:result) { described_class.demonstrate_integrated_pubsub }

    it 'チャットチャンネルのメッセージが正しく配信されることを確認する' do
      expect(result[:chat_first_poll]).to eq 3
      expect(result[:chat_incremental]).to eq 1
      expect(result[:chat_inbox_size]).to eq 4
    end

    it 'アラートチャンネルのメッセージが正しく配信されることを確認する' do
      expect(result[:alerts_first_poll]).to eq 1
      expect(result[:alerts_incremental]).to eq 1
      expect(result[:alerts_inbox_size]).to eq 2
    end

    it '全メッセージがデータベースに保存されていることを確認する' do
      expect(result[:total_messages_in_db]).to eq 6
    end

    it 'チャンネル間でメッセージが混在しないことを確認する' do
      chat_users = result[:chat_inbox].map { |m| m['user'] }.compact
      alert_levels = result[:alerts_inbox].map { |m| m['level'] }.compact

      expect(chat_users).to include('Alice', 'Bob', 'Charlie')
      expect(alert_levels).to include('info', 'warning')
      # チャットにアラートが混入していない
      expect(result[:chat_inbox].none? { |m| m.key?('level') }).to be true
    end
  end
end
