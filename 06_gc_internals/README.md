# 06: Ruby GC内部構造

## 概要

RubyのGC（ガベージコレクション）は、プログラマが明示的にメモリを解放しなくても、不要になったオブジェクトを自動的に回収する仕組みです。シニアRailsエンジニアとして、GCの内部構造を理解することは、本番環境でのパフォーマンス問題やメモリリークの調査において不可欠です。

## GC世代別管理の仕組み

### 世代別GC（Generational GC）

Ruby 2.1以降、世代別GCが導入されました。オブジェクトを「世代」で分類し、効率的にメモリを回収します。

```text

新世代（Young Generation）          旧世代（Old Generation）
┌─────────────────────┐          ┌─────────────────────┐
│ 新しく生成された      │  昇格     │ マイナーGCを生き残った │
│ オブジェクト          │ -------> │ 長寿命オブジェクト     │
│                     │          │                     │
│ マイナーGCで回収対象   │          │ メジャーGCでのみ       │
│                     │          │ 回収対象              │
└─────────────────────┘          └─────────────────────┘

```

- マイナーGCは新世代のオブジェクトのみスキャンします。高速で頻繁に実行されます
- メジャーGCは全オブジェクトをスキャンします。低速ですが完全な回収を行います
- 昇格（Promotion）はマイナーGCを生き残ったオブジェクトを旧世代に移動する処理です

### 世代別にする理由

多くのオブジェクトは短命です（「弱い世代仮説」）。一時変数、中間文字列、ブロックの戻り値などは生成後すぐに不要になります。これらを新世代としてマイナーGCで素早く回収することで、GCの停止時間を短縮できます。

## GC.statの読み方

`GC.stat`はGCの統計情報をハッシュで返します。本番環境の問題調査に不可欠なツールです。

### 主要な統計項目

```ruby

stat = GC.stat

# ヒープの状態

stat[:heap_live_slots]         # 生存オブジェクト数（現在使用中のスロット）
stat[:heap_free_slots]         # 空きスロット数
stat[:heap_allocated_pages]    # 割り当て済みヒープページ数

# オブジェクト割り当て統計（プロセス起動からの累積）

stat[:total_allocated_objects] # 割り当てられた全オブジェクト数
stat[:total_freed_objects]     # 解放された全オブジェクト数

# GC実行回数

stat[:minor_gc_count]          # マイナーGC実行回数
stat[:major_gc_count]          # メジャーGC実行回数
stat[:count]                   # GC合計実行回数

# 旧世代の状態

stat[:old_objects]             # 旧世代に昇格したオブジェクト数

```

### 診断のポイント

| 指標 | 正常 | 要注意
| ------ | ------ | --------
| `heap_live_slots` | リクエスト間で安定 | 単調増加 → メモリリークの疑い
| `minor_gc_count` / `major_gc_count` | minor >> major | majorが頻発 → チューニングが必要です
| `total_allocated_objects`の増加率 | 安定 | 急増 → 過剰なオブジェクト生成
| `old_objects` | 緩やかに安定 | 急増 → 長寿命オブジェクトの蓄積

## 本番環境でのGCチューニング方法

### 環境変数によるチューニング

Railsアプリケーションの推奨設定例を以下に示します。

```bash

# 初期ヒープスロット数（起動時のGC回数を削減）

export RUBY_GC_HEAP_INIT_SLOTS=600000

# ヒープ拡張時の成長率（メモリ増加を抑制）

export RUBY_GC_HEAP_GROWTH_FACTOR=1.25

# malloc割り当てのGCトリガー閾値（128MB）

export RUBY_GC_MALLOC_LIMIT=128000000

# malloc割り当ての上限値（256MB）

export RUBY_GC_MALLOC_LIMIT_MAX=256000000

# 旧世代のmalloc閾値

export RUBY_GC_OLDMALLOC_LIMIT=128000000

# 旧世代オブジェクト数に基づくメジャーGCトリガー係数

export RUBY_GC_HEAP_OLDOBJECT_LIMIT_FACTOR=1.3

```

### チューニングの方針

1.
   RUBY_GC_HEAP_INIT_SLOTSを大きくします。Railsアプリは起動時に多くのオブジェクトを生成するため、初期ヒープを大きくすると起動時のGC回数を削減できます
2. RUBY_GC_HEAP_GROWTH_FACTORを小さくします。メモリ制約のある環境では1.1〜1.25に設定し、メモリの急激な増加を防ぎます
3.
   RUBY_GC_MALLOC_LIMITを適切に設定します。大きすぎるとGCが遅延してメモリ使用量が増加し、小さすぎるとGCが頻発してスループットが低下します

### GC.compactの活用

```ruby

# PumaのbeforeForkで実行する例

# CoW（Copy-on-Write）の効率を高める

before_fork do
  GC.compact
end

```

## メモリリーク調査手法

### 手順1: GC.statの定期監視

```ruby

# Railsのミドルウェアで各リクエスト後にGC統計を記録

class GcStatsMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    status, headers, body = @app.call(env)
    stat = GC.stat
    Rails.logger.info(
      "GC Stats: live=#{stat[:heap_live_slots]} " \
      "allocated=#{stat[:total_allocated_objects]} " \
      "minor=#{stat[:minor_gc_count]} major=#{stat[:major_gc_count]}"
    )
    [status, headers, body]
  end
end

```

### 手順2: ObjectSpaceによる調査

```ruby

# オブジェクトの種類ごとのカウント

counts = ObjectSpace.count_objects

# => { TOTAL: 123456, FREE: 7890, T_OBJECT: 1234, T_STRING: 5678, ... }

# 特定クラスのインスタンス数をカウント

ObjectSpace.each_object(String).count
ObjectSpace.each_object(Hash).count

```

### 手順3: allocation_tracer gemの利用

```ruby

require 'allocation_tracer'

# どのファイルのどの行でオブジェクトが生成されているかを追跡

result = ObjectSpace::AllocationTracer.trace do
  # 調査対象のコード
  100.times { User.find(1) }
end

```

### 手順4: memory_profiler gemの利用

```ruby

require 'memory_profiler'

report = MemoryProfiler.report do
  # 調査対象のコード
  100.times { User.all.to_a }
end

report.pretty_print

```

### よくあるメモリリークの原因

1. グローバル変数やクラス変数への蓄積: `@@cache`にデータを追加し続けるパターンです
2. クロージャによる参照保持: Procやlambdaが不要なオブジェクトを参照し続けます
3. イベントリスナーの未解除: コールバックを登録して解除しないパターンです
4. 文字列のSymbol変換: ユーザー入力を`to_sym`すると、Symbolが際限なく増加します（Ruby 2.2未満）
5. ActiveRecordのプリロード蓄積: `includes`のチェーンが巨大なオブジェクトグラフを保持します

## 実行方法

```bash

# テストの実行

bundle exec rspec 06_gc_internals/gc_internals_spec.rb

# 個別メソッドの動作確認

ruby -r ./06_gc_internals/gc_internals -e "pp GcInternals.read_gc_stats"
ruby -r ./06_gc_internals/gc_internals -e "pp GcInternals.track_object_allocations"

```

## 参考リンク

- [Ruby GC Tuning (Official)](https://docs.ruby-lang.org/en/master/GC.html)
- [Generational GC in Ruby 2.1](https://blog.heroku.com/incremental-gc)
- [Tuning Ruby's GC for
  Unicorn](https://www.speedshop.co/2017/12/04/malloc-doubles-ruby-memory.html)
- [Understanding Ruby
  GC.stat](https://www.joyfulbikeshedding.com/blog/2019-03-14-what-causes-ruby-memory-bloat.html)
