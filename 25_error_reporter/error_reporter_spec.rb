# frozen_string_literal: true

require_relative '../spec/spec_helper'
require_relative 'error_reporter'

RSpec.describe ErrorReporterDemo do
  # ==========================================================================
  # 1. handle - 例外を握りつぶして報告する
  # ==========================================================================
  describe '.demonstrate_handle' do
    let(:result) { described_class.demonstrate_handle }

    it 'handle がブロック内の例外を握りつぶして nil を返すことを確認する' do
      expect(result[:result_is_nil]).to be true
    end

    it 'handle が例外をサブスクライバに報告することを確認する' do
      expect(result[:error_reported]).to eq 'API接続エラー'
      expect(result[:was_handled]).to be true
    end

    it 'handle のデフォルト severity が :warning であることを確認する' do
      expect(result[:default_severity]).to eq :warning
    end
  end

  # ==========================================================================
  # 2. handle のフォールバック値
  # ==========================================================================
  describe '.demonstrate_handle_with_fallback' do
    let(:result) { described_class.demonstrate_handle_with_fallback }

    it '例外時にフォールバック値を返すことを確認する' do
      expect(result[:fallback_result]).to eq []
    end

    it '成功時はブロックの戻り値を返すことを確認する' do
      expect(result[:success_result]).to eq %w[item_a item_b item_c]
    end

    it '成功時にはエラーが報告されないことを確認する' do
      expect(result[:total_errors]).to eq 1
    end
  end

  # ==========================================================================
  # 3. record - 例外を報告してから再送出する
  # ==========================================================================
  describe '.demonstrate_record' do
    let(:result) { described_class.demonstrate_record }

    it 'record が例外を再送出することを確認する' do
      expect(result[:exception_re_raised]).to be true
    end

    it 'record が再送出前にサブスクライバに報告することを確認する' do
      expect(result[:error_reported]).to eq '決済処理エラー'
      expect(result[:was_handled]).to be false
    end

    it 'record のデフォルト severity が :error であることを確認する' do
      expect(result[:default_severity]).to eq :error
    end
  end

  # ==========================================================================
  # 4. report - 例外オブジェクトを直接報告する
  # ==========================================================================
  describe '.demonstrate_report' do
    let(:result) { described_class.demonstrate_report }

    it '捕捉済みの例外を直接報告できることを確認する' do
      expect(result[:error_class]).to eq 'ArgumentError'
      expect(result[:message]).to eq '不正な入力パラメータ'
    end

    it 'report メソッドの handled と severity を設定できることを確認する' do
      expect(result[:handled]).to be true
      expect(result[:severity]).to eq :warning
    end
  end

  # ==========================================================================
  # 5. 複数サブスクライバの同時利用
  # ==========================================================================
  describe '.demonstrate_multiple_subscribers' do
    let(:result) { described_class.demonstrate_multiple_subscribers }

    it '全サブスクライバにエラーが配信されることを確認する' do
      expect(result[:log_count]).to eq 2
      expect(result[:sentry_count]).to eq 2
      expect(result[:metrics_handled]).to eq 2
    end

    it '各サブスクライバが独自の形式で情報を保持することを確認する' do
      expect(result[:sentry_last_level]).to eq 'warning'
      expect(result[:metrics_severity_warning]).to eq 1
    end
  end

  # ==========================================================================
  # 6. コンテキスト情報の付与
  # ==========================================================================
  describe '.demonstrate_context_enrichment' do
    let(:result) { described_class.demonstrate_context_enrichment }

    it 'スレッドコンテキストと引数コンテキストがマージされることを確認する' do
      expect(result[:has_user_id]).to be true
      expect(result[:has_request_id]).to be true
      expect(result[:has_action]).to be true
      expect(result[:has_cart_id]).to be true
    end

    it 'マージ後のコンテキストに全情報が含まれることを確認する' do
      ctx = result[:full_context]
      expect(ctx[:user_id]).to eq 42
      expect(ctx[:request_id]).to eq 'req-abc-123'
      expect(ctx[:action]).to eq 'checkout'
      expect(ctx[:cart_id]).to eq 999
    end

    it 'clear_context! でスレッドコンテキストがクリアされることを確認する' do
      expect(result[:context_after_clear]).to eq({})
    end
  end

  # ==========================================================================
  # 7. severity レベルの使い分け
  # ==========================================================================
  describe '.demonstrate_severity_levels' do
    let(:result) { described_class.demonstrate_severity_levels }

    it '各 severity レベルが正しく報告されることを確認する' do
      expect(result[:event_levels]).to eq %w[error warning info]
    end

    it 'severity ごとのカウントが正確であることを確認する' do
      expect(result[:error_count]).to eq 1
      expect(result[:warning_count]).to eq 1
      expect(result[:total_events]).to eq 3
    end
  end

  # ==========================================================================
  # 8. source パラメータ
  # ==========================================================================
  describe '.demonstrate_source_parameter' do
    let(:result) { described_class.demonstrate_source_parameter }

    it 'source ごとにエラーが分類されることを確認する' do
      expect(result[:application_errors]).to eq 1
      expect(result[:active_job_errors]).to eq 1
      expect(result[:stripe_errors]).to eq 1
    end

    it '全エラーが handled としてカウントされることを確認する' do
      expect(result[:total_handled]).to eq 3
    end
  end

  # ==========================================================================
  # 9. 特定の例外クラスのみをキャッチする
  # ==========================================================================
  describe '.demonstrate_specific_error_class' do
    let(:result) { described_class.demonstrate_specific_error_class }

    it '指定したクラスの例外が handle でキャッチされることを確認する' do
      expect(result[:argument_error_handled]).to eq 'フォールバック'
    end

    it '指定外のクラスの例外はキャッチされないことを確認する' do
      expect(result[:runtime_error_not_caught]).to be true
    end

    it 'キャッチされた例外のみがサブスクライバに報告されることを確認する' do
      expect(result[:reported_count]).to eq 1
      expect(result[:reported_class]).to eq 'ArgumentError'
    end
  end

  # ==========================================================================
  # 10. 実践的な統合パターン
  # ==========================================================================
  describe '.demonstrate_integration_pattern' do
    let(:result) { described_class.demonstrate_integration_pattern }

    it 'handle でフォールバック値を使って処理を継続できることを確認する' do
      expect(result[:recommendations_fallback]).to eq []
    end

    it 'record で報告後に例外が再送出されることを確認する' do
      expect(result[:payment_error]).to eq '決済プロバイダ通信エラー'
    end

    it '複数サブスクライバに正しくイベントが配信されることを確認する' do
      expect(result[:sentry_events]).to eq 2
      expect(result[:handled_count]).to eq 1
      expect(result[:unhandled_count]).to eq 1
    end

    it 'コンテキスト情報がサブスクライバに渡されることを確認する' do
      ctx = result[:sentry_first_context]
      expect(ctx[:user_id]).to eq 123
      expect(ctx[:request_id]).to eq 'req-xyz-789'
      expect(ctx[:action]).to eq 'show'
    end
  end

  # ==========================================================================
  # ErrorReporter クラスの単体テスト
  # ==========================================================================
  describe ErrorReporterDemo::ErrorReporter do
    let(:reporter) { described_class.new }
    let(:subscriber) { ErrorReporterDemo::LogSubscriber.new }

    before do
      reporter.subscribe(subscriber)
      reporter.clear_context!
    end

    describe '#subscribe' do
      it 'report メソッドを持たないオブジェクトを拒否する' do
        expect { reporter.subscribe(Object.new) }.to raise_error(ArgumentError, /report メソッドを実装/)
      end

      it '複数のサブスクライバを登録できる' do
        another = ErrorReporterDemo::SentryLikeSubscriber.new
        reporter.subscribe(another)
        expect(reporter.subscribers.size).to eq 2
      end
    end

    describe '#unsubscribe' do
      it 'サブスクライバを解除するとエラーが報告されなくなる' do
        reporter.unsubscribe(subscriber)

        reporter.handle do
          raise StandardError, 'テストエラー'
        end

        expect(subscriber.reported_errors).to be_empty
      end
    end

    describe '#handle' do
      it '例外が発生しない場合はブロックの戻り値を返す' do
        result = reporter.handle { '成功' }
        expect(result).to eq '成功'
        expect(subscriber.reported_errors).to be_empty
      end

      it '不正な severity を指定すると ArgumentError が発生する' do
        expect do
          reporter.handle(severity: :critical) do
            raise StandardError, 'テスト'
          end
        end.to raise_error(ArgumentError, /severity/)
      end
    end

    describe '#record' do
      it '例外が発生しない場合はブロックの戻り値を返す' do
        result = reporter.record { '成功' }
        expect(result).to eq '成功'
        expect(subscriber.reported_errors).to be_empty
      end
    end

    describe 'サブスクライバ自体のエラー耐性' do
      it 'サブスクライバがエラーを起こしても他のサブスクライバには影響しない' do
        # エラーを起こす壊れたサブスクライバ
        broken_subscriber = Object.new
        def broken_subscriber.report(*, **)
          raise 'サブスクライバ内部エラー'
        end

        good_subscriber = ErrorReporterDemo::LogSubscriber.new

        reporter.subscribe(broken_subscriber)
        reporter.subscribe(good_subscriber)

        reporter.handle do
          raise StandardError, 'テストエラー'
        end

        # 壊れたサブスクライバがあっても、正常なサブスクライバにはエラーが届く
        expect(good_subscriber.reported_errors.size).to eq 1
        expect(good_subscriber.last_error[:message]).to eq 'テストエラー'
      end
    end
  end
end
