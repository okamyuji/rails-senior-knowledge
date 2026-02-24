# RailsブートプロセスとRailtieシステム

## 概要

Railsアプリケーションの起動プロセスは、一見単純に見えますが、内部では複雑な初期化シーケンスが実行されています。このトピックでは、
シニアRailsエンジニアが知るべきブートプロセスの全体像、Railtieの仕組み、initializerの設計、および起動時間の最適化について解説します。

## ブートプロセスの理解が重要な理由

### 実務での必要性

1. gem開発では、Railtieを使ってRailsに統合するgemを開発する際にブートプロセスの理解が必須です
2. 起動時間のトラブルシューティングでは、本番環境でのデプロイ時間やコンテナ起動時間の最適化に直結します
3. initializerの設計では、アプリケーション固有の初期化処理を適切なタイミングで実行するために必要です
4. 環境別の動作理解では、developmentとproductionで異なる読み込み戦略を理解し、バグを防ぎます

## ブートシーケンスの全体像

### 起動の3ステップ

```text

config/boot.rb → config/application.rb → config/environment.rb

```

#### Step 1: config/boot.rb

```ruby

ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)
require "bundler/setup"  # Gemfile.lock に基づいてload pathを設定します
require "bootsnap/setup"  # Rails 5.2+ でデフォルト有効です

```

Bundlerが `Gemfile.lock` を読み込み、指定されたバージョンのgemを `$LOAD_PATH`
に追加します。この段階ではgemのコードはまだ実行されません。

#### Step 2: config/application.rb

```ruby

require_relative "boot"
require "rails/all"  # または個別にrequireします
Bundler.require(*Rails.groups)

module MyApp
  class Application < Rails::Application
    config.load_defaults 8.0
    config.time_zone = "Tokyo"
    # ... その他の設定
  end
end

```

`Bundler.require` が各gemの `lib/<gem_name>.rb` をrequireします。gemが `Rails::Railtie`
のサブクラスを定義していれば、`inherited` フックにより自動的にブートプロセスに登録されます。

#### Step 3: config/environment.rb

```ruby

require_relative "application"
Rails.application.initialize!

```

`initialize!`
がすべてのinitializerを依存関係順に実行します。この呼び出しが完了すると、アプリケーションはリクエストを受け付ける準備が整います。

### 起動シーケンスの詳細フロー

```text

Rails.application.initialize!
  │
  ├── run_initializers
  │     ├── load_environment_config
  │     ├── set_load_path
  │     ├── set_autoload_paths
  │     ├── initialize_logger
  │     ├── initialize_cache
  │     ├── active_record.initialize_database
  │     ├── ... (数十個のinitializer)
  │     └── eager_load! (productionのみ)
  │
  └── アプリケーション準備完了

```

## Railtie / Engine / Applicationの階層

### 継承関係

```text

Rails::Railtie
  └── Rails::Engine
        └── Rails::Application

```

| クラス | 役割 | 提供する機能
| ------- | ------ | ------------
| Railtie | 最も基本的な拡張ポイントです | initializer, config, rake_tasks, generators
| Engine | Railtieにアプリケーション的機能を追加します | routes, middleware, assets, migrations
| Application | 完全なアプリケーションです | environments, credentials, initializersディレクトリ

### Railtieの自動登録メカニズム

```ruby

# gem の lib/my_gem.rb

require "my_gem/railtie" if defined?(Rails::Railtie)

# lib/my_gem/railtie.rb

module MyGem
  class Railtie < Rails::Railtie
    # このクラスを定義するだけで自動的に登録されます
    # Rails::Railtie.inherited フックが呼ばれるためです
  end
end

```

`Rails::Railtie` のサブクラスを定義すると、`inherited`
コールバックが発火し、そのクラスが内部的なリストに追加されます。`Rails.application.initialize!`
の際に、すべてのRailtieのinitializerが収集・実行されます。

### カスタムRailtieの作成例

```ruby

class MyGemRailtie < Rails::Railtie
  # 設定用のnamespaceを追加します
  config.my_gem = ActiveSupport::OrderedOptions.new
  config.my_gem.enabled = true
  config.my_gem.api_key = nil

  # initializerの定義
  initializer "my_gem.configure" do |app|
    if app.config.my_gem.enabled
      MyGem.configure(api_key: app.config.my_gem.api_key)
    end
  end

  # Rakeタスクの登録
  rake_tasks do
    load "tasks/my_gem.rake"
  end

  # ジェネレーターの登録
  generators do
    require "generators/my_gem/install_generator"
  end

  # Railsコンソール起動時のフック
  console do
    MyGem.console_mode!
  end
end

```

