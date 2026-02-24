# 32: Rubyメモリ最適化

## 概要

Rubyプロセスのメモリ管理と最適化は、本番Railsアプリケーションの安定運用において
最も重要なスキルの一つです。メモリ使用量の増大は、レスポンスタイムの悪化、
OOMキラーによるプロセス強制終了、インフラコストの増加に直結します。

シニアRailsエンジニアとして、メモリの計測・分析・最適化の手法を体系的に
理解し、実務で活用できることが求められます。

## メモリ計測手法

### RSS（Resident Set Size）の取得

プロセスの実メモリ使用量を把握するための最も基本的な指標です。

```ruby

# psコマンド経由でRSSを取得します（KB単位）

rss_kb = `ps -o rss= -p #{Process.pid}`.strip.to_i

# Linux環境では/procから取得できます

# File.read("/proc/#{Process.pid}/status") から VmRSS 行を抽出

# GetProcessMem gem（クロスプラットフォーム対応）

# require 'get_process_mem'

# mem = GetProcessMem.new

# mem.mb  # => 123.45

```

### GC.statによるヒープ統計

```ruby

stat = GC.stat

stat[:heap_live_slots]          # 生存オブジェクト数
stat[:heap_free_slots]          # 空きスロット数
stat[:total_allocated_objects]  # 累積割り当てオブジェクト数
stat[:total_freed_objects]      # 累積解放オブジェクト数
stat[:malloc_increase_bytes]    # malloc割り当て増加量

```

### ObjectSpaceによるメモリ計測

```ruby

# オブジェクト種類別のカウント

ObjectSpace.count_objects

# => { TOTAL: 123456, FREE: 7890, T_STRING: 5678, T_ARRAY: 1234, ... }

# 個別オブジェクトのメモリサイズ

ObjectSpace.memsize_of("hello")       # => 40（バイト）
ObjectSpace.memsize_of("x" * 10000)   # => 10040（バイト）

# 全Rubyオブジェクトのメモリ使用量概算

ObjectSpace.memsize_of_all  # => バイト数

```

## オブジェクト割り当て削減

### frozen_string_literalの活用

```ruby

# frozen_string_literal: true

# 同一内容のリテラルが同一オブジェクトを共有します

a = "hello"
b = "hello"
a.equal?(b)  # => true（同一オブジェクト）

```

### SymbolとStringの比較

```ruby

# Symbolは常に同一オブジェクトです（GCされない永続的な識別子）

:my_key.equal?(:my_key)  # => true

# ハッシュキーにはSymbolを推奨します

{ name: "user", age: 25 }          # 効率的
{ "name" => "user", "age" => 25 }  # frozen_string_literal: trueでも非効率

```

### 中間オブジェクトの削減

```ruby

# 非効率: mapとselectで中間配列が2つ生成されます

result = data.map { |n| n * 2 }.select(&:even?)

# 効率的: each_with_objectで1パスで処理します

result = data.each_with_object([]) { |n, acc| acc << n * 2 if (n * 2).even? }

```

## 文字列最適化

### 文字列結合の比較

```text

+ 演算子（非効率）        << 演算子（効率的）       Array#join（効率的）

┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│ 毎回新しい中間    │    │ 既存バッファに    │    │ 配列要素を      │
│ 文字列を生成      │    │ 直接追記          │    │ 一括結合        │
│                 │    │                 │    │                 │
│ result = result │    │ buffer << str   │    │ parts.join(",") │
│   + str         │    │                 │    │                 │
│                 │    │ オブジェクト生成  │    │ 中間オブジェクト │
│ 中間オブジェクト  │    │ なし（既存変更）  │    │ 最小限          │
│ 大量生成         │    │                 │    │                 │
└─────────────────┘    └─────────────────┘    └─────────────────┘

```

```ruby

# 非効率: 100回のループで100個の中間文字列が生成されます

result = ""
100.times { |i| result = result + "item_#{i} " }

# 効率的: バッファに直接追記します（中間オブジェクト生成なし）

buffer = +""
100.times { |i| buffer << "item_#{i} " }

# 効率的: 配列に溜めて一括結合します

parts = Array.new(100) { |i| "item_#{i}" }
result = parts.join(" ")

```

## コレクション最適化（Enumerator::Lazy）

### 遅延評価パイプライン

```ruby

