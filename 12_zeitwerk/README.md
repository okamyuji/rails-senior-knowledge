# Zeitwerkオートローディングの仕組み

## 概要

ZeitwerkはRails
6以降のデフォルトオートローダーです。ファイルパスと定数名の規約ベースのマッピングにより、`require`や`require_relative`を手動で書く必
要がなくなります。Ruby
2.5以降でスタンドアロンでも動作し、gem開発でも広く利用されています。

## 命名規約 (Naming Convention)

Zeitwerkの根幹はファイルパスから定数名への自動マッピングです。

### 基本ルール

| ファイルパス | 定数名
| --- | ---
| `user.rb` | `User`
| `user_profile.rb` | `UserProfile`
| `html_parser.rb` | `HtmlParser`
| `concerns/fooable.rb` | `Concerns::Fooable`
| `api/v1/users_controller.rb` | `Api::V1::UsersController`

### 変換ロジック

1. `.rb` 拡張子を除去します
2. `/`（ディレクトリ区切り）を `::` に変換します
3. 各セグメントのアンダースコアを除去し、各単語の先頭を大文字化（キャメルケース）します

```ruby

# 内部的な変換の概念を以下に示します

"services/payment/stripe_gateway.rb"
  → "services/payment/stripe_gateway"   # 拡張子除去
  → ["services", "payment", "stripe_gateway"]  # パス分割
  → ["Services", "Payment", "StripeGateway"]   # 各セグメントをキャメルケース化
  → "Services::Payment::StripeGateway"  # :: で結合

```

## Zeitwerkの動作原理

### Module#autoloadの活用

ZeitwerkはRubyの組み込み機能 `Module#autoload` を活用します。

```ruby

# Rubyのautoload機構の例を以下に示します

module MyApp
  autoload :User, "/path/to/user.rb"
end

# MyApp::User を最初に参照した瞬間に /path/to/user.rb が require されます

```

Zeitwerkのsetup処理は以下の流れで動作します。

1. `push_dir` で指定されたルートディレクトリを走査します
2. 各 `.rb` ファイルに対して、パスから定数名を導出します
3. 対応するネームスペースモジュールに `autoload` を登録します
4. 定数が参照された時にファイルが `require` されます

### 2つのローダー（Railsの場合）

| ローダー | アクセス方法 | 管理対象 | リロード
| --- | --- | --- | ---
| main | `Rails.autoloaders.main` | `app/` 以下のコード | 開発環境でリロード可能です
| once | `Rails.autoloaders.once` | `autoload_once_paths` | リロードできません

## リローディング（開発環境）

### 仕組み

1. `loader.enable_reloading` を `setup` 前に有効化します
2. ファイル変更を検知します（Railsは `ActiveSupport::FileUpdateChecker` を使用します）
3. `loader.reload` を呼びます
4. 管理下の全定数を `remove_const` で削除します
5. `autoload` を再登録します
6. 次回の定数参照時に新しいコードがロードされます

### 注意点

- グローバル変数やクラス変数に保持された古い参照は更新されません
- 定数をローカル変数にキャッシュしている場合、古いクラスオブジェクトが残ります
- `before_remove_const` コールバックは廃止されています（classic autoloaderの機能でした）

```ruby

# 悪い例: リロード後に古い参照が残ります

CACHED_CLASS = User  # この変数はreload後も古いUserを参照し続けます

# 良い例: 毎回定数を参照します

def user_class
  User  # reload後は新しいUserが返されます
end

```

## Eager Loading（本番環境）

### 本番環境でEager Loadingが必要な理由

1. スレッドセーフティを確保します。autoloadはスレッドセーフですが、eager loadingにより不要なロック競合を排除できます
2. レイテンシが安定します。リクエスト処理中にファイルI/Oが発生しません
3. Copy-on-Writeを最大化できます。Puma/Unicornのfork前にコードをロードすることで、メモリ共有の恩恵を受けられます
4. 早期エラー検出が可能です。起動時にすべてのファイルをロードし、構文エラーや定数不整合を発見できます

### Rails設定

```ruby

# config/environments/production.rb

config.eager_load = true

# config/environments/development.rb

config.eager_load = false

# config/environments/test.rb

config.eager_load = ENV['CI'].present?  # CIではtrueを推奨します

```