## Initializerの設計

### 依存関係の制御

initializerは `:before` と `:after` オプションで実行順序を制御できます。

```ruby

class MyRailtie < Rails::Railtie
  # 他のinitializerの後に実行します
  initializer "my_railtie.setup", after: "active_record.initialize_database" do
    # ActiveRecordの初期化後に実行されます
  end

  # 他のinitializerの前に実行します
  initializer "my_railtie.early_setup", before: :load_config_initializers do
    # config/initializers/*.rbの読み込み前に実行されます
  end
end

```

### トポロジカルソートによる順序決定

Railsは内部でトポロジカルソートを使用して、すべてのinitializerの実行順序を決定します。

```text

依存関係グラフの例を以下に示します
  load_environment_config
    ├── set_load_path (after: load_environment_config)
    │     └── set_autoload_paths (after: set_load_path)
    └── initialize_logger (after: load_environment_config)
          ├── initialize_cache (after: initialize_logger)
          └── active_record.initialize_database (after: initialize_logger)

```

このグラフがトポロジカルソートされ、制約を満たす線形順序が生成されます。

### initializerの一覧確認

```ruby

# Railsに登録されているすべてのinitializerを確認します

Rails.application.initializers.each do |init|
  puts "#{init.name} (#{init.class})"
end

# 特定のinitializerの前後関係を確認します

init = Rails.application.initializers.find { |i| i.name == :load_config_initializers }
puts "before: #{init.before}"
puts "after: #{init.after}"

```

## 遅延読み込みと積極的読み込み

### Development環境（遅延読み込み）

```ruby

# config/environments/development.rb

Rails.application.configure do
  config.eager_load = false
  # Zeitwerkが定数参照時にファイルを遅延読み込みします
  # ファイル変更時に自動リロードされます
end

```

定数が初めて参照された時点で、対応するファイルが `require` されます。

メリットは以下の通りです。

- 起動が速くなります（使われるファイルだけロードします）
- ファイル変更が即時反映されます（リロード）
- 開発体験が向上します

デメリットは以下の通りです。

- 初回リクエストが遅くなります（ファイルロードが発生します）
- スレッドセーフティの問題があります（定数の遅延定義による競合）

### Production環境（積極的読み込み）

```ruby

# config/environments/production.rb

Rails.application.configure do
  config.eager_load = true
  # 起動時にすべてのファイルを一括読み込みします
end

```

`Rails.application.initialize!` の中で `eager_load!` が呼ばれ、`autoload_paths` 配下のすべての
`.rb` ファイルが `require` されます。

メリットは以下の通りです。

- リクエスト処理中のファイルI/Oを回避できます（レスポンスが速くなります）
- スレッドセーフです（すべての定数が事前に定義済みです）
- Copy-on-Writeに対応します（forkベースのサーバーでメモリを共有します）

デメリットは以下の通りです。

- 起動時間が長くなります
- メモリ使用量が多くなります

### eager_load_pathsの最適化

```ruby

# 不要なディレクトリをeager_load_pathsから除外します

config.eager_load_paths -= [Rails.root.join("app/admin")]

# eager_load_pathsの確認

Rails.application.config.eager_load_paths

```

## 起動時間の最適化

### Bootsnap（推奨）

Rails 5.2以降デフォルトで有効です。Shopifyが開発した起動高速化gemです。

```ruby

# config/boot.rb

require "bootsnap/setup"

```

最適化の仕組みは以下の通りです。

1. ISeqキャッシュ: Rubyのバイトコード（Instruction
   Sequence）をディスクにキャッシュします。再起動時にパースとコンパイルをスキップします
2. PATHキャッシュ: `$LOAD_PATH` の探索結果をキャッシュします。`require` のファイル検索を高速化します
3. YAMLキャッシュ: YAMLファイルのパース結果をキャッシュします。`config/*.yml` の読み込みを高速化します

```ruby

# Bootsnapの設定（通常はデフォルトのままで問題ありません）

Bootsnap.setup(
  cache_dir:            "tmp/cache",
  development_mode:     Rails.env.development?,
  load_path_cache:      true,
  compile_cache_iseq:   true,
  compile_cache_yaml:   true,
)

```