# Eager（通常）: 中間配列が都度生成されるため、メモリを大量消費します

result = (1..1_000_000)
  .to_a                   # 100万要素の配列を生成
  .map { |n| n * 2 }     # さらに100万要素の配列
  .select(&:even?)        # さらに配列
  .first(10)

# Lazy（遅延評価）: 要素を1つずつ逐次処理するため、メモリ効率が良くなります

result = (1..1_000_000)
  .lazy
  .map { |n| n * 2 }
  .select(&:even?)
  .first(10)              # 10個取得した時点で処理が終了します

```

### 無限シーケンスの安全な処理

```ruby

# 無限フィボナッチ数列からの偶数抽出

fib = Enumerator.new do |yielder|
  a, b = 0, 1
  loop do
    yielder.yield a
    a, b = b, a + b
  end
end

# Lazyがなければ無限ループになりますが、Lazyなら安全に5個だけ取得できます

fib.lazy.select(&:even?).first(5)

# => [0, 2, 8, 34, 144]

```

## GCチューニング環境変数

### 推奨設定（Railsアプリケーション）

```bash

# 初期ヒープスロット数（起動時のGC回数を削減します）

export RUBY_GC_HEAP_INIT_SLOTS=600000

# ヒープ拡張時の成長率（メモリ増加を抑制します）

export RUBY_GC_HEAP_GROWTH_FACTOR=1.25

# malloc割り当てのGCトリガー閾値（128MB）

export RUBY_GC_MALLOC_LIMIT=128000000

# malloc割り当ての上限値（256MB）

export RUBY_GC_MALLOC_LIMIT_MAX=256000000

# 旧世代のmalloc閾値

export RUBY_GC_OLDMALLOC_LIMIT=128000000

# 旧世代のmalloc上限値

export RUBY_GC_OLDMALLOC_LIMIT_MAX=256000000

# 旧世代オブジェクト数に基づくメジャーGCトリガー係数

export RUBY_GC_HEAP_OLDOBJECT_LIMIT_FACTOR=1.3

```

### チューニング方針

| 環境変数 | 方向 | 効果
| ---------- | ------ | ------
| `HEAP_INIT_SLOTS` | 大きく | 起動時のGC回数を削減します
| `HEAP_GROWTH_FACTOR` | 小さく | メモリ増加を抑制します
| `MALLOC_LIMIT` | 大きく | GC発動頻度が低下します（スループット向上）
| `MALLOC_LIMIT` | 小さく | メモリ使用量を抑制します（レイテンシ向上）
| `OLDOBJECT_LIMIT_FACTOR` | 小さく | 旧世代のメモリ蓄積を抑制します

## Jemallocの活用

### メモリ断片化の問題

```text

glibc malloc（デフォルト）              jemalloc
┌─────────────────────────┐         ┌─────────────────────────┐
│ ■□■□□■□■□□■□■■□ │         │ ■■■■■□□□□□□□□□□ │
│ ■□□■□□■□■□□■□□■ │         │ ■■■■□□□□□□□□□□□ │
│                         │         │                         │
│ ■ = 使用中  □ = 空き     │         │ オブジェクトがまとまって  │
│ 空きが散在 → OSに返却不可 │         │ 配置 → 空きをOSに返却可能 │
└─────────────────────────┘         └─────────────────────────┘

```

### Docker環境での導入

```dockerfile

# Dockerfile

FROM ruby:3.4

# jemallocのインストール

RUN apt-get update && apt-get install -y libjemalloc2

# jemallocをLD_PRELOADで有効化

ENV LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2

# jemallocの動作パラメータ設定

ENV MALLOC_CONF="dirty_decay_ms:1000,narenas:2,background_thread:true"

```

### Jemallocの効果

- RSSが20〜30%削減されます。長時間稼働での断片化が大幅に軽減されます
- マルチスレッド性能が向上します。スレッド単位のアリーナでロック競合を削減するため、Pumaとの相性が良くなります
- 不要になったページを定期的にOSに返却します

### 検出方法

```ruby

# jemallocが使われているか確認します

require 'rbconfig'
puts RbConfig::CONFIG['MAINLIBS']  # jemallocが含まれていれば検出できます

# MALLOC_CONFのstats_printで確認します

# MALLOC_CONF=stats_print:true ruby -e 'exit' 2>&1 | head

