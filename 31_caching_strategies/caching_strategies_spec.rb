# frozen_string_literal: true

require_relative 'caching_strategies'

RSpec.describe CachingStrategies do
  # ==========================================================================
  # 1. キャッシュストアインターフェース
  # ==========================================================================
  describe 'CacheStoreInterface' do
    describe '.demonstrate_unified_api' do
      let(:result) { CachingStrategies::CacheStoreInterface.demonstrate_unified_api }

      it '統一APIでread/write/delete/exist?が正しく動作すること' do
        expect(result[:write_and_read]).to eq({ name: '田中太郎', role: 'admin' })
        expect(result[:read_missing]).to be_nil
        expect(result[:exist_true]).to be true
        expect(result[:exist_false]).to be false
        expect(result[:after_delete]).to be_nil
        expect(result[:store_class]).to eq 'ActiveSupport::Cache::MemoryStore'
      end
    end

    describe '.demonstrate_memory_store_eviction' do
      let(:result) { CachingStrategies::CacheStoreInterface.demonstrate_memory_store_eviction }

      it 'サイズ制限を超えるとエビクションが発生すること' do
        expect(result[:total_written]).to eq 20
        expect(result[:surviving_count]).to be < result[:total_written]
        expect(result[:evicted_count]).to be_positive
        expect(result[:surviving_count] + result[:evicted_count]).to eq 20
      end
    end
  end

  # ==========================================================================
  # 2. fetchとCache-asideパターン
  # ==========================================================================
  describe 'FetchPattern' do
    describe '.demonstrate_fetch_basic' do
      let(:result) { CachingStrategies::FetchPattern.demonstrate_fetch_basic }

      it 'fetchがキャッシュミス時のみブロックを実行すること' do
        expect(result[:computation_count]).to eq 1
        expect(result[:cache_hit_on_second]).to be true
        expect(result[:results_identical]).to be true
        expect(result[:first_result]).to eq '計算結果'
      end
    end

    describe '.demonstrate_fetch_force' do
      let(:result) { CachingStrategies::FetchPattern.demonstrate_fetch_force }

      it 'force: trueでキャッシュを強制更新できること' do
        expect(result[:refreshed_value]).to eq '新しいデータ'
        expect(result[:is_new_value]).to be true
      end
    end

    describe '.demonstrate_fetch_skip_nil' do
      let(:result) { CachingStrategies::FetchPattern.demonstrate_fetch_skip_nil }

      it 'skip_nil: trueでnilがキャッシュされないこと' do
        # skip_nilなしの場合、nilもキャッシュされる
        expect(result[:nil_without_skip_nil_cached]).to be true
        # skip_nil: trueの場合、nilはキャッシュされない
        expect(result[:nil_with_skip_nil_cached]).to be false
      end
    end
  end

  # ==========================================================================
  # 3. キャッシュ有効期限
  # ==========================================================================
  describe 'CacheExpiration' do
    describe '.demonstrate_expires_in' do
      let(:result) { CachingStrategies::CacheExpiration.demonstrate_expires_in }

      it 'expires_inで設定した期限後にキャッシュが無効化されること' do
        # 期限切れ前は全て存在する
        expect(result[:before_expiry][:short_lived]).to be true
        expect(result[:before_expiry][:long_lived]).to be true
        expect(result[:before_expiry][:no_expiry]).to be true

        # 期限切れ後: 短期エントリのみ消失
        expect(result[:short_lived_expired]).to be true
        expect(result[:long_lived_still_valid]).to be true
        expect(result[:no_expiry_still_valid]).to be true
      end
    end

    describe '.demonstrate_race_condition_ttl_concept' do
      let(:result) { CachingStrategies::CacheExpiration.demonstrate_race_condition_ttl_concept }

      it 'race_condition_ttlの概念が正しく説明されること' do
        expect(result[:initial_result]).to eq '計算結果_1'
        expect(result[:computation_count]).to eq 1
        expect(result[:explanation]).to have_key(:without_race_condition_ttl)
        expect(result[:explanation]).to have_key(:with_race_condition_ttl)
        expect(result[:explanation][:with_race_condition_ttl].size).to eq 4
      end
    end

    describe '.simulate_race_condition_ttl' do
      let(:result) { CachingStrategies::CacheExpiration.simulate_race_condition_ttl }

      it '期限切れ後にキャッシュが再計算されること' do
        expect(result[:initial_value]).to eq 'value_v1'
        expect(result[:was_recomputed]).to be true
        expect(result[:total_fetch_count]).to eq 2
      end
    end
  end

  # ==========================================================================
  # 4. キャッシュバージョニング
  # ==========================================================================
  describe 'CacheVersioning' do
    describe '.demonstrate_cache_versioning' do
      let(:result) { CachingStrategies::CacheVersioning.demonstrate_cache_versioning }

      it 'バージョン変更でキャッシュが無効化されること' do
        # キーは同一だがバージョンが異なる
        expect(result[:same_cache_key]).to be true
        expect(result[:different_version]).to be true

        # v1はヒット
        expect(result[:v1_cache_hit]).to eq 'キャッシュデータv1'
        # v2は書き込み前はミス、書き込み後はヒット
        expect(result[:v2_cache_miss_before_write]).to be_nil
        expect(result[:v2_cache_hit_after_write]).to eq 'キャッシュデータv2'
      end
    end

    describe '.demonstrate_recyclable_keys' do
      let(:result) { CachingStrategies::CacheVersioning.demonstrate_recyclable_keys }

      it 'キーが再利用されバージョンのみ変わること' do
        expect(result[:all_keys_identical]).to be true
        expect(result[:all_versions_unique]).to be true
      end
    end
  end

  # ==========================================================================
  # 5. ロシアンドールキャッシング
  # ==========================================================================
  describe 'RussianDollCaching' do
    describe '.demonstrate_russian_doll' do
      let(:result) { CachingStrategies::RussianDollCaching.demonstrate_russian_doll }

      it '2回目のレンダリングでキャッシュヒットにより再実行が発生しないこと' do
        # 初回は外側1回 + 内側3回のレンダリング
        expect(result[:first_pass_renders][:outer]).to eq 1
        expect(result[:first_pass_renders][:inner]).to eq 3

        # 2回目はレンダリング回数が増えない
        expect(result[:no_rerender_on_hit]).to be true
        expect(result[:second_same_as_first]).to be true
      end
    end

    describe '.demonstrate_touch_cascade' do
      let(:result) { CachingStrategies::RussianDollCaching.demonstrate_touch_cascade }

      it 'touchによるバージョン変更でキャッシュが無効化されること' do
        expect(result[:cached_before_touch]).to be_a(String)
        expect(result[:still_valid_with_old_version]).to be_a(String)
        expect(result[:miss_with_new_version]).to be_nil
        expect(result[:parent_version_changed]).to be true
      end
    end
  end

  # ==========================================================================
  # 6. キャッシュキー生成
  # ==========================================================================
  describe 'CacheKeyGeneration' do
    describe '.demonstrate_cache_key_patterns' do
      let(:result) { CachingStrategies::CacheKeyGeneration.demonstrate_cache_key_patterns }

      it 'キャッシュキーが正しいフォーマットで生成されること' do
        expect(result[:single_model][:cache_key]).to eq 'users/42'
        expect(result[:single_model][:cache_version]).to be_a(String)
        expect(result[:single_model][:cache_key_with_version]).to include('users/42-')
        expect(result[:collection][:count]).to eq 3
      end
    end

    describe '.demonstrate_namespaced_keys' do
      let(:result) { CachingStrategies::CacheKeyGeneration.demonstrate_namespaced_keys }

      it '名前空間で隔離されたキャッシュが正しく動作すること' do
        expect(result[:value_in_namespace]).to eq 'データ'
        expect(result[:cross_namespace_read]).to be_nil
      end
    end
  end

  # ==========================================================================
  # 7. 条件付きキャッシュ（HTTPキャッシング概念）
  # ==========================================================================
  describe 'ConditionalCaching' do
    describe '.demonstrate_etag_concept' do
      let(:result) { CachingStrategies::ConditionalCaching.demonstrate_etag_concept }

      it 'ETagが一致した場合に304 Not Modifiedを返すこと' do
        expect(result[:not_modified]).to be true
        expect(result[:http_status]).to eq 304
        expect(result[:etag]).to be_a(String)
        expect(result[:flow]).to have_key(:step1)
      end
    end

    describe '.demonstrate_last_modified_concept' do
      let(:result) { CachingStrategies::ConditionalCaching.demonstrate_last_modified_concept }

      it 'Last-Modifiedベースのキャッシング概念が正しいこと' do
        expect(result[:not_modified]).to be true
        expect(result[:http_status]).to eq 304
        expect(result[:rails_helpers]).to have_key(:stale)
        expect(result[:cache_control_headers]).to have_key(:public)
      end
    end

    describe '.simulate_stale_check' do
      let(:result) { CachingStrategies::ConditionalCaching.simulate_stale_check }

      it 'stale?の3つのケースが正しくシミュレートされること' do
        # 初回リクエスト: stale（キャッシュなし）
        expect(result[:case1_first_request][:is_stale]).to be true

        # 2回目: not stale（ETag一致）
        expect(result[:case2_cache_hit][:is_stale]).to be false

        # 更新後: stale（ETag不一致）
        expect(result[:case3_after_update][:is_stale]).to be true
      end
    end
  end

  # ==========================================================================
  # 8. マルチレベルキャッシング
  # ==========================================================================
  describe 'MultiLevelCaching' do
    describe '.demonstrate_multi_level' do
      let(:result) { CachingStrategies::MultiLevelCaching.demonstrate_multi_level }

      it 'L1/L2キャッシュが正しく階層的に動作すること' do
        # 全ての結果が同じ値
        expect(result[:all_same_value]).to be true

        # ブロック実行は1回のみ
        expect(result[:computation_count]).to eq 1

        # 統計: L1ヒット2回、L2ヒット1回、ミス1回
        expect(result[:stats][:l1_hit]).to eq 2
        expect(result[:stats][:l2_hit]).to eq 1
        expect(result[:stats][:miss]).to eq 1

        # ヒット率 75%（4回中3回ヒット）
        expect(result[:hit_rate]).to eq 75.0
      end
    end

    describe '.best_practices' do
      let(:result) { CachingStrategies::MultiLevelCaching.best_practices }

      it 'マルチレベルキャッシングのベストプラクティスが返されること' do
        expect(result[:l1_configuration]).to have_key(:size)
        expect(result[:l2_configuration]).to have_key(:backend)
        expect(result[:invalidation_strategy]).to have_key(:delete_through)
        expect(result[:pitfalls]).to be_an(Array)
        expect(result[:pitfalls].size).to be >= 3
      end
    end
  end

  # ==========================================================================
  # 9. キャッシュ戦略の比較
  # ==========================================================================
  describe 'StrategyComparison' do
    describe '.comparison_guide' do
      let(:result) { CachingStrategies::StrategyComparison.comparison_guide }

      it '全キャッシング戦略が網羅されていること' do
        expect(result).to have_key(:page_caching)
        expect(result).to have_key(:fragment_caching)
        expect(result).to have_key(:russian_doll)
        expect(result).to have_key(:low_level_caching)
        expect(result).to have_key(:http_caching)

        # 各戦略に必要な情報が含まれていること
        result.each_value do |strategy|
          expect(strategy).to have_key(:description)
          expect(strategy).to have_key(:use_case)
          expect(strategy).to have_key(:rails_support)
        end
      end
    end
  end

  # ==========================================================================
  # TwoLevelCache 単体テスト
  # ==========================================================================
  describe CachingStrategies::MultiLevelCaching::TwoLevelCache do
    let(:cache) { described_class.new }

    describe '#fetch' do
      it '初回はブロックを実行しL1・L2の両方に格納すること' do
        value = cache.fetch('key1', 'computed_value')

        expect(value).to eq 'computed_value'
        expect(cache.l1_store.read('key1')).to eq 'computed_value'
        expect(cache.l2_store.read('key1')).to eq 'computed_value'
        expect(cache.stats[:miss]).to eq 1
      end

      it 'L1ヒット時はブロックを実行しないこと' do
        cache.fetch('key1', 'original')

        call_count = 0
        value = cache.fetch('key1') do
          call_count += 1
          'recomputed'
        end

        expect(value).to eq 'original'
        expect(call_count).to eq 0
        expect(cache.stats[:l1_hit]).to eq 1
      end

      it 'L1ミス・L2ヒット時にL1へ書き戻すこと' do
        cache.fetch('key1', 'value_from_db')
        cache.clear_l1

        # L1はクリア済み、L2にはデータがある
        expect(cache.l1_store.read('key1')).to be_nil
        expect(cache.l2_store.read('key1')).to eq 'value_from_db'

        # fetchでL2からL1に書き戻し
        value = cache.fetch('key1', 'should_not_run')
        expect(value).to eq 'value_from_db'
        expect(cache.l1_store.read('key1')).to eq 'value_from_db'
        expect(cache.stats[:l2_hit]).to eq 1
      end
    end

    describe '#delete' do
      it 'L1とL2の両方から削除すること' do
        cache.fetch('key1', 'value')
        cache.delete('key1')

        expect(cache.l1_store.read('key1')).to be_nil
        expect(cache.l2_store.read('key1')).to be_nil
      end
    end

    describe '#hit_rate' do
      it 'ヒット率が正しく計算されること' do
        expect(cache.hit_rate).to eq 0.0

        cache.fetch('a', 1)  # miss
        cache.fetch('a', 1)  # l1_hit

        expect(cache.hit_rate).to eq 50.0
      end
    end
  end
end
