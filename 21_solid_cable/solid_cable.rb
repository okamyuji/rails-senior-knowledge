# frozen_string_literal: true

# Solid Cableの内部構造を解説するモジュール
#
# Solid CableはRails 8でAction Cableのデフォルトバックエンドとなった
# データベースベースのPub/Subアダプターである。
# 従来のRedisアダプターに代わり、SQLiteやPostgreSQLなどの
# リレーショナルデータベースをメッセージブローカーとして使用する。
#
# このモジュールでは、Solid Cableの内部動作を簡略化した
# Pub/SubシステムをインメモリSQLiteで再現し、
# シニアRailsエンジニアが知るべきアーキテクチャと仕組みを学ぶ。

require 'active_record'
require 'securerandom'

# --- インメモリSQLiteデータベースのセットアップ ---
ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:') unless ActiveRecord::Base.connected?
ActiveRecord::Base.logger = nil # テスト時のログ出力を抑制

ActiveRecord::Schema.define do
  # Solid Cableのメッセージテーブル（solid_cable_messagesに相当）
  # 実際のSolid Cableではchannel, payload, created_atが主要カラム
  create_table :cable_messages, force: true do |t|
    t.string :channel, null: false
    t.text :payload, null: false
    t.datetime :created_at, null: false
  end

  add_index :cable_messages, :channel
  add_index :cable_messages, :created_at
end

# --- メッセージモデル ---
# Solid Cableの SolidCable::Message に相当するモデル
class CableMessage < ActiveRecord::Base
  self.table_name = 'cable_messages'

  scope :for_channel, ->(channel) { where(channel: channel) }
  scope :since, ->(time) { where('created_at > ?', time) }
  scope :older_than, ->(time) { where('created_at < ?', time) }
end

