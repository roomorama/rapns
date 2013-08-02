require 'redis'

require 'rapns/daemon/store/redis_store/reconnectable'
require 'rapns/daemon/store/active_record/reconnectable'
require 'rapns/daemon/store/redis_store/redis_ar_transporter'

module Rapns
  module Daemon
    module Store
      class RedisStore
        include Rapns::Daemon::Store::RedisStore::Reconnectable
        include Rapns::Daemon::Store::ActiveRecord::Reconnectable

        PENDING_QUEUE_NAME = 'rapns:notifications:pending'
        RETRIES_QUEUE_NAME = 'rapns:notifications:retries'
        PROCESSING_QUEUE_NAME = 'rapns:notifications:processing'

        def deliverable_notifications(apps)

          redis_values = with_redis_reconnect_and_retry do | redis|

            batch_size = [redis.llen(PENDING_QUEUE_NAME), Rapns.config.batch_size].min
            redis_values = redis.lrange(PENDING_QUEUE_NAME, 0, batch_size-1)

            unless redis_values.empty?
              time_score = Time.now.utc.to_i
              redis_values_with_scores = redis_values.collect { |value| [time_score, value] }
              redis.zadd PROCESSING_QUEUE_NAME, redis_values_with_scores.flatten
              redis.ltrim PENDING_QUEUE_NAME, batch_size, redis.llen(PENDING_QUEUE_NAME)
            end

            move_retries_into_pending(redis)
            handle_stalled_notifications(redis)

            redis_values

          end

          build_notifications redis_values
        end

        def retry_after(notification, deliver_after)
          transport = Rapns::RedisArTransporter.new(notification)

          with_redis_reconnect_and_retry do |redis|
            redis.zrem PROCESSING_QUEUE_NAME, transport

            notification.retries += 1
            notification.deliver_after = deliver_after

            redis.zadd RETRIES_QUEUE_NAME, deliver_after.utc.to_i, transport
          end
        end

        def mark_delivered(notification)
          remove_notification_in_processing(notification)
        end

        def mark_failed(notification, code, description)
          remove_notification_in_processing(notification)
          with_database_reconnect_and_retry do
            #return if Rapns::Notification.exists?(notification.id)
            notification.delivered = false
            notification.delivered_at = nil
            notification.failed = true
            notification.failed_at = Time.now
            notification.error_code = code
            notification.error_description = description
            notification.save(:validate => false)
          end
        end

        def create_apns_feedback(failed_at, device_token, app)
          with_database_reconnect_and_retry do
            Rapns::Apns::Feedback.create!(:failed_at => failed_at, :device_token => device_token, :app => app)
          end
        end

        def create_gcm_notification(attrs, data, registration_ids, deliver_after, app)
          attributes_hash = { type: 'Rapns::Gcm::Notification', data: data, registration_ids: registration_ids, deliver_after: deliver_after, app_id: app.id }
          transport = Rapns::RedisArTransporter.new(attributes_hash.merge(attrs))
          with_redis_reconnect_and_retry do |redis|
            redis.rpush PENDING_QUEUE_NAME, transport
          end
          transport.to_ar
        end

        def after_daemonize
          #reconnect_database
        end

        def build_notifications(list_of_notif_hashes)
          list_of_notif_hashes.collect do |notif_hash|
            Rapns::RedisArTransporter.new(notif_hash).to_ar
          end
        end

        protected

        def remove_notification_in_processing(notification)
          with_redis_reconnect_and_retry do |redis|
            redis.zrem PROCESSING_QUEUE_NAME, Rapns::RedisArTransporter.new(notification)
          end
        end

        def move_retries_into_pending(redis)
          retries = redis.zrangebyscore(RETRIES_QUEUE_NAME, '-inf', Time.now.utc.to_i)
          unless retries.empty?
            redis.lpush(PENDING_QUEUE_NAME, retries)
            redis.zrem(RETRIES_QUEUE_NAME, retries)
          end
        end

        def handle_stalled_notifications(redis)
          feedback_poll_interval = Rapns.config.feedback_poll
          stalled_notification_tolerence = Rapns.config.stalled_notification_tolerence

          min_score = stalled_notification_tolerence.seconds.ago.utc.to_i
          max_score = feedback_poll_interval.seconds.ago.utc.to_i

          tolerated_stalled_notifications = redis.zrangebyscore(PROCESSING_QUEUE_NAME, min_score, max_score)
          unless tolerated_stalled_notifications.empty?
            redis.lpush(PENDING_QUEUE_NAME, tolerated_stalled_notifications)
            redis.zrem(PROCESSING_QUEUE_NAME, tolerated_stalled_notifications)
          end

          untolerated_stalled_notifications = redis.zrangebyscore(PROCESSING_QUEUE_NAME, '-inf', min_score)
          redis.zrem(PROCESSING_QUEUE_NAME, untolerated_stalled_notifications) unless untolerated_stalled_notifications.empty?
        end

      end
    end
  end
end