```

## メモリブロートの防止

### 典型的なメモリブロートパターン

#### パターン1: ActiveRecordの全件ロード

```ruby

# 悪い例: 全レコードをメモリに展開します

User.all.each { |user| send_email(user) }

# 良い例: バッチ処理で1000件ずつ処理します

User.find_each(batch_size: 1000) { |user| send_email(user) }

```

#### パターン2: 文字列結合ループ

```ruby

# 悪い例: 中間文字列が大量生成されます

csv = ""
records.each { |r| csv = csv + r.to_csv }

# 良い例: StringIOでストリーミング構築します

require 'stringio'
io = StringIO.new
records.each { |r| io << r.to_csv }
csv = io.string

```

#### パターン3: 際限ないキャッシュ成長

```ruby

# 悪い例: サイズ制限なしのキャッシュ

@@cache = {}
def fetch(key)
  @@cache[key] ||= expensive_computation(key)
end

# 良い例: LRU/TTL付きキャッシュ

# Rails.cache（ActiveSupport::Cache）を使用します

def fetch(key)
  Rails.cache.fetch(key, expires_in: 1.hour) do
    expensive_computation(key)
  end
end

```

#### パターン4: 大きなCSVエクスポート

```ruby

# 悪い例: メモリ内で全CSVを構築します

csv_string = CSV.generate do |csv|
  millions_of_records.each { |r| csv << [r.name, r.email] }
end

# 良い例: ストリーミングレスポンスを使用します

# ActionController::Liveを使用してチャンクごとに送信します

```

## メモリプロファイリングツール

### memory_profiler gem

```ruby

require 'memory_profiler'

report = MemoryProfiler.report(top: 10) do
  # プロファイリング対象のコード
  100.times { User.find(1) }
end

report.pretty_print

# => Total allocated: 1234 objects (56789 bytes)

# => Total retained:  12 objects (345 bytes)

# => allocated memory by gem

# => allocated memory by file

# => allocated objects by class

```

### GC::Profiler

```ruby

GC::Profiler.enable

# プロファイリング対象の処理

heavy_computation

GC::Profiler.report    # GC実行ごとの詳細レポートを出力します
GC::Profiler.total_time # GCに費やした合計時間を返します

GC::Profiler.disable
GC::Profiler.clear

```

### derailed_benchmarks gem

```bash

# Gemfileに追加します

# gem 'derailed_benchmarks', group: :development

# gem別のメモリ使用量を計測します

bundle exec derailed bundle:mem

# リクエスト処理時のメモリ推移を計測します

bundle exec derailed exec perf:mem

# リクエスト処理時のオブジェクト割り当てを計測します

bundle exec derailed exec perf:objects

```

## 実行方法

```bash

# テストの実行

bundle exec rspec 32_memory_optimization/memory_optimization_spec.rb

# 個別メソッドの動作確認

ruby -r ./32_memory_optimization/memory_optimization -e "pp MemoryOptimization.measure_process_memory"
ruby -r ./32_memory_optimization/memory_optimization -e "pp MemoryOptimization.optimize_strings"
ruby -r ./32_memory_optimization/memory_optimization -e "pp MemoryOptimization.optimize_collections"
ruby -r ./32_memory_optimization/memory_optimization -e "pp MemoryOptimization.gc_tuning_variables"
ruby -r ./32_memory_optimization/memory_optimization -e "pp MemoryOptimization.memory_bloat_patterns"
ruby -r ./32_memory_optimization/memory_optimization -e "pp MemoryOptimization.memory_profiling_tools"

```

## 参考リンク

- [Ruby GC Tuning (Official)](https://docs.ruby-lang.org/en/master/GC.html)
- [Jemalloc - GitHub](https://github.com/jemalloc/jemalloc)
- [How Ruby Uses
  Memory](https://www.speedshop.co/2017/12/04/malloc-doubles-ruby-memory.html)
- [memory_profiler gem](https://github.com/SamSaffron/memory_profiler)
- [derailed_benchmarks gem](https://github.com/zombocom/derailed_benchmarks)
- [Understanding Ruby
  GC.stat](https://www.joyfulbikeshedding.com/blog/2019-03-14-what-causes-ruby-memory-bloat.html)
- [ObjectSpace
  Documentation](https://docs.ruby-lang.org/en/master/ObjectSpace.html)