## カスタムInflection

### 課題

デフォルトでは `html_parser.rb` → `HtmlParser` となりますが、`HTMLParser` を期待する場合があります。

### 解決方法

```ruby

# 方法1: Zeitwerkローダーで直接設定します

loader.inflector.inflect(
  "html_parser" => "HTMLParser",
  "api_controller" => "APIController",
  "oauth_token" => "OAuthToken"
)

# 方法2: カスタムInflectorクラスを使用します

class MyInflector < Zeitwerk::Inflector
  def camelize(basename, _abspath)
    case basename
    when "html_parser" then "HTMLParser"
    when "api"         then "API"
    else super
    end
  end
end

loader.inflector = MyInflector.new

# 方法3: RailsのActiveSupport::Inflectorを使用します

ActiveSupport::Inflector.inflections do |inflect|
  inflect.acronym "HTML"
  inflect.acronym "API"
  inflect.acronym "OAuth"
end

```

## autoloading問題のデバッグ方法

### 1. ログの有効化

```ruby

# Zeitwerkのデバッグログを有効化します

Rails.autoloaders.main.log!

# 出力例:

# Zeitwerk@rails.main: autoload set for User, to be loaded from app/models/user.rb

# Zeitwerk@rails.main: constant User loaded from app/models/user.rb

```

### 2. zeitwerk:checkタスク

```bash

# 全ファイルの命名規約をチェックします

bin/rails zeitwerk:check

# 成功時: "All is good!"

# 失敗時: "expected file app/models/foo.rb to define constant Foo, but didn't"

```

### 3. よくあるエラーと解決策

| エラー | 原因 | 解決策
| --- | --- | ---
| `NameError: uninitialized constant UserAPI` | ファイル名 `user_api.rb` に対して `UserApi` が期待されます | カスタムinflection設定またはクラス名を変更します
| `expected file X to define constant Y` | ファイル内の定数名がパスと一致しません | クラス/モジュール名をパスに合わせます
| `circular dependency detected` | A → B → Aの循環参照が発生しています | コードを再構成するか、遅延参照を活用します

### 4. autoloadパスの確認

```ruby

# Railsコンソールで確認します

Rails.autoloaders.main.dirs

# => ["/app/models", "/app/controllers", ...]

ActiveSupport::Dependencies.autoload_paths

```

## Engine/Gem開発での活用

### Engine開発

Engineは自身のZeitwerkローダーを持ち、ホストアプリケーションとの定数の衝突を防ぎます。

```text

my_engine/
  app/
    models/
      my_engine/
        widget.rb          → MyEngine::Widget
    controllers/
      my_engine/
        widgets_controller.rb → MyEngine::WidgetsController

```

### Gem開発

```ruby

# lib/my_gem.rb

require "zeitwerk"

module MyGem
  class Error < StandardError; end

  class << self
    def loader
      @loader ||= Zeitwerk::Loader.for_gem
    end
  end

  loader.setup
end

```

`Zeitwerk::Loader.for_gem` は以下を自動設定します。

- `GemInflector` を使用します（gem名のファイルを特別扱いします）
- `lib/` ディレクトリを自動的に `push_dir` に追加します
- gem内部の `require_relative` を排除します

## collapseディレクティブ

ディレクトリを名前空間にマッピングしたくない場合に使います。

```ruby

# デフォルト: app/models/concerns/searchable.rb → Concerns::Searchable

# collapse後: app/models/concerns/searchable.rb → Searchable

loader.collapse("#{__dir__}/models/concerns")

```

Railsでは `concerns` ディレクトリはデフォルトでcollapseされています。

## 実行方法

```bash

# テストの実行

bundle exec rspec 12_zeitwerk/zeitwerk_spec.rb

# 特定のテストを実行します

bundle exec rspec 12_zeitwerk/zeitwerk_spec.rb -e "命名規約"

```

## 参考資料

- [Zeitwerk GitHub](https://github.com/fxn/zeitwerk)
- [Rails Guides - Autoloading and Reloading
  Constants](https://guides.rubyonrails.org/autoloading_and_reloading_constants.html)
- [Zeitwerk README
  (公式ドキュメント)](https://github.com/fxn/zeitwerk/blob/main/README.md)
