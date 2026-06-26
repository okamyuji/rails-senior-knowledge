#!/usr/bin/env ruby
# frozen_string_literal: true

# MECEチェック機構: 38トピックの README/.rb/_spec.rb 横断検査
#
# これまでのレビュー指摘類型をロジックツリーに分解し、各カテゴリで
# 既知の誤りパターンを正規表現で検出する。1件でもhitしたら exit 1。
#
# カテゴリ（MECE）:
# A. バージョン誤記 - Ruby/Rails の API・機能の導入バージョン誤り
# B. 非アトミック操作 - 並行下で破綻するcheck-then-actパターン
# C. シグネチャ誤り - 引数形・キーワード引数の誤り
# D. セキュリティ抜け - LIKE escape、secure cookie、正規化漏れ
# E. 概念混同 - 鍵階層、collapse/nested root、key/key_hash、wall/monotonic、Symbol GC
# F. 内部実装の理解誤り - has_secure_password、ActiveSupport::Concern等の誤った前提
# G. 存在しないコマンド/API - rake task、メソッド名の誤り
# H. README/.rb齟齬 - 同じトピックでREADMEと.rbの記述が食い違う

ROOT = File.expand_path('..', __dir__)
TARGETS = Dir.glob(File.join(ROOT, '*_*/*.{rb,md}'))
EXCLUDE_PATHS = [
  File.join(ROOT, 'scripts'),
  File.join(ROOT, 'spec')
].freeze

@errors = []

def violation(category, file, line_no, snippet, reason)
  rel = file.sub("#{ROOT}/", '')
  @errors << "[#{category}] #{rel}:#{line_no}\n    #{snippet.strip[0, 160]}\n    → #{reason}"
end

def file_lines(file)
  @file_lines_cache ||= {}
  # 日本語の正規表現比較を非UTF-8ロケール環境でも壊さないため、エンコーディングを明示する
  @file_lines_cache[file] ||= File.readlines(file, encoding: 'UTF-8')
end

def each_target_line
  TARGETS.each do |file|
    next if EXCLUDE_PATHS.any? { |p| file.start_with?(p) }

    file_lines(file).each_with_index do |line, idx|
      yield file, idx + 1, line
    end
  end
end

# 直前N行内に特定パターンがあるか確認
def context_has?(file, line_no, lookback, regex)
  start_idx = [line_no - 1 - lookback, 0].max
  end_idx = line_no - 1
  file_lines(file)[start_idx...end_idx].any? { |l| l.match?(regex) }
end

# 直後N行内に特定パターンがあるか確認
def lookahead_has?(file, line_no, lookahead, regex)
  start_idx = line_no - 1
  end_idx = [line_no - 1 + lookahead, file_lines(file).size].min
  file_lines(file)[start_idx...end_idx].any? { |l| l.match?(regex) }
end

# ============================================================================
# 各カテゴリのチェック関数 - 1行ずつ独立に評価
# ============================================================================

def check_a_versions(file, line_no, line)
  # A1: "Rails 7.1+ で cursor:" のような誤り
  if line =~ /Rails\s*7\.1\+?\s*で?\s*(は)?\s*cursor:/ ||
     line =~ /cursor:\s*(の|を).*Rails\s*7\.1\+?/
    violation('A1', file, line_no, line, 'find_each(cursor:) は Rails 8.0+。Rails 7.1+ 表記は誤り')
  end
  # A3
  if line =~ /Rails\s*7\.1\+?\s*で?\s*ErrorReporter|ErrorReporter.*Rails\s*7\.1\+? で/
    violation('A3', file, line_no, line, 'ActiveSupport::ErrorReporter は Rails 7.0+')
  end
  # A4
  violation('A4', file, line_no, line, 'ShardSelector は Rails 6.1+') if line =~ /Rails\s*7\.1\+?\s*で?\s*ShardSelector/
  # A5
  if line =~ /load_defaults\s+8\.0/
    violation('A5', file, line_no, line, '本リポジトリは Rails 8.1 ターゲットなので load_defaults 8.1 が正')
  end
  # A6
  return unless line =~ /3\.3.*以降.*デフォルトの?JIT(コンパイラ)?(です|である)/ && !line.include?('無効')

  violation('A6', file, line_no, line, 'YJITは3.3以降でもデフォルトでは無効')
end

