# 04: Fiber - 軽量協調スレッドとFiber::Scheduler

## 概要

FiberはRubyにおける軽量な協調的コンテキストスイッチ機構です。OSスレッドとは異なり、ユーザー空間で管理され、
明示的な制御移動（resume/yield）によって動作します。Ruby
3.0以降、Fiber::Schedulerインターフェースの導入により、ノンブロッキングI/Oをコールバックなしで実現できるようになりました。

## FiberとThreadの比較

| 特性 | Fiber | Thread
| ------ | ------- | --------
| スケジューリング | 協調的（明示的にyield） | プリエンプティブ（OSが切り替え）
| コンテキストスイッチ | 非常に軽量（マイクロ秒単位） | 比較的重い（カーネル介入）
| メモリ消費 | 小さい（数KB〜） | 大きい（スタック1MB程度）
| 並行性 | 1スレッド内で協調的に切替 | 真の並行実行（GVLの制約あり）
| 安全性 | データ競合なし（シングルスレッド） | データ競合の可能性あり
| 用途 | I/O待機の並行化、ジェネレータ | CPU並列処理、バックグラウンド処理

## Fiberの基本

### 生成と実行

```ruby

fiber = Fiber.new do |value|
  puts "受信: #{value}"
  result = Fiber.yield("応答")
  puts "受信: #{result}"
  "最終結果"
end

fiber.resume("初期値")  # => "応答"
fiber.resume("次の値")   # => "最終結果"

```

### 状態遷移

```text

created → (resume) → running → (yield) → suspended → (resume) → running → (完了) → dead

```

- created: `Fiber.new`で生成直後の状態です。まだ実行されていません
- running: `resume`により実行中の状態です。`Fiber.current.alive?`で確認できます
- suspended: `Fiber.yield`で中断中の状態です。再度`resume`で再開できます
- dead: ブロックの実行が完了した状態です。`resume`すると`FiberError`が発生します

## Fiberによるコルーチンパターン

### Producer-Consumer

```ruby

producer = Fiber.new do
  data_source.each { |item| Fiber.yield(item) }
  nil
end

while (item = producer.resume)
  process(item)
end

```

### パイプライン

複数のFiberをチェーンして段階的なデータ変換を行うパターンです。Unixパイプに類似しています。

### Fiber#transfer

`resume`/`yield`は非対称（呼び出し側 → Fiber →
呼び出し側）ですが、`transfer`は任意のFiber間で制御を対称的に移動できます。状態機械の実装などに有用です。

## Fiber::Scheduler（Ruby 3.0+）

### 目的

従来のRubyでは、I/O操作（`sleep`、ネットワーク通信、ファイル読み書き）はスレッドをブロックしていました。
Fiber::Schedulerはこれらの操作にフックし、ブロッキング呼び出しをノンブロッキングに変換します。

### 仕組み

```text

Fiber.set_scheduler(MyScheduler.new)

# 以降、sleepやIO.readなどがMySchedulerのメソッドに委譲される

# → kernel_sleep, io_wait, io_read等がコールバックされる

# → スケジューラーはイベントループで効率的に待機を管理する

```

### 主要なインターフェースメソッド

| メソッド | 用途
| ---------- | ------
| `kernel_sleep` | `sleep`呼び出しのフック
| `io_wait` | I/O準備完了の待機
| `io_read` / `io_write` | I/O読み書きのフック
| `io_select` | `IO.select`のフック
| `address_resolve` | DNS解決のフック
| `block` / `unblock` | `Mutex`等の同期プリミティブ
| `close` | スケジューラー終了処理
| `fiber` | スケジューラー管理下でのFiber生成

### ノンブロッキングFiber

```ruby

# blocking: falseで生成されたFiberはスケジューラーの管理下に入る

Fiber.new(blocking: false) do
  sleep 1  # → scheduler.kernel_sleep(1)に委譲される
end

```

## Fiberローカルとスレッドローカルのストレージ（Ruby 3.2+）

Ruby 3.x以降、ストレージは3層構造になっています。

