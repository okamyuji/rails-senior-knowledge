# 10. TracePointとObjectSpaceによる本番デバッグ・プロファイリング

## 概要

TracePointとObjectSpaceは、Rubyの実行時動作を観測・分析するための低レベルAPIです。
シニアRailsエンジニアが本番環境で発生する再現困難なバグやメモリリークを調査する際に不可欠なツールです。

## 本番デバッグ手法

### TracePointによる動的トレース

TracePointはRuby VMのイベントフックを提供します。以下のイベントを監視できます。

| イベント | 説明 | 本番利用
| --------- | ------ | ---------
| `:call` | Rubyメソッド呼び出し | 限定的に可
| `:return` | Rubyメソッド復帰 | 限定的に可
| `:c_call` | C実装メソッド呼び出し | 非推奨
| `:b_call` | ブロック呼び出し | 非推奨
| `:raise` | 例外発生 | 推奨（軽量）
| `:line` | 行実行 | 絶対禁止

```ruby

# 本番で安全な例外追跡パターン

trace = TracePoint.new(:raise) do |tp|
  Rails.logger.warn(
    "Silent exception: #{tp.raised_exception.class} - #{tp.raised_exception.message} " \
    "at #{tp.path}:#{tp.lineno}"
  )
end

# ブロック形式で短時間のみ有効化（自動でdisableされる）

trace.enable { process_request(request) }

```

### rescueされた例外の検出

Railsアプリケーションでは`rescue_from`や`begin/rescue`で例外が握りつぶされることがあります。
`:raise`イベントはrescueされた例外も捕捉するため、隠れたエラーの発見に有用です。

```ruby

# 本番でサイレント例外を検出するミドルウェア例

class SilentExceptionDetector
  def initialize(app)
    @app = app
  end

  def call(env)
    silent_exceptions = []
    trace = TracePoint.new(:raise) do |tp|
      silent_exceptions << {
        class: tp.raised_exception.class.name,
        message: tp.raised_exception.message,
        location: "#{tp.path}:#{tp.lineno}"
      }
    end

    trace.enable { @app.call(env) }

    # 閾値を超えた場合にアラート
    if silent_exceptions.size > 10
      Rails.logger.warn("過剰な例外検出: #{silent_exceptions.size}件")
    end
  end
end

```

## メモリリーク検出パターン

### 基本的な検出フロー

```ruby

# ステップ1: GCを実行してベースラインを取得

GC.start
before = ObjectSpace.count_objects.dup
before_target = ObjectSpace.each_object(TargetClass).count

# ステップ2: 対象処理を実行

100.times { process_something }

# ステップ3: GCを実行して差分を取得

GC.start
after = ObjectSpace.count_objects.dup
after_target = ObjectSpace.each_object(TargetClass).count

# ステップ4: 分析

diff = after_target - before_target
puts "TargetClassインスタンス増加: #{diff}" if diff > 0

```

### アロケーション追跡による原因箇所の特定

```ruby

require "objspace"

ObjectSpace.trace_object_allocations do
  # 対象処理を実行
  result = SuspiciousService.new.call

  # リークが疑われるオブジェクトの割り当て元を特定
  ObjectSpace.each_object(LeakingClass) do |obj|
    file = ObjectSpace.allocation_sourcefile(obj)
    line = ObjectSpace.allocation_sourceline(obj)
    method = ObjectSpace.allocation_method_id(obj)
    puts "#{file}:#{line} (#{method})" if file
  end
end

```

### Rails環境での典型的なリークパターン

1. クラス変数やグローバル変数へのキャッシュ蓄積

   - `@@cache`や`$global_hash`にデータを追加し続けるパターンです
   - 対策としてLRUキャッシュやTTL付きキャッシュを使用してください

2. クロージャによる参照保持

   - Proc/Lambdaがスコープ外のオブジェクトを参照し続けるパターンです
   - 対策としてWeakRefの使用や明示的な参照解放を行ってください

3. ActiveRecordオブジェクトの蓄積

   - `find_each`ではなく`all.each`を使った大量レコード処理が原因です
   - 対策として`find_each` / `in_batches`を使用してください