module SolidCableInternals
  module_function

  # ==========================================================================
  # 1. アーキテクチャ概要: データベースベースのPub/Sub
  # ==========================================================================
  #
  # Solid Cableのアーキテクチャは以下の特徴を持つ:
  #
  # [Publisher] → INSERT INTO cable_messages → [Database]
  #                                                ↓
  # [Subscriber] ← SELECT (polling) ←─────────────┘
  #
  # - メッセージはデータベーステーブルにINSERTされる
  # - サブスクライバーはポーリングで新しいメッセージを取得する
  # - Redisのように常時接続するのではなく、定期的にSELECTクエリを発行する
  # - メッセージは一定期間後にTRIMされ、テーブルの肥大化を防ぐ
  #
  # この設計により、Redis等の外部インフラを不要にし、
  # アプリケーションの運用をシンプルにする。
  def demonstrate_architecture
    CableMessage.delete_all

    # === メッセージの発行（Publish） ===
    # Solid CableではAction Cable経由でbroadcastされたメッセージが
    # cable_messagesテーブルにINSERTされる
    published_message = CableMessage.create!(
      channel: 'chat_room_1',
      payload: '{"type":"message","body":"こんにちは"}',
      created_at: Time.now
    )

    # === メッセージの格納構造 ===
    # 各メッセージはチャンネル名、ペイロード（JSON）、作成日時を持つ
    stored = CableMessage.find(published_message.id)

    # === 複数チャンネルへの発行 ===
    CableMessage.create!(
      channel: 'notifications',
      payload: '{"type":"alert","message":"新着あり"}',
      created_at: Time.now
    )

    {
      # メッセージがデータベースに永続化される
      message_persisted: stored.persisted?,
      message_channel: stored.channel,
      message_payload: stored.payload,
      # テーブル内の全メッセージ数
      total_messages: CableMessage.count,
      # チャンネルごとのメッセージ数
      channels: CableMessage.group(:channel).count,
      # Solid Cableの本質: RDBMSがメッセージブローカーになる
      architecture: 'Database-backed Pub/Sub (INSERT → SELECT polling)'
    }
  end

  # ==========================================================================
  # 2. メッセージライフサイクル: 発行→格納→配信→削除
  # ==========================================================================
  #
  # Solid Cableのメッセージは以下のライフサイクルを辿る:
  #
  # 1. Publish: Action Cable#broadcast → SolidCable::Message.create
  # 2. Store: データベーステーブルにINSERT（一時的な保存）
  # 3. Deliver: ポーリングにより購読者がSELECTで取得
  # 4. Trim: 古いメッセージは定期的にDELETEで削除
  #
  # メッセージは「永続的なキュー」ではなく、
  # 配信のための一時的なバッファとして機能する。
  def demonstrate_message_lifecycle
    CableMessage.delete_all

    channel = 'lifecycle_demo'
    lifecycle_events = []

    # ステップ1: メッセージの発行（Publish）
    now = Time.now
    msg1 = CableMessage.create!(channel: channel, payload: '{"step":1}', created_at: now)
    lifecycle_events << "published: id=#{msg1.id}"

    # ステップ2: メッセージの格納を確認（Store）
    stored_count = CableMessage.for_channel(channel).count
    lifecycle_events << "stored: count=#{stored_count}"

    # ステップ3: サブスクライバーによる取得（Deliver）
    # サブスクライバーは最後に取得したメッセージのIDを記録し、
    # それ以降のメッセージだけを取得する
    last_seen_id = 0
    new_messages = CableMessage.for_channel(channel).where('id > ?', last_seen_id)
    delivered = new_messages.map(&:payload)
    lifecycle_events << "delivered: #{delivered.length} message(s)"

    # ステップ4: 追加のメッセージを発行
    msg2 = CableMessage.create!(channel: channel, payload: '{"step":2}', created_at: now + 1)
    lifecycle_events << "published: id=#{msg2.id}"

    # last_seen_id を更新して次のポーリングでは新しいメッセージだけ取得
    last_seen_id = msg1.id
    incremental = CableMessage.for_channel(channel).where('id > ?', last_seen_id)
    lifecycle_events << "incremental_deliver: #{incremental.count} new message(s)"

    {
      lifecycle_events: lifecycle_events,
      total_published: CableMessage.for_channel(channel).count,
      # last_seen_id による差分取得が効率的なポーリングの鍵
      incremental_delivery_works: incremental.one?,
      last_message_payload: incremental.first.payload
    }
  end

  # ==========================================================================
  # 3. ポーリングメカニズム: 設定可能なポーリング間隔
  # ==========================================================================
  #
  # Solid Cableの最大の特徴はポーリングベースの配信である。
  # Redisアダプターのようなリアルタイムプッシュ（SUBSCRIBE）とは異なり、
  # 一定間隔でデータベースをSELECTしてメッセージを取得する。
  #
  # 設定項目:
  # - polling_interval: ポーリング間隔（デフォルト: 0.1秒 = 100ms）
  # - connects_to: 専用データベースの指定
  #
  # ポーリング間隔は遅延とDB負荷のトレードオフ:
  # - 短い間隔: 低遅延だがDB負荷が高い
  # - 長い間隔: DB負荷は低いがメッセージ配信に遅延が生じる
  def demonstrate_polling_mechanism
    CableMessage.delete_all

    channel = 'polling_demo'

    # === ポーリングをシミュレーション ===
    # 実際のSolid Cableでは別スレッドで定期的にポーリングが走る
    polling_config = {
      polling_interval: 0.1, # 秒（デフォルト値）
      description: '100msごとにSELECTクエリを発行'
    }

    # サブスクライバーの状態を管理するクラス
    # 実際のSolid Cableでは SolidCable::Listener がこの役割を担う
    subscriber_state = {
      last_seen_id: 0,
      channel: channel,
      received_messages: []
    }

    # ポーリング関数（1回のポーリングサイクルをシミュレート）
    poll_once = lambda do
      messages = CableMessage.for_channel(subscriber_state[:channel])
                             .where('id > ?', subscriber_state[:last_seen_id])
                             .order(:id)
      messages.each do |msg|
        subscriber_state[:received_messages] << msg.payload
        subscriber_state[:last_seen_id] = msg.id
      end
      messages.count
    end

    # ポーリングサイクル1: まだメッセージなし
    poll1_count = poll_once.call

    # メッセージを発行
    CableMessage.create!(channel: channel, payload: '{"msg":"first"}', created_at: Time.now)
    CableMessage.create!(channel: channel, payload: '{"msg":"second"}', created_at: Time.now)

    # ポーリングサイクル2: 2件のメッセージを取得
    poll2_count = poll_once.call

    # さらにメッセージを発行
    CableMessage.create!(channel: channel, payload: '{"msg":"third"}', created_at: Time.now)

    # ポーリングサイクル3: 差分の1件だけ取得
    poll3_count = poll_once.call

    {
      polling_config: polling_config,
      poll_cycle_1: { new_messages: poll1_count },
      poll_cycle_2: { new_messages: poll2_count },
      poll_cycle_3: { new_messages: poll3_count },
      total_received: subscriber_state[:received_messages].length,
      all_received: subscriber_state[:received_messages],
      # ポーリングの効率性: IDベースの差分取得で重複なし
      no_duplicates: subscriber_state[:received_messages].uniq.length ==
        subscriber_state[:received_messages].length
    }
  end

  # ==========================================================================
  # 4. メッセージトリミング: 古いメッセージの自動削除
  # ==========================================================================
  #
  # Solid Cableはメッセージを永続的に保存しない。
  # 一定期間を過ぎたメッセージは自動的にTRIM（削除）される。
  # これにより、テーブルの肥大化を防ぎ、クエリ性能を維持する。
  #
  # 設定項目:
  # - message_retention: メッセージ保持期間（デフォルト: 1日）
  # - trim_batch_size: 一度に削除するメッセージ数
  #
  # 実際のSolid Cableでは SolidCable::TrimJob が定期的に実行される。
  def demonstrate_message_trimming
    CableMessage.delete_all

    # 古いメッセージと新しいメッセージを作成
    old_time = Time.now - (86_400 * 2) # 2日前
    recent_time = Time.now - 3600 # 1時間前
    current_time = Time.now

    # 2日前のメッセージ（trimming対象）
    CableMessage.create!(channel: 'chat', payload: '{"old":true}', created_at: old_time)
    CableMessage.create!(channel: 'chat', payload: '{"old":true}', created_at: old_time)
    CableMessage.create!(channel: 'chat', payload: '{"old":true}', created_at: old_time)

    # 1時間前のメッセージ（保持期間内）
    CableMessage.create!(channel: 'chat', payload: '{"recent":true}', created_at: recent_time)

    # 現在のメッセージ（保持期間内）
    CableMessage.create!(channel: 'chat', payload: '{"current":true}', created_at: current_time)

    before_trim = CableMessage.count

    # === トリミング処理 ===
    # message_retention のデフォルトは1日
    # それより古いメッセージを削除する
    retention_period = 86_400 # 1日（秒）
    cutoff_time = Time.now - retention_period

    # バッチ削除（trim_batch_sizeに基づくバッチ処理をシミュレート）
    trim_batch_size = 100
    trimmed_count = CableMessage.older_than(cutoff_time).limit(trim_batch_size).delete_all

    after_trim = CableMessage.count

    {
      before_trim_count: before_trim,
      trimmed_count: trimmed_count,
      after_trim_count: after_trim,
      # 保持期間内のメッセージだけが残る
      retained_messages: CableMessage.all.map(&:payload),
      retention_config: {
        message_retention: '1 day (default)',
        trim_batch_size: trim_batch_size,
        description: 'SolidCable::TrimJobが定期的に古いメッセージを削除'
      }
    }
  end

  # ==========================================================================
  # 5. チャンネルサブスクリプション: チャンネル分離とメッセージ配信
  # ==========================================================================
  #
  # Solid CableはAction Cableのチャンネルモデルに対応し、
  # サブスクライバーは特定のチャンネルのメッセージだけを受信する。
  #
  # チャンネル名はAction Cableの内部表現に基づく:
  # - "chat_room:1" のような文字列でブロードキャストされる
  # - 内部的にはSQLのWHERE channel = ? でフィルタリングされる
  #
  # 複数のサブスクライバーが同じチャンネルを購読できるが、
  # 各サブスクライバーは独立してメッセージを追跡する。
  def demonstrate_channel_subscription
    CableMessage.delete_all

    # 複数のチャンネルにメッセージを発行
    now = Time.now

    # チャットルーム1
    CableMessage.create!(channel: 'chat_room:1', payload: '{"user":"Alice","msg":"Hello"}', created_at: now)
    CableMessage.create!(channel: 'chat_room:1', payload: '{"user":"Bob","msg":"Hi!"}', created_at: now)

    # チャットルーム2
    CableMessage.create!(channel: 'chat_room:2', payload: '{"user":"Charlie","msg":"Hey"}', created_at: now)

    # 通知チャンネル
    CableMessage.create!(channel: 'notifications:user_1', payload: '{"alert":"新着メッセージ"}', created_at: now)
    CableMessage.create!(channel: 'notifications:user_2', payload: '{"alert":"新着コメント"}', created_at: now)

    # === サブスクライバーA: chat_room:1 を購読 ===
    subscriber_a_messages = CableMessage.for_channel('chat_room:1').map(&:payload)

    # === サブスクライバーB: chat_room:2 を購読 ===
    subscriber_b_messages = CableMessage.for_channel('chat_room:2').map(&:payload)

    # === サブスクライバーC: notifications:user_1 を購読 ===
    subscriber_c_messages = CableMessage.for_channel('notifications:user_1').map(&:payload)

    # === 複数サブスクライバーの独立性 ===
    # 同じチャンネルの2人のサブスクライバーがそれぞれ独立にメッセージを追跡
    sub1_last_id = 0
    sub2_last_id = 0

    # サブスクライバー1が先にポーリング
    sub1_msgs = CableMessage.for_channel('chat_room:1').where('id > ?', sub1_last_id)
    sub1_last_id = sub1_msgs.last&.id || 0

    # 新しいメッセージを追加
    CableMessage.create!(channel: 'chat_room:1', payload: '{"user":"Alice","msg":"New msg"}', created_at: now)

    # サブスクライバー2が遅れてポーリング（全メッセージを取得）
    sub2_msgs = CableMessage.for_channel('chat_room:1').where('id > ?', sub2_last_id)

    # サブスクライバー1が差分だけポーリング
    sub1_new = CableMessage.for_channel('chat_room:1').where('id > ?', sub1_last_id)

    {
      # チャンネル分離: 各サブスクライバーは自分のチャンネルのメッセージだけ受信
      subscriber_a_count: subscriber_a_messages.length,
      subscriber_b_count: subscriber_b_messages.length,
      subscriber_c_count: subscriber_c_messages.length,
      # チャンネルが正しく分離されている
      channel_isolation: subscriber_a_messages.length == 2 &&
        subscriber_b_messages.length == 1 &&
        subscriber_c_messages.length == 1,
      # 複数サブスクライバーの独立性
      sub2_sees_all: sub2_msgs.count == 3,
      sub1_sees_incremental: sub1_new.one?,
      total_channels: CableMessage.distinct.pluck(:channel).length
    }
  end

  # ==========================================================================
  # 6. Redisアダプターとの比較: トレードオフ分析
  # ==========================================================================
  #
  # Solid Cable（データベース）とRedisアダプターの主な違いを
  # 実際の動作特性に基づいて比較する。
  #
  # Solid Cableの利点:
  # - Redisサーバーの運用が不要（インフラ簡素化）
  # - 既存のデータベースを使用できる
  # - メッセージが永続化されるため、サーバー再起動時も安心
  # - SQLiteで十分な小〜中規模アプリに最適
  #
  # Redisアダプターの利点:
  # - リアルタイム性が高い（SUBSCRIBE/PUBLISHによるプッシュ）
  # - 高スループット（メモリ内操作）
  # - 大規模なWebSocket接続に対応
  #
  # 選定基準:
  # - 同時接続数が数百以下 → Solid Cable
  # - ミリ秒単位のリアルタイム性が必要 → Redis
  # - インフラをシンプルに保ちたい → Solid Cable
  # - 大規模チャットシステム → Redis
  def demonstrate_comparison_with_redis
    CableMessage.delete_all

    # === スループット特性のシミュレーション ===
    # データベースベース: INSERT → SELECT のオーバーヘッド
    channel = 'benchmark_channel'
    message_count = 50

    # メッセージの発行（INSERT）
    publish_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    message_count.times do |i|
      CableMessage.create!(
        channel: channel,
        payload: %({"index":#{i}}),
        created_at: Time.now
      )
    end
    publish_duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - publish_start

    # メッセージの取得（SELECT）
    fetch_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    fetched = CableMessage.for_channel(channel).order(:id).to_a
    fetch_duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - fetch_start

    {
      # パフォーマンス測定結果
      messages_published: message_count,
      publish_duration_ms: (publish_duration * 1000).round(2),
      fetch_duration_ms: (fetch_duration * 1000).round(2),
      all_fetched: fetched.length == message_count,
      # 比較表
      comparison: {
        solid_cable: {
          delivery_model: 'ポーリング（polling）',
          latency: 'polling_interval に依存（デフォルト 100ms）',
          throughput: '中程度（DB I/Oがボトルネック）',
          infrastructure: '追加インフラ不要',
          persistence: 'メッセージがDB に永続化される',
          best_for: '小〜中規模アプリ、シンプルな構成'
        },
        redis_adapter: {
          delivery_model: 'プッシュ（SUBSCRIBE/PUBLISH）',
          latency: '非常に低い（サブミリ秒）',
          throughput: '高い（インメモリ操作）',
          infrastructure: 'Redisサーバーが必要',
          persistence: 'メッセージは揮発性（デフォルト）',
          best_for: '大規模リアルタイムアプリ、高頻度更新'
        }
      }
    }
  end

  # ==========================================================================
  # 7. 設定: polling_interval, message_retention, connects_to
  # ==========================================================================
  #
  # Solid Cableの設定はconfig/cable.ymlまたは
  # Railsの設定ファイルで行う。
  #
  # 主要な設定項目:
  # - polling_interval: メッセージポーリング間隔（秒）
  # - message_retention: メッセージ保持期間
  # - connects_to: 専用データベース接続の指定
  # - silence_polling: ポーリングのSQLログを抑制するか
  # - autotrim: 自動トリミングを有効にするか
  #
  # 本番環境では専用のデータベースを使用し、
  # メインDBへの負荷を分離することが推奨される。
  def demonstrate_configuration
    CableMessage.delete_all

    # === 設定例 ===
    # 実際のRailsアプリケーションでの設定方法を示す

    # config/cable.yml の設定例
    cable_yml_config = {
      development: {
        adapter: 'solid_cable',
        polling_interval: '0.1.seconds',
        message_retention: '1.day'
      },
      production: {
        adapter: 'solid_cable',
        polling_interval: '0.1.seconds',
        message_retention: '1.day',
        connects_to: {
          database: { writing: 'cable', reading: 'cable' }
        },
        silence_polling: true
      }
    }

    # database.yml での専用DB設定
    database_config = {
      cable: {
        primary: {
          adapter: 'sqlite3',
          database: 'storage/cable.sqlite3'
        },
        production: {
          adapter: 'postgresql',
          database: 'myapp_cable',
          pool: 10,
          description: '本番では専用PostgreSQL推奨'
        }
      }
    }

    # === polling_interval の効果をシミュレーション ===
    # 異なるポーリング間隔での理論的な遅延
    intervals = {
      aggressive: { interval: 0.01, max_latency_ms: 10, db_queries_per_second: 100 },
      default: { interval: 0.1, max_latency_ms: 100, db_queries_per_second: 10 },
      conservative: { interval: 1.0, max_latency_ms: 1000, db_queries_per_second: 1 }
    }

    # === message_retention の効果 ===
    # 異なる保持期間でのストレージ使用量の概算
    retention_scenarios = {
      short: { retention: '6.hours', description: '高トラフィック環境向け' },
      default: { retention: '1.day', description: '標準的な設定' },
      long: { retention: '7.days', description: 'デバッグ・監査用途' }
    }

    # === connects_to による DB 分離 ===
    # Solid Cableが専用DBを使う理由:
    # 1. ポーリングクエリがメインDBに負荷をかけない
    # 2. cable_messagesテーブルの書き込みがメインDBのWALに影響しない
    # 3. バックアップ・メンテナンスを独立して行える

    {
      cable_yml: cable_yml_config,
      database_config: database_config,
      polling_intervals: intervals,
      retention_scenarios: retention_scenarios,
      # Solid Cable固有の設定項目まとめ
      configuration_keys: %w[
        polling_interval
        message_retention
        connects_to
        silence_polling
        autotrim
      ],
      # インストール方法
      setup_command: 'bin/rails solid_cable:install'
    }
  end

  # ==========================================================================
  # 8. 統合デモ: 簡易Pub/Subシステム
  # ==========================================================================
  #
  # Solid Cableの全体像を統合したデモ。
  # Publisher → Database → Subscriber のフローを
  # 複数チャンネル・複数サブスクライバーで実行する。
  def demonstrate_integrated_pubsub
    CableMessage.delete_all

    # === Publisherの定義 ===
    publish = lambda do |channel, data|
      CableMessage.create!(
        channel: channel,
        payload: data.to_json,
        created_at: Time.now
      )
    end

    # === Subscriberの定義 ===
    create_subscriber = lambda do |channel|
      state = { channel: channel, last_seen_id: 0, inbox: [] }
      poll = lambda do
        messages = CableMessage.for_channel(state[:channel])
                               .where('id > ?', state[:last_seen_id])
                               .order(:id)
        messages.each do |msg|
          state[:inbox] << JSON.parse(msg.payload)
          state[:last_seen_id] = msg.id
        end
        messages.count
      end
      { state: state, poll: poll }
    end

    # === セットアップ ===
    sub_chat = create_subscriber.call('chat:general')
    sub_alerts = create_subscriber.call('alerts:system')

    # === メッセージ発行 ===
    publish.call('chat:general', { user: 'Alice', text: 'おはよう' })
    publish.call('chat:general', { user: 'Bob', text: 'おはよう!' })
    publish.call('alerts:system', { level: 'info', text: 'デプロイ完了' })
    publish.call('chat:general', { user: 'Alice', text: '今日もよろしく' })

    # === ポーリング実行 ===
    chat_received = sub_chat[:poll].call
    alerts_received = sub_alerts[:poll].call

    # === 追加メッセージ ===
    publish.call('chat:general', { user: 'Charlie', text: '参加します' })
    publish.call('alerts:system', { level: 'warning', text: 'メモリ使用率80%' })

    # === 差分ポーリング ===
    chat_new = sub_chat[:poll].call
    alerts_new = sub_alerts[:poll].call

    # === トリミング ===
    total_before = CableMessage.count

    {
      # 初回ポーリングの結果
      chat_first_poll: chat_received,
      alerts_first_poll: alerts_received,
      # 差分ポーリングの結果
      chat_incremental: chat_new,
      alerts_incremental: alerts_new,
      # サブスクライバーの受信内容
      chat_inbox: sub_chat[:state][:inbox],
      alerts_inbox: sub_alerts[:state][:inbox],
      # チャンネル分離が正しく機能している
      chat_inbox_size: sub_chat[:state][:inbox].length,
      alerts_inbox_size: sub_alerts[:state][:inbox].length,
      total_messages_in_db: total_before
    }
  end
end
