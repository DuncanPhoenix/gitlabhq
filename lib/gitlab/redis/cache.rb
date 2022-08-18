# frozen_string_literal: true

module Gitlab
  module Redis
    class Cache < ::Gitlab::Redis::Wrapper
      CACHE_NAMESPACE = 'cache:gitlab'

      # Full list of options:
      # https://api.rubyonrails.org/classes/ActiveSupport/Cache/RedisCacheStore.html#method-c-new
      def self.active_support_config
        {
          redis: pool,
          compress: Gitlab::Utils.to_boolean(ENV.fetch('ENABLE_REDIS_CACHE_COMPRESSION', '1')),
          namespace: CACHE_NAMESPACE,
          expires_in: ENV.fetch('GITLAB_RAILS_CACHE_DEFAULT_TTL_SECONDS', 2.weeks).to_i # Cache should not grow forever
        }
      end
    end
  end
end
