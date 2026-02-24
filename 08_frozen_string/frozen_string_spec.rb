# frozen_string_literal: true

require_relative '../spec/spec_helper'
require_relative 'frozen_string'

RSpec.describe FrozenStringLiteral do
  # ===========================================
  # 1. frozen_string_literal プラグマの効果
  # ===========================================
  describe 'frozen_string_literal プラグマ' do
    it '文字列リテラルがフリーズされていること' do
      result = FrozenStringLiteral::PragmaEffect.demonstrate_frozen_literals
      expect(result[:frozen]).to be true
      expect(result[:value]).to eq 'hello'
    end

    it 'フリーズされた文字列への破壊的操作でFrozenErrorが発生すること' do
      result = FrozenStringLiteral::PragmaEffect.demonstrate_frozen_error
      expect(result[:error_class]).to eq 'FrozenError'
      expect(result[:message]).to include('frozen')
    end

    it 'このファイル内の文字列リテラルがフリーズされていること' do
      str = 'test string'
      expect(str).to be_frozen
      expect { str << ' append' }.to raise_error(FrozenError)
    end
  end

  # ===========================================
  # 2. String#freeze と プラグマの違い
  # ===========================================
  describe 'String#freeze とプラグマの比較' do
    it '式展開を含む文字列はプラグマ有効時でもフリーズされないこと' do
      result = FrozenStringLiteral::FreezeComparison.interpolated_string_behavior
      expect(result[:frozen]).to be false
      expect(result[:value]).to eq 'Hello, Ruby'
    end

    it '同一内容の freeze 済み文字列がデデュプリケーションされること' do
      result = FrozenStringLiteral::FreezeComparison.explicit_freeze_deduplication
      expect(result[:same_object]).to be true
      expect(result[:object_id_a]).to eq result[:object_id_b]
    end
  end

  # ===========================================
  # 3. 文字列デデュプリケーション
  # ===========================================
  describe '文字列デデュプリケーション（-@ / +@）' do
    it '単項マイナスで同一オブジェクトが返ること' do
      result = FrozenStringLiteral::StringDeduplication.demonstrate_dedup
      expect(result[:same_object]).to be true
      expect(result[:a_frozen]).to be true
    end

    it '動的文字列のデデュプリケーションが機能すること' do
      result = FrozenStringLiteral::StringDeduplication.dedup_dynamic_string
      expect(result[:deduped_frozen]).to be true
      expect(result[:deduped_value]).to eq 'hello'
    end

    it '既にフリーズ済みの文字列に -@ を適用すると同一オブジェクトが返ること' do
      result = FrozenStringLiteral::StringDeduplication.minus_at_behavior
      expect(result[:original_frozen]).to be true
      expect(result[:same_object]).to be true
    end
  end

  # ===========================================
  # 4. メモリへの影響
  # ===========================================
  describe 'メモリ最適化' do
    it '同一リテラルが同一オブジェクトIDを共有すること' do
      result = FrozenStringLiteral::MemoryImpact.demonstrate_object_sharing
      expect(result[:all_same]).to be true
    end

    it 'フリーズ文字列とミュータブル文字列でユニークオブジェクト数が異なること' do
      result = FrozenStringLiteral::MemoryImpact.memory_comparison_simulation
      expect(result[:frozen_unique_objects]).to eq 1
      expect(result[:mutable_unique_objects]).to be > 1
    end
  end

  # ===========================================
  # 5. ミュータブル文字列パターン
  # ===========================================
  describe 'ミュータブル文字列の作成パターン' do
    it 'String.new でミュータブル文字列を作成できること' do
      result = FrozenStringLiteral::MutablePatterns.string_new_pattern
      expect(result[:value]).to eq 'hello world'
      expect(result[:frozen]).to be false
    end

    it '単項プラス（+）でミュータブルコピーを取得できること' do
      result = FrozenStringLiteral::MutablePatterns.unary_plus_pattern
      expect(result[:value]).to eq 'hello world'
      expect(result[:frozen]).to be false
    end

    it '.dup でミュータブルコピーを取得できること' do
      result = FrozenStringLiteral::MutablePatterns.dup_pattern
      expect(result[:original]).to eq 'hello'
      expect(result[:copy]).to eq 'hello world'
      expect(result[:original_frozen]).to be true
      expect(result[:copy_frozen]).to be false
    end

    it 'バッファ構築パターンが正しく動作すること' do
      result = FrozenStringLiteral::MutablePatterns.buffer_building_pattern
      expect(result[:result]).to eq 'name,age,email'
      expect(result[:frozen]).to be false
    end

    it 'エンコーディング指定付き String.new が正しく動作すること' do
      result = FrozenStringLiteral::MutablePatterns.string_new_with_encoding
      expect(result[:binary_encoding]).to eq 'ASCII-8BIT'
      expect(result[:utf8_encoding]).to eq 'UTF-8'
      expect(result[:binary_frozen]).to be false
    end
  end

  # ===========================================
  # 6. Hashキーへの影響
  # ===========================================
  describe 'Hashキーへの影響' do
    it 'フリーズ済み文字列キーがdupされずにそのまま使用されること' do
      result = FrozenStringLiteral::HashKeyImpact.demonstrate_hash_key_freeze
      expect(result[:original_frozen]).to be true
      expect(result[:stored_key_frozen]).to be true
      expect(result[:same_object]).to be true
    end

    it 'ミュータブルな文字列キーがHashにより自動的にdup+freezeされること' do
      result = FrozenStringLiteral::HashKeyImpact.demonstrate_mutable_key_behavior
      expect(result[:original_frozen]).to be false
      expect(result[:stored_key_frozen]).to be true
      expect(result[:same_object]).to be false
      expect(result[:same_value]).to be true
    end
  end

  # ===========================================
  # 7. Chilled Strings（Ruby 3.4）の概念理解
  # ===========================================
  describe 'Chilled Strings 概念' do
    it 'バージョン比較情報が正しい構造を持つこと' do
      result = FrozenStringLiteral::ChilledStrings.version_comparison
      expect(result).to have_key('Ruby 3.3以前')
      expect(result).to have_key('Ruby 3.4')
      expect(result).to have_key('将来のRuby')
      expect(result['Ruby 3.4'][:no_pragma]).to include('Chilled')
    end

    it 'Chilled Stringの説明が提供されること' do
      explanation = FrozenStringLiteral::ChilledStrings.explain_chilled_behavior
      expect(explanation).to include('Chilled')
      expect(explanation).to include('warning')
      expect(explanation).to include('frozen')
    end
  end

  # ===========================================
  # 8. 移行戦略
  # ===========================================
  describe '移行戦略' do
    it '移行ステップが4段階で構成されていること' do
      steps = FrozenStringLiteral::MigrationStrategy.migration_steps
      expect(steps.keys).to eq %i[step1 step2 step3 step4]
      expect(steps[:step1][:title]).to eq '現状把握'
    end

    it '一般的な落とし穴が網羅されていること' do
      pitfalls = FrozenStringLiteral::MigrationStrategy.common_pitfalls
      expect(pitfalls).to have_key('テンプレートエンジン')
      expect(pitfalls).to have_key('ジェムの互換性')
      expect(pitfalls).to have_key('メタプログラミング')
      expect(pitfalls).to have_key('IO操作')
    end

    it 'RuboCop設定例が提供されること' do
      config = FrozenStringLiteral::MigrationStrategy.rubocop_config_example
      expect(config).to include('FrozenStringLiteralComment')
      expect(config).to include('always')
    end
  end

  # ===========================================
  # 9. 直接的な動作確認（統合テスト）
  # ===========================================
  describe '直接的な動作確認' do
    it 'frozen_string_literal: true 環境でリテラルと+リテラルの違いを確認' do
      frozen_str = 'immutable'
      mutable_str = +'mutable'

      expect(frozen_str).to be_frozen
      expect(mutable_str).not_to be_frozen

      expect { frozen_str << '!' }.to raise_error(FrozenError)
      expect { mutable_str << '!' }.not_to raise_error
      expect(mutable_str).to eq 'mutable!'
    end

    it '同一フリーズリテラルがobject_idを共有すること' do
      # frozen_string_literal: true 環境下
      id1 = 'same_literal'.object_id
      id2 = 'same_literal'.object_id
      expect(id1).to eq id2
    end

    it '-@ と +@ が逆の操作であること' do
      original = 'hello'
      expect(original).to be_frozen

      mutable = +original
      expect(mutable).not_to be_frozen
      expect(mutable).to eq original
      expect(mutable).not_to equal(original)

      refrozen = -mutable
      expect(refrozen).to be_frozen
      expect(refrozen).to eq original
    end
  end
end
