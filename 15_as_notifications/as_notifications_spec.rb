# frozen_string_literal: true

require_relative 'as_notifications'

RSpec.describe AsNotifications do
  # 各テスト後にサブスクライバーが残らないよう念のため確認
  # （各メソッド内で unsubscribe 済みだが安全策として）

  describe AsNotifications::SubscribeInstrument do
    describe '.demonstrate_basic_subscribe_instrument' do
      it 'subscribe/instrument の基本的な Pub/Sub パターンが動作する' do
        events = described_class.demonstrate_basic_subscribe_instrument

        expect(events.size).to eq(1)
        event = events.first
        expect(event[:name]).to eq('custom.event')
        expect(event[:has_start]).to be true
        expect(event[:has_finish]).to be true
        expect(event[:has_id]).to be true
        expect(event[:payload_data]).to eq('テストデータ')
      end
    end

    describe '.demonstrate_instrument_without_block' do
      it 'ブロックなしの instrument でも通知が配信される' do
        received = described_class.demonstrate_instrument_without_block

        expect(received.size).to eq(1)
        expect(received.first[:name]).to eq('simple.notification')
        expect(received.first[:message]).to eq('ブロックなし通知')
      end
    end

    describe '.demonstrate_unsubscribe' do
      it 'unsubscribe 後はイベントが届かないことを確認する' do
        result = described_class.demonstrate_unsubscribe

        expect(result[:before_unsubscribe]).to eq(1)
        expect(result[:after_unsubscribe]).to eq(1)
      end
    end
  end

  describe AsNotifications::EventObject do
    describe '.demonstrate_event_attributes' do
      it 'Event オブジェクトの各属性に正しい値が設定される' do
        data = described_class.demonstrate_event_attributes

        expect(data[:name]).to eq('event.demo')
        expect(data[:duration_is_numeric]).to be true
        expect(data[:duration_positive]).to be true
        expect(data[:has_transaction_id]).to be true
        expect(data[:payload_keys]).to eq(%i[action user_id])
        expect(data[:time_is_numeric]).to be true
        expect(data[:end_is_numeric]).to be true
        expect(data[:end_after_start]).to be true
      end
    end

    describe '.demonstrate_payload_mutation' do
      it 'instrument ブロック内でペイロードを動的に変更できる' do
        payload = described_class.demonstrate_payload_mutation

        expect(payload[:status]).to eq(:completed)
        expect(payload[:result_count]).to eq(42)
      end
    end
  end

  describe AsNotifications::MonotonicTime do
    describe '.demonstrate_monotonic_clock' do
      it 'モノトニック時計で正の経過時間を計測できる' do
        result = described_class.demonstrate_monotonic_clock

        expect(result[:monotonic_elapsed_positive]).to be true
        expect(result[:wall_elapsed_positive]).to be true
        expect(result[:monotonic_never_negative]).to be true
        expect(result[:both_measure_duration]).to be true
      end
    end

    describe '.demonstrate_event_uses_monotonic' do
      it 'Event#duration がすべて非負の数値であることを確認する' do
        result = described_class.demonstrate_event_uses_monotonic

        expect(result[:all_non_negative]).to be true
        expect(result[:count]).to eq(3)
        expect(result[:all_numeric]).to be true
      end
    end
  end

  describe AsNotifications::PatternMatching do
    describe '.demonstrate_regex_subscription' do
      it '正規表現でパターンに一致するイベントのみ購読できる' do
        result = described_class.demonstrate_regex_subscription

        expect(result[:matched_count]).to eq(3)
        expect(result[:matched_names]).to eq(
          ['app.order.create', 'app.payment.process', 'app.user.login']
        )
        expect(result[:includes_system]).to be false
      end
    end

    describe '.demonstrate_multiple_subscribers' do
      it '複数のサブスクライバーが同一イベントを受信できる' do
        result = described_class.demonstrate_multiple_subscribers

        expect(result[:subscriber_a_received]).to eq(['A: テスト'])
        expect(result[:subscriber_b_received]).to eq(['B: テスト'])
        expect(result[:both_received]).to be true
      end
    end

    describe '.demonstrate_unsubscribe_by_name' do
      it '文字列指定で同名の全サブスクライバーを一括解除できる' do
        result = described_class.demonstrate_unsubscribe_by_name

        expect(result[:before]).to eq({ a: 1, b: 1 })
        expect(result[:after]).to eq({ a: 1, b: 1 })
      end
    end
  end

  describe AsNotifications::BuiltInEvents do
    describe '.list_builtin_events' do
      it 'Rails の主要な組み込みイベントカテゴリを網羅する' do
        events = described_class.list_builtin_events

        expect(events).to have_key(:action_controller)
        expect(events).to have_key(:active_record)
        expect(events).to have_key(:action_view)
        expect(events).to have_key(:active_support)
        expect(events).to have_key(:action_mailer)
        expect(events).to have_key(:active_job)

        # 各カテゴリに少なくとも1つのイベントが含まれる
        events.each_value do |event_list|
          expect(event_list).not_to be_empty
        end
      end
    end

    describe '.demonstrate_event_naming_convention' do
      it '全イベント名がドット区切りの命名規則に従う' do
        result = described_class.demonstrate_event_naming_convention

        expect(result[:all_have_dot]).to be true
        expect(result[:total_count]).to be > 10

        result[:sample_parts].each do |parts|
          expect(parts).to have_key(:action)
          expect(parts).to have_key(:namespace)
        end
      end
    end
  end

  describe AsNotifications::CustomInstrumentation do
    describe '.demonstrate_custom_events' do
      it 'カスタムイベントを計装してメトリクスを収集できる' do
        result = described_class.demonstrate_custom_events

        expect(result[:metrics_count]).to eq(2)
        expect(result[:event_names]).to contain_exactly('app.user_search', 'app.order_process')
        expect(result[:search_result_count]).to eq(3)
        expect(result[:order_status]).to eq(:completed)
      end
    end

    describe '.demonstrate_nested_instrumentation' do
      it 'ネストした計装で外側の duration が内側を含む' do
        result = described_class.demonstrate_nested_instrumentation

        expect(result[:event_count]).to eq(2)
        expect(result[:inner_name]).to eq('nested.inner')
        expect(result[:outer_name]).to eq('nested.outer')
        expect(result[:outer_includes_inner]).to be true
      end
    end
  end

  describe AsNotifications::FanoutMechanism do
    describe '.demonstrate_fanout_dispatch_order' do
      it '全サブスクライバーが登録順に呼び出される' do
        result = described_class.demonstrate_fanout_dispatch_order

        expect(result[:all_called]).to be true
        expect(result[:order]).to eq(%i[subscriber_1 subscriber_2 subscriber_3])
      end
    end

    describe '.demonstrate_notifier_structure' do
      it 'Notifier が subscribe メソッドを持つ' do
        result = described_class.demonstrate_notifier_structure

        expect(result[:notifier_class]).not_to be_nil
        expect(result[:responds_to_subscribe]).to be true
      end
    end
  end

  describe AsNotifications::LogSubscriberDemo do
    describe '.demonstrate_log_subscriber_concept' do
      it 'LogSubscriber の継承関係を確認する' do
        result = described_class.demonstrate_log_subscriber_concept

        expect(result[:inherits_from_subscriber]).to be true
        expect(result[:log_subscriber_class]).to eq('ActiveSupport::LogSubscriber')
        expect(result[:custom_is_log_subscriber]).to be true
      end
    end

    describe '.demonstrate_color_helpers' do
      it 'LogSubscriber インスタンスが必要なメソッドを持つ' do
        result = described_class.demonstrate_color_helpers

        expect(result[:has_logger_accessor]).to be true
        expect(result[:is_log_subscriber]).to be true
      end
    end
  end

  describe AsNotifications::PerformanceConsiderations do
    describe '.demonstrate_overhead_without_subscribers' do
      it 'サブスクライバーなしの instrument オーバーヘッドが小さい' do
        result = described_class.demonstrate_overhead_without_subscribers

        expect(result[:iterations]).to eq(1000)
        expect(result[:overhead_is_small]).to be true
        expect(result[:per_call_overhead_us]).to be_a(Numeric)
      end
    end

    describe '.demonstrate_overhead_with_subscriber' do
      it 'サブスクライバーありの場合に全イベントが配信される' do
        result = described_class.demonstrate_overhead_with_subscriber

        expect(result[:iterations]).to eq(1000)
        expect(result[:all_events_delivered]).to be true
        expect(result[:subscriber_called_count]).to eq(1000)
      end
    end

    describe '.best_practices' do
      it 'パフォーマンスベストプラクティスのリストを返す' do
        practices = described_class.best_practices

        expect(practices).to be_an(Array)
        expect(practices.size).to be >= 5
        expect(practices).to all(be_a(String))
      end
    end
  end
end
