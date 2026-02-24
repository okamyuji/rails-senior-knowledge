# frozen_string_literal: true

require_relative 'error_handling'

RSpec.describe ErrorHandling do
  describe '.demonstrate_exception_hierarchy' do
    let(:result) { described_class.demonstrate_exception_hierarchy }

    it 'すべてのカスタム例外が StandardError を継承していることを確認する' do
      expect(result[:all_inherit_standard_error]).to be true
    end

    it '例外階層の親子関係が正しいことを確認する' do
      expect(result[:business_is_application]).to be true
      expect(result[:validation_is_business]).to be true
      expect(result[:system_is_application]).to be true
    end

    it '各例外に適切なエラーコードと HTTP ステータスが設定されていることを確認する' do
      expect(result[:error_codes][:validation]).to eq 'VALIDATION_ERROR'
      expect(result[:error_codes][:authorization]).to eq 'AUTHORIZATION_ERROR'
      expect(result[:http_statuses][:validation]).to eq 422
      expect(result[:http_statuses][:authorization]).to eq 403
      expect(result[:http_statuses][:external]).to eq 503
    end

    it 'ValidationError の ancestors チェーンが正しい順序であることを確認する' do
      chain = result[:ancestors_chain]
      expect(chain).to include(
        ErrorHandling::ValidationError,
        ErrorHandling::BusinessError,
        ErrorHandling::ApplicationError
      )
      # ValidationError が BusinessError より先に出現する
      vi = chain.index(ErrorHandling::ValidationError)
      bi = chain.index(ErrorHandling::BusinessError)
      expect(vi).to be < bi
    end
  end

  describe '.demonstrate_rescue_from_pattern' do
    let(:result) { described_class.demonstrate_rescue_from_pattern }

    it 'ValidationError が専用ハンドラで処理されることを確認する' do
      expect(result[:validation_handled][:status]).to eq 422
      expect(result[:validation_handled][:error]).to eq 'VALIDATION'
      expect(result[:validation_handled][:field]).to eq :email
    end

    it 'SystemError が ApplicationError ハンドラで処理されることを確認する' do
      expect(result[:system_handled][:status]).to eq 500
      expect(result[:system_handled][:error]).to eq 'SYSTEM_ERROR'
    end
  end

  describe '.demonstrate_exception_vs_standard_error' do
    let(:result) { described_class.demonstrate_exception_vs_standard_error }

    it 'RuntimeError が StandardError のサブクラスであることを確認する' do
      expect(result[:runtime_is_standard]).to be true
      expect(result[:type_error_is_standard]).to be true
    end

    it 'SignalException と SystemExit が StandardError 外であることを確認する' do
      expect(result[:signal_is_not_standard]).to be true
      expect(result[:system_exit_is_not_standard]).to be true
      expect(result[:no_memory_is_not_standard]).to be true
    end

    it '危険なパターンの説明が含まれていることを確認する' do
      expect(result[:dangerous_pattern]).to include('rescue Exception')
      expect(result[:dangerous_pattern]).to include('SystemExit')
      expect(result[:dangerous_pattern]).to include('Interrupt')
    end
  end

  describe '.demonstrate_error_context_enrichment' do
    let(:result) { described_class.demonstrate_error_context_enrichment }

    it 'エラーレポートに構造化されたメタデータが含まれることを確認する' do
      expect(result[:error_class]).to eq 'ErrorHandling::ValidationError'
      expect(result[:error_code]).to eq 'VALIDATION_ERROR'
      expect(result[:http_status]).to eq 422
      expect(result[:has_metadata]).to be true
    end

    it 'メタデータにリクエスト情報が含まれることを確認する' do
      expect(result[:metadata_keys]).to include(:errors, :field, :request_id, :user_id)
    end
  end

  describe ErrorHandling::CircuitBreaker do
    describe '状態遷移' do
      it '初期状態が closed であることを確認する' do
        breaker = described_class.new(failure_threshold: 3)
        expect(breaker.state).to eq :closed
      end

      it '失敗が閾値に達すると open に遷移することを確認する' do
        breaker = described_class.new(failure_threshold: 2, recovery_timeout: 60)

        2.times do
          breaker.call { raise '障害' }
        rescue StandardError
          # 失敗を記録
        end

        expect(breaker.state).to eq :open
      end

      it 'open 状態で即座に ExternalServiceError を発生させることを確認する' do
        breaker = described_class.new(failure_threshold: 1, recovery_timeout: 60)

        begin
          breaker.call { raise '障害' }
        rescue StandardError
          # open に遷移
        end

        expect(breaker.state).to eq :open

        expect do
          breaker.call { 'この処理は実行されない' }
        end.to raise_error(ErrorHandling::ExternalServiceError, /Circuit breaker is open/)
      end

      it 'タイムアウト経過後に half_open → closed と回復することを確認する' do
        breaker = described_class.new(
          failure_threshold: 1,
          recovery_timeout: 0.05,
          success_threshold: 1
        )

        begin
          breaker.call { raise '障害' }
        rescue StandardError
          # open に遷移
        end

        expect(breaker.state).to eq :open

        sleep(0.1)

        # タイムアウト経過後、成功すると closed に戻る
        result = breaker.call { '回復' }
        expect(result).to eq '回復'
        expect(breaker.state).to eq :closed
      end
    end
  end

  describe '.demonstrate_circuit_breaker' do
    let(:result) { described_class.demonstrate_circuit_breaker }

    it 'Circuit Breaker の状態遷移が正しいことを確認する' do
      expect(result[:initial_state]).to eq :closed
      expect(result[:after_success_state]).to eq :closed
      expect(result[:after_failures_state]).to eq :open
      expect(result[:after_recovery_state]).to eq :closed
    end

    it 'open 状態でエラーが発生することを確認する' do
      expect(result[:open_raises][:error]).to be true
      expect(result[:open_raises][:message]).to include('Circuit breaker is open')
    end

    it '回復後に正常な結果を返すことを確認する' do
      expect(result[:recovery_result]).to eq '回復成功'
    end
  end

  describe ErrorHandling::RetryWithBackoff do
    it '一時的障害後にリトライで成功することを確認する' do
      call_count = 0
      handler = described_class.new(max_retries: 3, base_delay: 0.01, retryable_errors: [RuntimeError])

      result = handler.call do
        call_count += 1
        raise '一時的障害' if call_count < 2

        '成功'
      end

      expect(result).to eq '成功'
      expect(handler.attempts).to eq 2
    end

    it 'リトライ上限に達すると最後の例外を発生させることを確認する' do
      handler = described_class.new(max_retries: 2, base_delay: 0.01, retryable_errors: [RuntimeError])

      expect do
        handler.call { raise '永続的障害' }
      end.to raise_error(RuntimeError, '永続的障害')

      expect(handler.attempts).to eq 3 # 初回 + 2回リトライ
    end

    it 'リトライ対象外の例外は即座に再 raise されることを確認する' do
      handler = described_class.new(max_retries: 3, base_delay: 0.01, retryable_errors: [RuntimeError])

      expect do
        handler.call { raise ArgumentError, '不正な引数' }
      end.to raise_error(ArgumentError)

      expect(handler.attempts).to eq 1
      expect(handler.delays).to be_empty
    end

    it '待機時間が指数関数的に増加することを確認する' do
      handler = described_class.new(max_retries: 3, base_delay: 0.01, multiplier: 2, retryable_errors: [RuntimeError])

      begin
        handler.call { raise '障害' }
      rescue RuntimeError
        # 想定通り
      end

      # 遅延は増加するはず（ジッターがあるため厳密な倍数ではない）
      expect(handler.delays.length).to eq 3
      expect(handler.delays[1]).to be > handler.delays[0]
      expect(handler.delays[2]).to be > handler.delays[1]
    end
  end

  describe '.demonstrate_retry_with_backoff' do
    let(:result) { described_class.demonstrate_retry_with_backoff }

    it 'リトライ後に最終的に成功するケースを確認する' do
      expect(result[:eventual_success][:result]).to eq '3回目で成功'
      expect(result[:eventual_success][:total_attempts]).to eq 3
      expect(result[:eventual_success][:retries]).to eq 2
    end

    it 'リトライ上限超過のケースを確認する' do
      expect(result[:max_retries_exceeded][:error]).to eq '永続的障害'
      expect(result[:max_retries_exceeded][:total_attempts]).to eq 3
    end

    it 'リトライ対象外のエラーが即座に失敗するケースを確認する' do
      expect(result[:non_retryable][:error]).to eq '不正な引数'
      expect(result[:non_retryable][:total_attempts]).to eq 1
      expect(result[:non_retryable][:retries]).to eq 0
    end
  end

  describe '.demonstrate_error_wrapping' do
    let(:result) { described_class.demonstrate_error_wrapping }

    it '低レベルエラーがドメインエラーにラップされることを確認する' do
      wrapped = result[:wrapped_error]
      expect(wrapped[:domain_error_class]).to eq 'ErrorHandling::ExternalServiceError'
      expect(wrapped[:has_cause]).to be true
      expect(wrapped[:cause_class]).to eq 'Errno::ECONNREFUSED'
    end

    it 'cause チェーンで根本原因を辿れることを確認する' do
      chain = result[:cause_chain]
      expect(chain[:chain_length]).to be >= 2
      expect(chain[:chain_classes].first).to eq 'ErrorHandling::ApplicationError'
    end
  end

  describe '.demonstrate_fail_fast_vs_resilient' do
    let(:result) { described_class.demonstrate_fail_fast_vs_resilient }

    it '必須設定が不足している場合に即座に失敗することを確認する' do
      expect(result[:fail_fast_missing_config][:failed]).to be true
      expect(result[:fail_fast_missing_config][:message]).to include('DATABASE_URL')
    end

    it '必須設定が揃っている場合は正常終了することを確認する' do
      expect(result[:fail_fast_valid_config][:failed]).to be false
    end

    it 'プライマリ失敗時にフォールバックが使用されることを確認する' do
      fallback = result[:resilient_cache_fallback]
      expect(fallback[:used_fallback]).to be true
      expect(fallback[:result][:source]).to eq 'database'
    end

    it 'プライマリ成功時にフォールバックが使用されないことを確認する' do
      primary = result[:resilient_primary_success]
      expect(primary[:source]).to eq 'cache'
    end
  end

  describe '.demonstrate_error_reporting_integration' do
    let(:result) { described_class.demonstrate_error_reporting_integration }

    it 'エラーが報告サービスに記録されることを確認する' do
      expect(result[:total_reports]).to be >= 3
    end

    it '重要度別にエラーが分類されることを確認する' do
      expect(result[:severity_counts]).to have_key(:warning)
      expect(result[:severity_counts]).to have_key(:error)
    end

    it 'handle メソッドでエラーを吸収してフォールバック値を返すことを確認する' do
      expect(result[:handled_result]).to eq 'デフォルト値'
    end

    it 'record メソッドでエラーを報告しつつ再 raise することを確認する' do
      expect(result[:recorded_error]).to eq '致命的エラー'
    end

    it 'エラーレポートが構造化データを含むことを確認する' do
      expected_keys = %i[context error_class message severity timestamp]
      expect(result[:report_structure]).to include(*expected_keys)
    end
  end
end
