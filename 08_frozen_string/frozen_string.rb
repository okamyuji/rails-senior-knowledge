# frozen_string_literal: true

# == Frozen String Literal と Chilled String ==
#
# Ruby 3.4で導入された「Chilled String」の概念を含め、
# 文字列のフリーズ機構、メモリ最適化、移行戦略を包括的に解説する。
#
# 対象読者: シニアRailsエンジニア
module FrozenStringLiteral
  # ============================================================
  # 1. frozen_string_literal プラグマの効果
  # ============================================================
  #
  # ファイル先頭の `# frozen_string_literal: true` マジックコメントにより、
  # そのファイル内のすべての文字列リテラルが自動的にフリーズされる。
  #
  # 効果:
  # - 文字列リテラルへの破壊的操作（<<, gsub!, replace等）が FrozenError を発生
  # - 同一内容の文字列リテラルがメモリ上で共有される可能性がある
  # - GCの負荷軽減とメモリ使用量の削減
  module PragmaEffect
    # frozen_string_literal: true が有効なファイルでの文字列リテラルの状態を確認
    def self.demonstrate_frozen_literals
      str = 'hello'
      {
        value: str,
        frozen: str.frozen?, # => true（プラグマにより自動フリーズ）
        object_id: str.object_id
      }
    end

    # フリーズされた文字列への破壊的操作は FrozenError を発生させる
    def self.demonstrate_frozen_error
      str = 'hello'
      str << ' world' # => FrozenError: can't modify frozen String: "hello"
    rescue FrozenError => e
      { error_class: e.class.name, message: e.message }
    end
  end

  # ============================================================
  # 2. String#freeze と frozen_string_literal の違い
  # ============================================================
  #
  # - `frozen_string_literal: true`: ファイル内の全文字列リテラルを暗黙的にフリーズ
  # - `String#freeze`: 個別の文字列を明示的にフリーズ
  #
  # 重要な違い:
  # - プラグマはコンパイル時に作用し、freeze はランタイムに作用する
  # - プラグマ有効時、"str".freeze は追加コストなし（既にフリーズ済み）
  # - 式展開を含む文字列は動的に生成されるため、プラグマではフリーズされない
  module FreezeComparison
    # プラグマ有効時でも式展開を含む文字列はフリーズされない。
    # 式展開を含む文字列は実行時に動的に生成されるため、
    # コンパイル時に最適化されるリテラルとは異なる扱いとなる。
    def self.interpolated_string_behavior
      name = 'Ruby'
      interpolated = "Hello, #{name}"
      {
        value: interpolated,
        frozen: interpolated.frozen? # => false（式展開はフリーズされない）
      }
    end

    # 明示的 freeze は frozen_string_literal がないファイルで有用
    # 同一内容の freeze された文字列はデデュプリケーションされる
    def self.explicit_freeze_deduplication
      # frozen_string_literal: true のファイルでは
      # "hello".freeze は冗長だが害はない
      a = 'hello'
      b = 'hello'
      {
        same_object: a.equal?(b), # => true
        object_id_a: a.object_id,
        object_id_b: b.object_id
      }
    end
  end

  # ============================================================
  # 3. Chilled Strings（Ruby 3.4の新概念）
  # ============================================================
  #
  # Ruby 3.4では、frozen_string_literal プラグマが指定されていないファイルの
  # 文字列リテラルが「Chilled（冷却された）」状態になる。
  #
  # Chilled String の特徴:
  # - frozen? は true を返す
  # - 破壊的操作を行うと、即座に FrozenError ではなく警告を出してから実行
  # - 将来のRubyバージョンでデフォルトフリーズに完全移行するための橋渡し
  #
  # これにより、既存コードを段階的に frozen_string_literal: true に
  # 移行できるようになる。
  module ChilledStrings
    # Chilled Stringの動作をシミュレート
    # 注意: このファイルは frozen_string_literal: true なので、
    # 実際のChilled Stringの動作はプラグマなしのファイルでのみ確認可能
    #
    # Chilled Stringのライフサイクル:
    # 1. リテラル作成時: frozen状態（chilled）
    # 2. 破壊的操作時: 警告を出してunfreezeし、操作を実行
    # 3. 操作後: 通常のミュータブル文字列として振る舞う
    def self.explain_chilled_behavior
      <<~EXPLANATION
        Ruby 3.4 Chilled String の動作:

        # frozen_string_literal プラグマなしのファイルで:
        str = "hello"
        str.frozen?        # => true（chilled状態）

        # 破壊的操作を試みると:
        str << " world"    # => warning: literal string will be frozen in the future
                           #    (ただし操作は成功する)

        str.frozen?        # => false（unfreezeされた）
        str                # => "hello world"

        # frozen_string_literal: true のファイルでは:
        str = "hello"
        str << " world"    # => FrozenError（即座にエラー）
      EXPLANATION
    end

    # Ruby 3.3以前 vs Ruby 3.4 の比較
    def self.version_comparison
      {
        'Ruby 3.3以前' => {
          pragma_true: '文字列リテラルはフリーズ、破壊的操作でFrozenError',
          pragma_false: '文字列リテラルはミュータブル、自由に変更可能',
          no_pragma: '文字列リテラルはミュータブル、自由に変更可能'
        },
        'Ruby 3.4' => {
          pragma_true: '文字列リテラルはフリーズ、破壊的操作でFrozenError',
          pragma_false: '文字列リテラルはミュータブル、自由に変更可能',
          no_pragma: '文字列リテラルはChilled、破壊的操作で警告後に実行'
        },
        '将来のRuby' => {
          expected: '全文字列リテラルがデフォルトでフリーズ（FrozenError）'
        }
      }
    end
  end

  # ============================================================
  # 4. 文字列デデュプリケーション（-"string" / String#-@）
  # ============================================================
  #
  # `-"string"` （単項マイナス）は、フリーズされたデデュプリケーション済み
  # 文字列を返す。VM内部のフリーズ文字列テーブルから同一内容の文字列を検索し、
  # 存在すれば既存のオブジェクトを返す。
  module StringDeduplication
    # 単項マイナスによるデデュプリケーション
    def self.demonstrate_dedup
      a = -'hello'
      b = -'hello'
      {
        same_object: a.equal?(b),   # => true（同一オブジェクト）
        a_frozen: a.frozen?,        # => true
        object_id_a: a.object_id,
        object_id_b: b.object_id
      }
    end

    # 動的文字列のデデュプリケーション
    def self.dedup_dynamic_string
      base = 'hel'
      dynamic = "#{base}lo" # ミュータブルな動的文字列
      deduped = -dynamic # フリーズ＆デデュプリケーション

      literal = -'hello'

      {
        dynamic_value: dynamic,
        deduped_value: deduped,
        same_as_literal: deduped.equal?(literal), # => true（内容が同じならデデュプ）
        deduped_frozen: deduped.frozen? # => true
      }
    end

    # String#-@ の内部動作
    # 既にフリーズされていればそのまま返す（frozen_string_literal: true環境下）
    # フリーズされていなければ、freeze + dedup して返す
    def self.minus_at_behavior
      str = 'test'
      # frozen_string_literal: true なので str は既にフリーズ済み
      deduped = -str
      {
        original_frozen: str.frozen?,
        same_object: str.equal?(deduped), # => true（既にフリーズ済みなら同一）
        deduped_frozen: deduped.frozen?
      }
    end
  end

  # ============================================================
  # 5. メモリへの影響
  # ============================================================
  #
  # frozen_string_literal: true によるメモリ最適化:
  # - 同一内容の文字列リテラルがオブジェクトを共有
  # - 不要な文字列オブジェクトの生成を抑制
  # - GCの負荷を軽減
  module MemoryImpact
    # 同一リテラルのオブジェクトID共有を確認
    def self.demonstrate_object_sharing
      # frozen_string_literal: true 環境下では
      # 同一内容のリテラルが同一オブジェクトを参照する
      ids = 5.times.map { 'shared_string'.object_id }
      {
        all_same: ids.uniq.size == 1, # => true
        object_ids: ids
      }
    end

    # メモリ使用量の概算比較
    def self.memory_comparison_simulation
      # フリーズあり: 1つのオブジェクトを共有
      frozen_count = 1000
      frozen_ids = frozen_count.times.map { 'frozen_example'.object_id }
      unique_frozen = frozen_ids.uniq.size

      # ミュータブル: 毎回新しいオブジェクトが生成される
      mutable_ids = frozen_count.times.map { String.new('mutable_example').object_id }
      unique_mutable = mutable_ids.uniq.size

      {
        frozen_unique_objects: unique_frozen,      # => 1
        mutable_unique_objects: unique_mutable,    # => 1000
        memory_savings_ratio: "#{unique_frozen}/#{unique_mutable}"
      }
    end

    # ObjectSpace を使った実測（概算）
    def self.count_string_objects
      GC.start
      before = ObjectSpace.count_objects[:T_STRING]

      # フリーズされたリテラル（新しいオブジェクトは生成されない）
      100.times { 'frozen_literal_test' }

      GC.start
      after_frozen = ObjectSpace.count_objects[:T_STRING]

      # String.newでミュータブル文字列を大量生成
      strings = []
      100.times { strings << String.new('mutable_literal_test') }

      GC.start
      after_mutable = ObjectSpace.count_objects[:T_STRING]

      {
        before: before,
        after_frozen_literals: after_frozen,
        after_mutable_strings: after_mutable,
        frozen_increase: after_frozen - before,
        mutable_increase: after_mutable - after_frozen
      }
    end
  end

  # ============================================================
  # 6. ミュータブル文字列パターン
  # ============================================================
  #
  # frozen_string_literal: true 環境下でミュータブルな文字列が必要な場合:
  # - String.new("...") : 常にミュータブルな新しい文字列を生成
  # - +"..." : 単項プラスでミュータブルなコピーを取得（String#+@）
  # - .dup : フリーズされた文字列のミュータブルなコピーを取得
  module MutablePatterns
    # String.new でミュータブル文字列を作成
    def self.string_new_pattern
      mutable = String.new('hello')
      mutable << ' world'
      {
        value: mutable,             # => "hello world"
        frozen: mutable.frozen?     # => false
      }
    end

    # 単項プラス（+）でミュータブルコピーを取得
    def self.unary_plus_pattern
      mutable = +'hello'
      mutable << ' world'
      {
        value: mutable,             # => "hello world"
        frozen: mutable.frozen?     # => false
      }
    end

    # .dup でミュータブルコピーを取得
    def self.dup_pattern
      original = 'hello'
      copy = original.dup
      copy << ' world'
      {
        original: original,
        copy: copy,
        original_frozen: original.frozen?,  # => true
        copy_frozen: copy.frozen?           # => false
      }
    end

    # 実務でよく使うパターン: バッファ構築
    def self.buffer_building_pattern
      # CSVやログの行を組み立てるケース
      buffer = +''
      %w[name age email].each_with_index do |field, i|
        buffer << ',' if i.positive?
        buffer << field
      end
      {
        result: buffer,          # => "name,age,email"
        frozen: buffer.frozen?   # => false
      }
    end

    # エンコーディング指定付き String.new
    def self.string_new_with_encoding
      binary = String.new('binary data', encoding: Encoding::ASCII_8BIT)
      utf8 = String.new('UTF-8文字列', encoding: Encoding::UTF_8)
      {
        binary_encoding: binary.encoding.name,  # => "ASCII-8BIT"
        utf8_encoding: utf8.encoding.name,      # => "UTF-8"
        binary_frozen: binary.frozen?,           # => false
        utf8_frozen: utf8.frozen?                # => false
      }
    end
  end

  # ============================================================
  # 7. Hashキーへの影響
  # ============================================================
  #
  # RubyのHashは、文字列キーを自動的に dup + freeze する。
  # これは、キーがハッシュ外部から変更されることを防ぐため。
  #
  # frozen_string_literal: true 環境下では、文字列リテラルが
  # 既にフリーズ済みなので、dup のコストが不要になる。
  module HashKeyImpact
    # Hashキーの自動freeze動作
    def self.demonstrate_hash_key_freeze
      # frozen_string_literal: true ではキーは既にフリーズ済み
      key = 'my_key'
      hash = { key => 'value' }

      stored_key = hash.keys.first
      {
        original_frozen: key.frozen?, # => true
        stored_key_frozen: stored_key.frozen?, # => true
        same_object: key.equal?(stored_key) # => true（既にフリーズ済みならdupしない）
      }
    end

    # ミュータブルなキーでの挙動（比較用）
    def self.demonstrate_mutable_key_behavior
      mutable_key = String.new('my_key')
      hash = { mutable_key => 'value' }

      stored_key = hash.keys.first
      {
        original_frozen: mutable_key.frozen?,  # => false
        stored_key_frozen: stored_key.frozen?, # => true（Hashが自動freeze）
        same_object: mutable_key.equal?(stored_key), # => false（dupされる）
        same_value: mutable_key == stored_key # => true
      }
    end

    # シンボルキーとの比較
    def self.symbol_vs_frozen_string_keys
      # シンボルは常にフリーズされた一意なオブジェクト
      # フリーズ文字列もオブジェクト共有される
      # パフォーマンス特性は類似するが、シンボルの方がやや高速
      {
        symbol_key: :my_key.frozen?,            # => true
        frozen_string_key: 'my_key'.frozen?,    # => true
        recommendation: '内部識別子にはシンボル、外部データには文字列を使用'
      }
    end
  end

  # ============================================================
  # 8. 移行戦略
  # ============================================================
  #
  # frozen_string_literal: true をプロジェクト全体に適用するための戦略。
  # Ruby 3.4のChilled Stringにより、段階的な移行がさらに容易になった。
  module MigrationStrategy
    # 移行ステップの概要
    def self.migration_steps
      {
        step1: {
          title: '現状把握',
          actions: [
            "grep -rL 'frozen_string_literal' app/ lib/ でプラグマなしファイルを特定",
            'Ruby 3.4環境でテストを実行し、Chilled String警告を収集',
            'Warning.warnをオーバーライドして警告をログに記録'
          ]
        },
        step2: {
          title: '段階的にプラグマを追加',
          actions: [
            'RuboCop の Style/FrozenStringLiteralComment を有効化',
            'CI/CDパイプラインで新規ファイルへのプラグマ追加を強制',
            '既存ファイルはモジュール/ディレクトリ単位で段階的に移行'
          ]
        },
        step3: {
          title: '破壊的操作の修正',
          actions: [
            'FrozenError が発生する箇所を特定',
            "String.new または +'' パターンに置き換え",
            'テストカバレッジを確認しながら修正'
          ]
        },
        step4: {
          title: 'CI/CDでの検証',
          actions: [
            "RUBYOPT='--enable-frozen-string-literal' でテスト実行",
            '段階的に環境変数を有効化して全体への影響を確認',
            'Chilled String警告をエラーとして扱う設定を検討'
          ]
        }
      }
    end

    # RuboCopの設定例
    def self.rubocop_config_example
      <<~YAML
        # .rubocop.yml
        Style/FrozenStringLiteralComment:
          Enabled: true
          EnforcedStyle: always
          SafeAutoCorrect: true

        # 自動修正: rubocop -a --only Style/FrozenStringLiteralComment
      YAML
    end

    # Warning.warn をオーバーライドしてChilled String警告を捕捉する例
    def self.warning_capture_example
      <<~RUBY
        # config/initializers/chilled_string_warnings.rb（Rails用）
        if RUBY_VERSION >= "3.4"
          original_warn = Warning.method(:warn)

          Warning.define_method(:warn) do |message, **kwargs|
            if message.include?("literal string will be frozen")
              # 警告をログに記録して発生箇所を特定
              Rails.logger.warn("[ChilledString] \#{message.chomp} at \#{caller(1, 1)&.first}")
            end
            original_warn.call(message, **kwargs)
          end
        end
      RUBY
    end

    # 移行時の注意点
    def self.common_pitfalls
      {
        'テンプレートエンジン' => 'ERB/Haml/Slimテンプレートは通常プラグマの影響を受けない',
        'ジェムの互換性' => '古いジェムがミュータブル文字列を前提としている場合がある',
        'メタプログラミング' => 'eval系メソッドで生成されるコードは個別対応が必要',
        'IO操作' => 'File.readの返値はフリーズされない（リテラルではないため）',
        '環境変数' => "ENV['KEY']の返値はフリーズされない",
        '正規表現マッチ' => '$~, $1等のグローバル変数はフリーズされない'
      }
    end
  end
end
