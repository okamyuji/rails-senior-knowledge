# frozen_string_literal: true

require 'active_support'
require 'active_support/notifications'
require 'active_support/log_subscriber'
require 'securerandom'

# ActiveSupport::Notifications 計装（Instrumentation）システムの解説モジュール
#
# ActiveSupport::Notifications は Rails の Pub/Sub（出版/購読）パターンに基づく
# 計装フレームワークである。アプリケーション内部のイベントを計測・監視し、
# パフォーマンスモニタリングやロギングに活用できる。
#
# このモジュールでは、シニアエンジニアが知るべき Notifications の
# 内部動作を実例を通じて学ぶ。
module AsNotifications
  # ==========================================================================
  # 1. Subscribe / Instrument: 基本的な Pub/Sub パターン
  # ==========================================================================
  module SubscribeInstrument
    # ActiveSupport::Notifications の基本:
    # - subscribe: イベントの購読者（サブスクライバー）を登録する
    # - instrument: イベントを発行（パブリッシュ）する
    #
    # instrument のブロック内で行われた処理の所要時間が自動的に計測される。
    # subscribe のブロックには、イベント名・開始時刻・終了時刻・
    # ユニークID・ペイロードが渡される。
    def self.demonstrate_basic_subscribe_instrument
      received_events = []

      # サブスクライバーを登録（5引数形式: name, start, finish, id, payload）
      subscriber = ActiveSupport::Notifications.subscribe('custom.event') do |name, start, finish, id, payload|
        received_events << {
          name: name,
          has_start: !start.nil?,
          has_finish: !finish.nil?,
          has_id: !id.nil?,
          payload_data: payload[:data]
        }
      end

      # イベントを発行
      ActiveSupport::Notifications.instrument('custom.event', data: 'テストデータ') do
        # ここに計測対象の処理を記述する
        '処理結果'
      end

      # クリーンアップ: サブスクライバーを解除
      ActiveSupport::Notifications.unsubscribe(subscriber)

      received_events
      # => [{
      #   name: "custom.event",
      #   has_start: true,
      #   has_finish: true,
      #   has_id: true,
      #   payload_data: "テストデータ"
      # }]
    end

    # ブロックなしの instrument: ペイロードのみを通知する
    # 所要時間の計測が不要な場合に使う
    def self.demonstrate_instrument_without_block
      received = []

      subscriber = ActiveSupport::Notifications.subscribe('simple.notification') do |*args|
        event = ActiveSupport::Notifications::Event.new(*args)
        received << { name: event.name, message: event.payload[:message] }
      end

      ActiveSupport::Notifications.instrument('simple.notification', message: 'ブロックなし通知')

      ActiveSupport::Notifications.unsubscribe(subscriber)

      received
    end

    # unsubscribe の動作確認: 購読解除後はイベントが届かない
    def self.demonstrate_unsubscribe
      count = 0

      subscriber = ActiveSupport::Notifications.subscribe('unsub.test') do |*_args|
        count += 1
      end

      ActiveSupport::Notifications.instrument('unsub.test')
      count_before = count

      ActiveSupport::Notifications.unsubscribe(subscriber)
      ActiveSupport::Notifications.instrument('unsub.test')
      count_after = count

      { before_unsubscribe: count_before, after_unsubscribe: count_after }
      # => { before_unsubscribe: 1, after_unsubscribe: 1 }
    end
  end

  # ==========================================================================
  # 2. Event オブジェクト: 詳細な計測データへのアクセス
  # ==========================================================================
  module EventObject
    # ActiveSupport::Notifications::Event オブジェクトは、
    # 計装イベントの詳細情報をカプセル化する。
    #
    # 主要な属性:
    # - name:       イベント名
    # - payload:    任意のデータを格納するハッシュ
    # - time:       イベント開始時刻（Time オブジェクト）
    # - end:        イベント終了時刻（Time オブジェクト）
    # - duration:   所要時間（ミリ秒）
    # - transaction_id: イベントのユニークID
    def self.demonstrate_event_attributes
      event_data = nil

      subscriber = ActiveSupport::Notifications.subscribe('event.demo') do |*args|
        event = ActiveSupport::Notifications::Event.new(*args)
        event_data = {
          name: event.name,
          duration_is_numeric: event.duration.is_a?(Numeric),
          duration_positive: event.duration >= 0,
          has_transaction_id: !event.transaction_id.nil?,
          payload_keys: event.payload.keys.sort,
          # ActiveSupport 8.x では time/end はモノトニック時計のFloat値
          time_is_numeric: event.time.is_a?(Numeric),
          end_is_numeric: event.end.is_a?(Numeric),
          end_after_start: event.end >= event.time
        }
      end

      ActiveSupport::Notifications.instrument('event.demo', action: 'test', user_id: 42) do
        # 少し時間がかかる処理をシミュレート
        sum = 0
        1000.times { |i| sum += i }
        sum
      end

      ActiveSupport::Notifications.unsubscribe(subscriber)

      event_data
    end

    # ペイロードの動的な変更:
    # instrument ブロック内でペイロードを変更できる。
    # これにより、処理結果に基づいて追加情報を記録できる。
    def self.demonstrate_payload_mutation
      captured_payload = nil

      subscriber = ActiveSupport::Notifications.subscribe('payload.mutation') do |*args|
        event = ActiveSupport::Notifications::Event.new(*args)
        captured_payload = event.payload.dup
      end

      ActiveSupport::Notifications.instrument('payload.mutation', status: :pending) do |payload|
        # ブロック引数としてペイロードハッシュが渡される
        payload[:status] = :completed
        payload[:result_count] = 42
      end

      ActiveSupport::Notifications.unsubscribe(subscriber)

      captured_payload
      # => { status: :completed, result_count: 42 }
    end
  end

  # ==========================================================================
  # 3. モノトニック時計: 正確な時間計測の仕組み
  # ==========================================================================
  module MonotonicTime
    # Rails は内部的にモノトニック時計（Process::CLOCK_MONOTONIC）を使用して
    # 正確な所要時間を計測する。
    #
    # 壁時計（Time.now）との違い:
    # - 壁時計: NTPによる時刻補正の影響を受ける（巻き戻りの可能性あり）
    # - モノトニック時計: 常に単調増加し、システム時刻の変更に影響されない
    #
    # ActiveSupport::Notifications::Event#duration はモノトニック時計ベースで
    # 計算されるため、正確な経過時間を得られる。
    def self.demonstrate_monotonic_clock
      # モノトニック時計の基本的な使い方
      mono_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      wall_start = Time.now

      # 少量の計算処理
      sum = 0
      10_000.times { |i| sum += i }

      mono_end = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      wall_end = Time.now

      mono_elapsed = mono_end - mono_start
      wall_elapsed = wall_end - wall_start

      {
        monotonic_elapsed_positive: mono_elapsed.positive?,
        wall_elapsed_positive: wall_elapsed.positive?,
        # モノトニック時計は常に単調増加する
        monotonic_never_negative: mono_elapsed >= 0,
        # モノトニック時計はエポックからの経過時間ではないため、
        # 絶対値の比較は意味がないが、差分は正確
        both_measure_duration: mono_elapsed.positive? && wall_elapsed.positive?
      }
    end

    # Event#duration がモノトニック時計ベースであることを確認
    def self.demonstrate_event_uses_monotonic
      durations = []

      subscriber = ActiveSupport::Notifications.subscribe('mono.check') do |*args|
        event = ActiveSupport::Notifications::Event.new(*args)
        durations << event.duration
      end

      3.times do
        ActiveSupport::Notifications.instrument('mono.check') do
          sum = 0
          1000.times { |i| sum += i }
        end
      end

      ActiveSupport::Notifications.unsubscribe(subscriber)

      {
        all_non_negative: durations.all? { |d| d >= 0 },
        count: durations.size,
        all_numeric: durations.all? { |d| d.is_a?(Numeric) }
      }
    end
  end

  # ==========================================================================
  # 4. パターンマッチングサブスクリプション: 正規表現による購読
  # ==========================================================================
  module PatternMatching
    # subscribe に正規表現を渡すと、パターンに一致する
    # すべてのイベントを一括で購読できる。
    #
    # これにより、命名規則に基づいたイベントのグループ化が可能。
    # 例: /\.action_controller$/ で全コントローラーイベントを捕捉
    def self.demonstrate_regex_subscription
      matched_events = []

      # 正規表現でパターンマッチング購読
      subscriber = ActiveSupport::Notifications.subscribe(/^app\./) do |*args|
        event = ActiveSupport::Notifications::Event.new(*args)
        matched_events << event.name
      end

      # パターンに一致するイベントを発行
      ActiveSupport::Notifications.instrument('app.user.login', user: 'alice')
      ActiveSupport::Notifications.instrument('app.order.create', order_id: 1)
      ActiveSupport::Notifications.instrument('app.payment.process', amount: 100)

      # パターンに一致しないイベントは無視される
      ActiveSupport::Notifications.instrument('system.health_check')

      ActiveSupport::Notifications.unsubscribe(subscriber)

      {
        matched_count: matched_events.size,
        matched_names: matched_events.sort,
        includes_system: matched_events.include?('system.health_check')
      }
      # => {
      #   matched_count: 3,
      #   matched_names: ["app.order.create", "app.payment.process", "app.user.login"],
      #   includes_system: false
      # }
    end

    # 複数のサブスクライバーが同一イベントを購読できる
    # （ファンアウト: 1つのイベントが複数の購読者に配信される）
    def self.demonstrate_multiple_subscribers
      log_a = []
      log_b = []

      subscriber_a = ActiveSupport::Notifications.subscribe('multi.event') do |*args|
        event = ActiveSupport::Notifications::Event.new(*args)
        log_a << "A: #{event.payload[:msg]}"
      end

      subscriber_b = ActiveSupport::Notifications.subscribe('multi.event') do |*args|
        event = ActiveSupport::Notifications::Event.new(*args)
        log_b << "B: #{event.payload[:msg]}"
      end

      ActiveSupport::Notifications.instrument('multi.event', msg: 'テスト')

      ActiveSupport::Notifications.unsubscribe(subscriber_a)
      ActiveSupport::Notifications.unsubscribe(subscriber_b)

      {
        subscriber_a_received: log_a,
        subscriber_b_received: log_b,
        both_received: log_a.size == 1 && log_b.size == 1
      }
    end

    # 名前によるサブスクライバー一括解除
    # unsubscribe に文字列を渡すと、その名前の全サブスクライバーが解除される
    def self.demonstrate_unsubscribe_by_name
      counts = { a: 0, b: 0 }

      ActiveSupport::Notifications.subscribe('named.unsub') do |*_args|
        counts[:a] += 1
      end

      ActiveSupport::Notifications.subscribe('named.unsub') do |*_args|
        counts[:b] += 1
      end

      ActiveSupport::Notifications.instrument('named.unsub')
      before = counts.dup

      # 文字列指定で同名の全サブスクライバーを一括解除
      ActiveSupport::Notifications.unsubscribe('named.unsub')

      ActiveSupport::Notifications.instrument('named.unsub')
      after = counts.dup

      { before: before, after: after }
      # => { before: { a: 1, b: 1 }, after: { a: 1, b: 1 } }
    end
  end

  # ==========================================================================
  # 5. Rails 組み込みイベント: フレームワークが発行する計装イベント
  # ==========================================================================
  module BuiltInEvents
    # Rails は多くの組み込みイベントを発行する。
    # これらを購読することで、フレームワーク内部の動作を監視できる。
    #
    # 主要な組み込みイベント一覧を返す。
    # 各イベントの命名規則: "動作.コンポーネント"
    def self.list_builtin_events
      {
        action_controller: [
          'process_action.action_controller',    # コントローラーアクション実行
          'start_processing.action_controller',  # アクション処理開始
          'redirect_to.action_controller',       # リダイレクト
          'send_file.action_controller',         # ファイル送信
          'send_data.action_controller',         # データ送信
          'halted_callback.action_controller'    # コールバックで処理中断
        ],
        active_record: [
          'sql.active_record',                   # SQLクエリ実行
          'instantiation.active_record'          # ARオブジェクトのインスタンス化
        ],
        action_view: [
          'render_template.action_view',         # テンプレートレンダリング
          'render_partial.action_view',          # パーシャルレンダリング
          'render_layout.action_view',           # レイアウトレンダリング
          'render_collection.action_view'        # コレクションレンダリング
        ],
        active_support: [
          'cache_read.active_support',           # キャッシュ読み取り
          'cache_write.active_support',          # キャッシュ書き込み
          'cache_delete.active_support',         # キャッシュ削除
          'cache_exist?.active_support'          # キャッシュ存在確認
        ],
        action_mailer: [
          'deliver.action_mailer',               # メール送信
          'process.action_mailer'                # メーラーアクション処理
        ],
        active_job: [
          'enqueue.active_job',                  # ジョブのキューイング
          'perform.active_job',                  # ジョブ実行
          'enqueue_at.active_job',               # 予約ジョブのキューイング
          'discard.active_job'                   # ジョブ破棄
        ]
      }
    end

    # 組み込みイベントの命名規則を検証する
    # Rails のイベント名は "動作.コンポーネント" の形式（ドット区切り・逆順）
    def self.demonstrate_event_naming_convention
      all_events = list_builtin_events.values.flatten

      {
        # すべてのイベント名がドットを含む
        all_have_dot: all_events.all? { |e| e.include?('.') },
        # イベント名の形式: "action.namespace"
        sample_parts: all_events.first(3).map do |e|
          parts = e.split('.')
          { action: parts[0], namespace: parts[1] }
        end,
        total_count: all_events.size
      }
    end
  end

  # ==========================================================================
  # 6. カスタム計装: アプリケーション固有のイベントの追加
  # ==========================================================================
  module CustomInstrumentation
    # アプリケーション固有のイベントを計装する手法。
    # ビジネスロジックの計測やデバッグに活用できる。
    #
    # 推奨命名規則: "動作.アプリ名" または "動作.コンポーネント名"
    # 例: "search.my_app", "checkout.payment_service"
    def self.demonstrate_custom_events
      metrics = []

      subscriber = ActiveSupport::Notifications.subscribe(/^app\./) do |*args|
        event = ActiveSupport::Notifications::Event.new(*args)
        metrics << {
          name: event.name,
          duration_ms: event.duration.round(2),
          payload: event.payload
        }
      end

      # ユーザー検索の計装
      ActiveSupport::Notifications.instrument('app.user_search', query: '田中') do |payload|
        # 検索処理のシミュレーション
        results = %w[田中太郎 田中花子 田中一郎]
        payload[:result_count] = results.size
        results
      end

      # 注文処理の計装
      ActiveSupport::Notifications.instrument('app.order_process', order_id: 12_345) do |payload|
        payload[:status] = :completed
        payload[:items_count] = 3
      end

      ActiveSupport::Notifications.unsubscribe(subscriber)

      {
        metrics_count: metrics.size,
        event_names: metrics.map { |m| m[:name] },
        search_result_count: metrics.find { |m| m[:name] == 'app.user_search' }&.dig(:payload, :result_count),
        order_status: metrics.find { |m| m[:name] == 'app.order_process' }&.dig(:payload, :status)
      }
    end

    # ネストした計装: 親子関係のあるイベント
    # 外側のイベントの duration は内側のイベントの duration を含む
    def self.demonstrate_nested_instrumentation
      events = []

      subscriber = ActiveSupport::Notifications.subscribe(/^nested\./) do |*args|
        event = ActiveSupport::Notifications::Event.new(*args)
        events << { name: event.name, duration: event.duration }
      end

      ActiveSupport::Notifications.instrument('nested.outer') do
        ActiveSupport::Notifications.instrument('nested.inner') do
          sum = 0
          1000.times { |i| sum += i }
        end
      end

      ActiveSupport::Notifications.unsubscribe(subscriber)

      inner = events.find { |e| e[:name] == 'nested.inner' }
      outer = events.find { |e| e[:name] == 'nested.outer' }

      {
        event_count: events.size,
        inner_name: inner&.fetch(:name),
        outer_name: outer&.fetch(:name),
        # 外側の duration は内側を含むため、常に >= inner
        outer_includes_inner: outer && inner ? outer[:duration] >= inner[:duration] : false
      }
    end
  end

  # ==========================================================================
  # 7. ファンアウトメカニズム: 通知のディスパッチ方式
  # ==========================================================================
  module FanoutMechanism
    # ActiveSupport::Notifications は内部で Fanout オブジェクトを使い、
    # イベントを全購読者にディスパッチする。
    #
    # Fanout の動作:
    # 1. instrument が呼ばれると、該当イベントの全サブスクライバーを検索
    # 2. 各サブスクライバーに対してイベントデータを配信
    # 3. サブスクライバーはデフォルトで同期的に実行される
    #
    # 同期ディスパッチのため、サブスクライバーの処理時間が
    # instrument の呼び出し元に影響する点に注意。
    def self.demonstrate_fanout_dispatch_order
      execution_order = []

      sub1 = ActiveSupport::Notifications.subscribe('fanout.test') do |*_args|
        execution_order << :subscriber_1
      end

      sub2 = ActiveSupport::Notifications.subscribe('fanout.test') do |*_args|
        execution_order << :subscriber_2
      end

      sub3 = ActiveSupport::Notifications.subscribe('fanout.test') do |*_args|
        execution_order << :subscriber_3
      end

      ActiveSupport::Notifications.instrument('fanout.test')

      ActiveSupport::Notifications.unsubscribe(sub1)
      ActiveSupport::Notifications.unsubscribe(sub2)
      ActiveSupport::Notifications.unsubscribe(sub3)

      {
        # すべてのサブスクライバーが呼ばれた
        all_called: execution_order.size == 3,
        # 登録順に実行される
        order: execution_order
      }
    end

    # Notifier（通知システム本体）の構造を確認する
    def self.demonstrate_notifier_structure
      notifier = ActiveSupport::Notifications.notifier

      {
        notifier_class: notifier.class.name,
        responds_to_subscribe: notifier.respond_to?(:subscribe),
        responds_to_publish: notifier.respond_to?(:publish) || notifier.respond_to?(:instrument)
      }
    end
  end

  # ==========================================================================
  # 8. LogSubscriber: 構造化ロギングのための仕組み
  # ==========================================================================
  module LogSubscriberDemo
    # ActiveSupport::LogSubscriber は、計装イベントを構造化ログとして
    # 出力するための基底クラスである。
    #
    # Rails 内部では ActionController::LogSubscriber, ActiveRecord::LogSubscriber
    # などが、リクエスト処理やSQLクエリのログ出力に使われている。
    #
    # カスタム LogSubscriber を作ることで、アプリケーション固有の
    # 構造化ログを統一的に出力できる。

    # カスタム LogSubscriber の実装例
    class AppLogSubscriber < ActiveSupport::LogSubscriber
      # メソッド名がイベント名のアクション部分に対応する
      # "process.app" というイベントが発行されると、このメソッドが呼ばれる
      def process(event)
        @last_event = event
        @processed = true
      end

      # 外部からテスト用にアクセスするためのアクセサ
      attr_reader :last_event, :processed
    end

    # LogSubscriber の基本概念を示す
    def self.demonstrate_log_subscriber_concept
      {
        # LogSubscriber は ActiveSupport::Subscriber を継承
        inherits_from_subscriber: ActiveSupport::LogSubscriber < ActiveSupport::Subscriber,
        # LogSubscriber のクラス構造
        log_subscriber_class: ActiveSupport::LogSubscriber.name,
        # カスタム LogSubscriber
        custom_subscriber_class: AppLogSubscriber.name,
        custom_is_log_subscriber: AppLogSubscriber < ActiveSupport::LogSubscriber
      }
    end

    # LogSubscriber が提供するカラー出力ヘルパーを確認する
    # Rails のログ出力で色付きテキストを生成するのに使われる
    def self.demonstrate_color_helpers
      subscriber = AppLogSubscriber.new

      # LogSubscriber が提供するメソッドの確認
      {
        responds_to_color: subscriber.respond_to?(:color, true),
        has_logger_accessor: subscriber.respond_to?(:logger),
        is_log_subscriber: subscriber.is_a?(ActiveSupport::LogSubscriber)
      }
    end
  end

  # ==========================================================================
  # 9. パフォーマンスに関する考慮事項
  # ==========================================================================
  module PerformanceConsiderations
    # 計装のオーバーヘッドと最適化のポイント
    #
    # 1. サブスクライバーがない場合のオーバーヘッドは極めて小さい
    # 2. サブスクライバーの処理は同期的に実行される
    # 3. 重い処理はサブスクライバー内で非同期化を検討する
    # 4. 不要なサブスクライバーは必ず解除する

    # サブスクライバーなしの instrument のオーバーヘッドを計測する
    def self.demonstrate_overhead_without_subscribers
      # サブスクライバーなしの場合
      iterations = 1000
      event_name = "perf.no_subscribers_#{SecureRandom.hex(4)}"

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      iterations.times do
        ActiveSupport::Notifications.instrument(event_name) do
          # 空の処理
        end
      end
      no_sub_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

      {
        iterations: iterations,
        no_subscriber_total_ms: (no_sub_elapsed * 1000).round(2),
        # サブスクライバーなしの場合、1回あたりのオーバーヘッドは微小
        per_call_overhead_us: ((no_sub_elapsed / iterations) * 1_000_000).round(2),
        overhead_is_small: no_sub_elapsed < 1.0 # 1000回で1秒未満
      }
    end

    # サブスクライバーありの場合の影響を計測する
    def self.demonstrate_overhead_with_subscriber
      iterations = 1000
      event_name = "perf.with_subscriber_#{SecureRandom.hex(4)}"
      count = 0

      subscriber = ActiveSupport::Notifications.subscribe(event_name) do |*_args|
        count += 1
      end

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      iterations.times do
        ActiveSupport::Notifications.instrument(event_name) do
          # 空の処理
        end
      end
      with_sub_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

      ActiveSupport::Notifications.unsubscribe(subscriber)

      {
        iterations: iterations,
        with_subscriber_total_ms: (with_sub_elapsed * 1000).round(2),
        subscriber_called_count: count,
        all_events_delivered: count == iterations
      }
    end

    # パフォーマンスベストプラクティスの一覧
    def self.best_practices
      [
        'サブスクライバーがいなければ instrument のオーバーヘッドは極小',
        'サブスクライバー内では重い処理を避け、キューイングを検討する',
        '正規表現購読は文字列購読より若干コストが高い',
        '不要になったサブスクライバーは unsubscribe で必ず解除する',
        'テスト環境では計装を活用してイベント発行を検証できる',
        '本番環境では APM ツール（New Relic, Datadog 等）が自動購読する',
        'instrument のブロック内でペイロードを変更して結果を記録する',
        'ネストした instrument は外側の duration に含まれることに注意'
      ]
    end
  end
end
