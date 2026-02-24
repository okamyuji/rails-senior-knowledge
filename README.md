# Rails Senior Knowledge

Ruby 3.4 / Rails 8を対象としたシニアRailsエンジニア向けの教育プロジェクトです。
各トピックでは、実務で必要となる内部動作の理解や設計判断に役立つ知識を、実行可能なコードとテストを通じて学びます。

## 前提条件

- Ruby 3.4.8
- Bundler

## セットアップ

```bash

bundle install

```

## テストの実行

```bash

# 全テストの実行

bundle exec rspec *_*/*_spec.rb

# 個別トピックのテスト実行

bundle exec rspec 01_ruby_object_model/ruby_object_model_spec.rb

# Rakeタスクによる全テスト実行

bundle exec rake

```

## Linterの実行

```bash

bundle exec rubocop

```

## トピック一覧

### I. Ruby言語の内部動作

Rubyランタイムの仕組みを理解し、パフォーマンス問題の診断や最適な設計判断ができるようになります。

| # | ディレクトリ | トピック | 実務での活用場面
| --- | --- | --- | ---
| 01 | 01_ruby_object_model | Rubyオブジェクトモデル | メモリ使用量の理解、即値最適化の活用
| 02 | 02_method_lookup | メソッド探索チェーン | include/prepend選択、メソッド競合のデバッグ
| 03 | 03_block_proc_lambda | Block/Proc/Lambda | コールバック設計、DSL構築、メモリリーク防止
| 04 | 04_fiber | Fiberの内部動作 | 非同期I/O、Fiber::Scheduler、並行処理設計
| 05 | 05_ractor | Ractorによる並列実行 | CPU-bound処理の並列化、スレッドとの使い分け
| 06 | 06_gc_internals | GCの内部動作 | メモリリーク調査、GCチューニング、本番環境の最適化
| 07 | 07_yjit | YJITの最適化 | 本番でのYJIT有効化判断、パフォーマンス計測
| 08 | 08_frozen_string | Frozen StringとChilled String | Ruby 3.4移行対応、文字列メモリの最適化
| 09 | 09_refinements | Refinements | 安全なモンキーパッチ、gemでのスコープ制御
| 10 | 10_tracepoint_objectspace | TracePointとObjectSpace | 本番デバッグ、メモリプロファイリング、リーク検出

### II. Rails 8の内部アーキテクチャ

Railsの内部動作を理解し、問題発生時に根本原因を特定できるようになります。

| # | ディレクトリ | トピック | 実務での活用場面
| --- | --- | --- | ---
| 11 | 11_rack_middleware | Rackミドルウェアチェーン | カスタムミドルウェア作成、リクエスト処理の理解
| 12 | 12_zeitwerk | Zeitwerkオートローダー | autoloading問題のデバッグ、Engine/gem開発
| 13 | 13_activerecord_arel | ActiveRecordとArelの内部 | 複雑なクエリ構築、SQLインジェクション防止
| 14 | 14_connection_pool | コネクションプールの内部 | DB接続枯渇問題の診断、マルチスレッド設定
| 15 | 15_as_notifications | ActiveSupport::Notifications | カスタム計装、パフォーマンスモニタリング
| 16 | 16_routing_internals | ルーティングの内部動作 | 高度なルート設計、カスタム制約の実装
| 17 | 17_activemodel_attributes | ActiveModel属性API | カスタム型の定義、フォームオブジェクト設計
| 18 | 18_rails_boot_process | Railsブートプロセス | 起動時間の最適化、initializer設計、Railtie活用

### III. Rails 8の新機能活用

Rails 8で追加・デフォルト化された機能を活用し、依存関係を減らしシンプルなアーキテクチャを実現します。

| # | ディレクトリ | トピック | 実務での活用場面
| --- | --- | --- | ---
| 19 | 19_solid_queue | Solid Queue | Redis/Sidekiq不要のジョブキュー
| 20 | 20_solid_cache | Solid Cache | Redis/Memcached不要の大容量キャッシュ
| 21 | 21_solid_cable | Solid Cable | Redis不要のWebSocket/Action Cable
| 22 | 22_authentication | 認証ジェネレータ | Devise不要の組み込み認証実装
| 23 | 23_activerecord_encryption | ActiveRecord Encryption | 個人情報のDB暗号化
| 24 | 24_generates_token_for | generates_token_forとnormalizes | 目的別セキュアトークン、属性正規化
| 25 | 25_error_reporter | Error Reporter | エラー報告の統一API、監視サービスとの統合

### IV. データベースと性能最適化

本番環境で発生するパフォーマンス問題を予防・診断・解決できるようになります。

| # | ディレクトリ | トピック | 実務での活用場面
| --- | --- | --- | ---
| 26 | 26_n_plus_one | N+1検出とStrict Loading | クエリ最適化、strict_loadingによる防止
| 27 | 27_multi_db | マルチDB/シャーディング | 読み書き分離、水平分割、大規模DB運用
| 28 | 28_database_locking | データベースロック戦略 | 楽観的/悲観的ロック、競合状態の防止
| 29 | 29_batch_processing | バッチ処理 | 大量データ処理、メモリ効率的な一括操作
| 30 | 30_query_plan | クエリプラン分析 | EXPLAIN解読、インデックス戦略、スロークエリ対策
| 31 | 31_caching_strategies | キャッシング戦略 | Russian doll、fragment cache、HTTP caching
| 32 | 32_memory_optimization | メモリ最適化 | jemalloc、GCチューニング、本番メモリ削減

### V. 上級設計パターン

大規模Railsアプリケーションを保守可能に設計・実装するためのパターンと原則を学びます。

| # | ディレクトリ | トピック | 実務での活用場面
| --- | --- | --- | ---
| 33 | 33_service_objects | サービスオブジェクト設計 | Fat Model/Controller回避、ビジネスロジック分離
| 34 | 34_background_job_design | バックグラウンドジョブ設計 | 冪等性の確保、リトライ戦略、障害耐性
| 35 | 35_api_design | API設計パターン | バージョニング、シリアライゼーション、レート制限
| 36 | 36_concern_design | Concern設計原則 | 責務分離、適切なConcern/Module設計
| 37 | 37_error_handling | エラーハンドリング | カスタム例外階層、rescue_from、Circuit Breaker
| 38 | 38_testing_design | テスト設計 | parallel tests、fixtures vs factories、テスト高速化

## 各トピックの構成

各トピックディレクトリには以下の3ファイルが含まれています。

- `{topic_name}.rb` - 実装コード（詳細コメント付き）
- `{topic_name}_spec.rb` - RSpecテスト
- `README.md` - 日本語ドキュメント（なぜ重要か、いつ使うか、内部動作の解説）

## 技術スタック

- Ruby 3.4.8
- Rails 8.x（個別gem利用: ActiveRecord, ActiveSupport, ActiveModel, ActionPack,
  Railties）
- RSpec 3.13（テスト）
- RuboCop + rubocop-rspec（Linter/Formatter）
- SQLite3（DB依存トピック用、インメモリ）