### Gemfileの最適化

```ruby

# 起動時に不要なgemはrequire: falseで遅延読み込みします

gem "sidekiq", require: false
gem "aws-sdk-s3", require: false
gem "prawn", require: false

# 必要な箇所で手動requireします

# app/jobs/process_job.rb

require "sidekiq"

```

### Spring（非推奨ですが知識として重要です）

Rails 7.1でデフォルトから除外されました。開発環境でアプリケーションプロセスをバックグラウンドで維持し、コマンド起動を高速化するプリローダーでした。

除外された理由は以下の通りです。

- キャッシュ不整合による不可解なバグが発生しました
- デバッグが困難でした（プロセスが古い状態を保持します）
- Bootsnapの改善によりSpringの利点が薄れました

### 起動時間の計測

```bash

# 起動時間の計測

time rails runner "puts 'OK'"

# 詳細なプロファイリング

RAILS_LOG_LEVEL=debug rails runner "puts 'OK'" 2>&1 | grep "Completed initialization"

# Bootsnapのキャッシュを削除して比較します

rm -rf tmp/cache/bootsnap
time rails runner "puts 'OK'"

```

## Bundler.requireの仕組み

### gemの読み込みフロー

```text

Bundler.require(*Rails.groups)
  │
  ├── Gemfileを解析します
  ├── 指定グループに属するgemを特定します
  └── 各gemの lib/<gem_name>.rb をrequireします
        │
        └── gem内で Rails::Railtie サブクラスが定義されている場合
              └── inheritedフックによりRailtieとして登録されます

```

### Rails.groupsの動作

```ruby

# Rails.env = "development" の場合

Rails.groups

# => [:default, "development"]

# Gemfileの対応するグループのgemがrequireされます

# group :default と group :development のgemが対象です

```

### require: falseパターン

```ruby

# Gemfile

gem "sidekiq"                  # 自動でrequireされます
gem "aws-sdk-s3", require: false  # 自動requireされません

# require: false のgemはBundler.requireでは読み込まれません

# 必要な時に手動でrequireします

```

## 実務での活用例

### カスタムinitializerの設計パターン

```ruby

# config/initializers/redis.rb

Rails.application.config.after_initialize do
  # すべてのinitializer実行後に呼ばれます
  $redis = Redis.new(url: ENV["REDIS_URL"])
end

# config/initializers/stripe.rb

# initializerファイルはconfig/initializers/配下に置くだけで自動読み込みされます

Stripe.api_key = Rails.application.credentials.stripe[:secret_key]

```

### Engineの開発

```ruby

# lib/my_engine/engine.rb

module MyEngine
  class Engine < ::Rails::Engine
    isolate_namespace MyEngine

    # Engine固有のinitializer
    initializer "my_engine.assets" do |app|
      app.config.assets.paths << root.join("app", "assets")
    end

    # Engineのマイグレーションをホストアプリに統合します
    initializer "my_engine.migrations" do |app|
      config.paths["db/migrate"].expanded.each do |path|
        app.config.paths["db/migrate"] << path
      end
    end
  end
end

```

## 実行方法

```bash

# テストの実行

bundle exec rspec 18_rails_boot_process/rails_boot_process_spec.rb

# 個別のメソッドを試します

bundle exec ruby -r ./18_rails_boot_process/rails_boot_process -e "pp RailsBootProcess.railtie_class_hierarchy"
bundle exec ruby -r ./18_rails_boot_process/rails_boot_process -e "pp RailsBootProcess.demonstrate_initializer_ordering"

```

## 関連トピック

- トピック12: Zeitwerk（自動読み込みとeager loadingの詳細）
- トピック11: Rackミドルウェア（ミドルウェアスタックの構成）
- トピック15: ActiveSupport::Notifications（initializer内でのイベント通知設定）

## 参考資料

- [Rails Guides - The Rails Initialization
  Process](https://guides.rubyonrails.org/initialization.html)
- [Rails Guides - Configuring Rails
  Applications](https://guides.rubyonrails.org/configuring.html)
- [Rails API -
  Rails::Railtie](https://api.rubyonrails.org/classes/Rails/Railtie.html)
- [Rails API -
  Rails::Engine](https://api.rubyonrails.org/classes/Rails/Engine.html)
- [Bootsnap GitHub](https://github.com/Shopify/bootsnap)