4. 文字列の凍結漏れ

   - ループ内で毎回新しい文字列を生成するパターンです
   - 対策として`frozen_string_literal: true`を徹底してください

## TracePointのパフォーマンスコスト

### イベント別コスト

TracePointのコストはイベントの種類と発火頻度に大きく依存します。

| イベント | 相対コスト | 理由
| --------- | ----------- | ------
| `:line` | 極めて高い | 全行で発火します。1メソッドで数十〜数百回です
| `:b_call` / `:b_return` | 高い | ブロックはRubyコードで非常に頻繁に使用されます
| `:call` / `:return` | 中程度 | メソッド呼び出し回数に比例します
| `:c_call` / `:c_return` | 中程度 | Cメソッドは数が多いです
| `:raise` | 低い | 通常、例外発生は低頻度です
| `:class` / `:end` | 極めて低い | クラス定義は起動時のみです

### ベンチマーク指標

一般的な目安（環境依存）は以下の通りです。

- TracePointなし: ベースライン
- `:call` / `:return`のみ: 約2〜5倍の遅延
- `:line`追加: 約10〜50倍の遅延
- `:b_call`追加: 約5〜20倍の遅延

### コスト削減のテクニック

```ruby

# 悪い例: 全イベントを常時有効化

trace = TracePoint.new(:call, :return, :line, :raise) { |tp| log(tp) }
trace.enable # 本番で常時有効 → パフォーマンス壊滅

# 良い例1: ブロック形式で短時間のみ有効化

trace = TracePoint.new(:call, :return) { |tp| log(tp) }
trace.enable { suspect_method_call }

# 良い例2: サンプリング（全リクエストの1%のみトレース）

if rand < 0.01
  trace.enable { process_request }
else
  process_request
end

# 良い例3: 条件付き有効化（エラー率が閾値を超えた場合のみ）

if error_rate > 0.05
  trace.enable { process_request }
else
  process_request
end

```

## ObjectSpaceによるプロファイリング

### count_objectsでヒープの概要を把握する方法

```ruby

# 定期的にヒープ状態を記録するバックグラウンドジョブ

class HeapProfilerJob < ApplicationJob
  def perform
    counts = ObjectSpace.count_objects
    live = counts[:TOTAL] - counts[:FREE]

    Rails.logger.info(
      "Heap: total=#{counts[:TOTAL]} live=#{live} " \
      "strings=#{counts[:T_STRING]} arrays=#{counts[:T_ARRAY]}"
    )

    # 閾値を超えた場合にアラート
    alert_if_threshold_exceeded(counts)
  end
end

```

### each_objectで特定クラスを調査する方法

```ruby

# 特定クラスのインスタンス数を監視

def monitor_instance_count(klass, threshold:)
  count = ObjectSpace.each_object(klass).count
  if count > threshold
    Rails.logger.warn("#{klass}インスタンス数が閾値超過: #{count} > #{threshold}")
  end
  count
end

```

### memsize_ofでオブジェクトのメモリ使用量を計測する方法

```ruby

require "objspace"

# 個別オブジェクトのメモリ使用量

str = "a" * 10_000
ObjectSpace.memsize_of(str) # => 10041（概算バイト数）

# 特定クラスの全インスタンスの合計メモリ使用量

total_memory = ObjectSpace.each_object(TargetClass).sum { |obj|
  ObjectSpace.memsize_of(obj)
}

```

## テストの実行

```bash

# このトピックのテストのみ実行

bundle exec rspec 10_tracepoint_objectspace/tracepoint_objectspace_spec.rb

# 全トピックのテストを実行

bundle exec rspec

```

## 参考資料

- [TracePoint
  (Ruby公式ドキュメント)](https://docs.ruby-lang.org/ja/latest/class/TracePoint.html)
- [ObjectSpace
  (Ruby公式ドキュメント)](https://docs.ruby-lang.org/ja/latest/class/ObjectSpace.html)
- [ObjectSpace::AllocationTracer](https://github.com/ko1/allocation_tracer)
- [memory_profiler gem](https://github.com/SamSaffron/memory_profiler)