def check_b_atomicity(file, line_no, line)
  # B1: redis.exists? → redis.set の非アトミックパターン
  return unless line =~ /redis\.exists\?/
  return if line.include?('# 非アトミック') || line.include?('# bad')

  if lookahead_has?(file, line_no + 1, 6, /redis\.set\(/) &&
     !lookahead_has?(file, line_no + 1, 6, /nx:\s*true/)
    violation('B1', file, line_no, line, 'redis.exists? → redis.set は非アトミック。SET NX EX を使用すべき')
  end
end

def check_c_signatures(file, line_no, line)
  # C1: rate_limit by: ->(req) のような引数受け lambda
  return unless line =~ /rate_limit.*by:\s*->\s*\(\s*\w+\s*\)/

  violation('C1', file, line_no, line, 'rate_limit by: は引数なしlambda（controller context評価）が正')
end

def check_d_security(file, line_no, line)
  # D1: matches("%#{x}%") の x が sanitize_sql_like されていない
  if line =~ /matches\(["']%#\{([^}]+)\}%["']/ &&
     !Regexp.last_match(1).include?('sanitize_sql_like') &&
     !line.include?('# 危険') && !line.include?('# bad') &&
     !context_has?(file, line_no, 12, /sanitize_sql_like/)
    violation('D1', file, line_no, line, 'Arel#matches で LIKE ワイルドカードエスケープなし。sanitize_sql_like 推奨')
  end

  # D2: cookies.signed[...] = ... に secure: が無い書き込み
  if line =~ /cookies\.signed(\.permanent)?\[[^\]]+\]\s*=/ &&
     !line.strip.start_with?('→') &&
     !line.include?('# 例') && !line.include?('# bad') && !line.include?('# 削除') &&
     !lookahead_has?(file, line_no, 12, /\bsecure:/)
    violation('D2', file, line_no, line, 'cookies.signed[:...] = ... に secure: が見当たらない')
  end
end

def check_e_concepts(file, line_no, line)
  # E1
  if line =~ /プライマリキー.*\|.*DEK.*の暗号化に使用/ && !line.include?('デフォルト')
    violation('E1', file, line_no, line, 'デフォルトのDerivedSecretKeyProviderはDEKを生成しない')
  end
  # E2: Solid Cache限定
  if (line =~ /キー正規化.*SHA256|キーをSHA256でハッシュ化/) && (file.include?('solid_cache') || file.include?('20_solid_cache'))
    violation('E2', file, line_no, line, 'Solid Cache の key_hash は XXH64。SHA256表記は誤り')
  end
  # E3
  violation('E3', file, line_no, line, 'Ruby 2.2+ で動的Symbol(mortal)はGC対象') if line =~ /Symbolは常にGCされ(ない|ません)/
  # E5
  return unless line =~ /クラス\s*→\s*prepend|クラス自身\s*→\s*prepend/

  violation('E5', file, line_no, line, 'prepend はクラス本体より「前」に挿入される')
end

def check_f_internals(file, line_no, line)
  # F1: Rails.event subscriberでevent.method形式
  if line =~ /event\.(name|payload|tags|context|timestamp|source_location)/ &&
     !line.include?('# 誤') && !line.include?('# bad') &&
     context_has?(file, line_no, 20, /Rails\.event|EventReporter|def emit/)
    violation('F1', file, line_no, line, 'Rails.event subscriber は event をHashとして受け取る。event[:name]が正')
  end
  # F2
  return unless line =~ /let_it_be.*各テスト後にロールバック|let_it_be.*各.*example.*後にロールバック/

  violation('F2', file, line_no, line, 'let_it_be はグループ単位でロールバック')
end

def check_g_commands(file, line_no, line)
  # G1: db:encryption:rotate（存在しない）
  return unless line =~ /db:encryption:rotate/ && !line.match?(/存在しない|削除|誤|無い|ない/)

  violation('G1', file, line_no, line, 'rake db:encryption:rotate は存在しない')
end

def check_h_consistency(file, line_no, line)
  return unless file.include?('zeitwerk')

  # H1: zeitwerkの collapse 例で Concerns::Searchable がコード側に残存
  if line =~ /['"]Concerns::Searchable['"]/
    violation('H1', file, line_no, line, 'zeitwerk collapse例は plain Zeitwerk (Myapp::Foo) に統一済み')
  end

  # H2: loader.collapse の引数に app/models/concerns / app/controllers/concerns を渡す例
  return unless line =~ %r{loader\.collapse\(["']app/(models|controllers)/concerns}

  violation('H2', file, line_no, line,
            'loader.collapse の例にRailsのapp/{models,controllers}/concernsを使わない（ネストrootで処理されるため）')
end

# ============================================================================
# 実行: 各行に対して全カテゴリのチェックを実施
# ============================================================================

each_target_line do |file, line_no, line|
  check_a_versions(file, line_no, line)
  check_b_atomicity(file, line_no, line)
  check_c_signatures(file, line_no, line)
  check_d_security(file, line_no, line)
  check_e_concepts(file, line_no, line)
  check_f_internals(file, line_no, line)
  check_g_commands(file, line_no, line)
  check_h_consistency(file, line_no, line)
end

# ============================================================================
# 結果出力
# ============================================================================
if @errors.empty?
  puts '✓ MECEチェック完了。違反なし。'
  exit 0
else
  puts "✗ #{@errors.size} 件の違反を検出:"
  @errors.each { |e| puts "  #{e}" }
  exit 1
end