```ruby

# 1. Fiber[:key]: Fiberストレージ（Fiberごとに独立）

#    子Fiberは親のストレージを継承（コピー）

#    storage: {} で空のストレージから開始

Fiber[:request_id] = "abc123"

# 2. Thread.current[:key]: 実はFiberローカル（他のFiberからは見えない）

#    歴史的経緯でThread上にあるが、Ruby 3.xではFiberスコープで動作する

Thread.current[:local_data] = data

# 3. Thread#thread_variable_set: 真のスレッドローカル（Cレベル）

#    全Fiberから参照可能

Thread.current.thread_variable_set(:name, value)

```

使い分けの指針は以下の通りです。

- リクエストスコープの値（リクエストIDなど）には`Fiber[:key]`を使います
- 全Fiberで共有すべきスレッドレベルの値には`Thread#thread_variable_set/get`を使います
- レガシーコードとの互換性には`Thread.current[]`を使います（ただしFiberローカルであることに注意してください）

## EnumeratorとFiber

`Enumerator`は内部でFiberを使用して遅延評価を実現しています。`Enumerator#next`は内部的に`Fiber#resume`を呼び出し
ます。

```ruby

# この2つは本質的に同じ動作をする

enum = Enumerator.new { |y| y << 1; y << 2; y << 3 }
fiber = Fiber.new { Fiber.yield(1); Fiber.yield(2); 3 }

enum.next   # => 1    （内部でFiber#resume）
fiber.resume # => 1

```

`Lazy`エンumeratorもFiberベースであるため、無限列を効率的に扱えます。

## Railsにおける実践的な応用

### Falconサーバー

[Falcon](https://github.com/socketry/falcon)はFiber::Schedulerを活用した非同期Webサーバーです。Pumaのようなスレッドベースのサーバーとは異なり、1スレッドで数千の同時接続を処理できます。

```ruby

# Gemfile

gem "falcon"

# 起動

# $ falcon serve

```

Falconの利点は以下の通りです。

- 少ないメモリ消費で高い並行性を実現します
- データ競合のリスクがありません（シングルスレッド内で協調的に動作します）
- 既存のRailsコードがそのまま動作します（Fiber::Schedulerが透過的にフックします）

### Asyncジーム

[Async](https://github.com/socketry/async)はFiber::Schedulerの参照実装を含むライブラリです。

```ruby

require "async"

Async do |task|
  # 複数のHTTPリクエストを並行して実行
  task.async { fetch_user_data }
  task.async { fetch_order_data }
  task.async { fetch_notification_data }
end

# → 3つのリクエストが並行して実行され、合計時間は最も遅いリクエストの時間程度になる

```

### Active Recordとの組み合わせ

Fiber::Schedulerが有効な環境では、データベースクエリのI/O待機中に他のFiberが実行されます。ただし、
コネクションプールの管理に注意が必要です。

```ruby

# Fiber環境でのコネクション管理

# ActiveRecord::Base.connection_poolはFiber対応済み（Rails 7.1+）

Async do |task|
  task.async { User.find(1) }     # DB I/O中に他のFiberが実行される
  task.async { Order.find(1) }
end

```

### 使いどころの判断基準

| シナリオ | 推奨
| ---------- | ------
| I/O-boundな処理の並行化 | Fiber（Async/Falcon）
| CPU-boundな並列処理 | Ractor / プロセスフォーク
| バックグラウンドジョブ | Solid Queue / Sidekiq
| リアルタイム通信（WebSocket） | Fiber（Action Cableと併用）
| 大量の同時接続処理 | Fiber（Falcon）

## 参考資料

- [Ruby公式ドキュメント: Fiber](https://docs.ruby-lang.org/ja/latest/class/Fiber.html)
- [Ruby公式ドキュメント:
  Fiber::Scheduler](https://docs.ruby-lang.org/ja/latest/class/Fiber=3a=3aScheduler.html)
- [Async gem](https://github.com/socketry/async)
- [Falcon](https://github.com/socketry/falcon)
- [Samuel Williams - Fiber
  Scheduler](https://www.codeotaku.com/journal/2020-04/ruby-concurrency-final-report/index)
