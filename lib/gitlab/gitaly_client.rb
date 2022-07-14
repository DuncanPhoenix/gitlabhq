# frozen_string_literal: true

require 'base64'

require 'gitaly'
require 'grpc/health/v1/health_pb'
require 'grpc/health/v1/health_services_pb'

module Gitlab
  module GitalyClient
    class TooManyInvocationsError < StandardError
      attr_reader :call_site, :invocation_count, :max_call_stack

      def initialize(call_site, invocation_count, max_call_stack, most_invoked_stack)
        @call_site = call_site
        @invocation_count = invocation_count
        @max_call_stack = max_call_stack
        stacks = most_invoked_stack.join('\n') if most_invoked_stack

        msg = "GitalyClient##{call_site} called #{invocation_count} times from single request. Potential n+1?"
        msg = "#{msg}\nThe following call site called into Gitaly #{max_call_stack} times:\n#{stacks}\n" if stacks

        super(msg)
      end
    end

    SERVER_VERSION_FILE = 'GITALY_SERVER_VERSION'
    MAXIMUM_GITALY_CALLS = 30
    CLIENT_NAME = (Gitlab::Runtime.sidekiq? ? 'gitlab-sidekiq' : 'gitlab-web').freeze
    GITALY_METADATA_FILENAME = '.gitaly-metadata'

    MUTEX = Mutex.new

    def self.stub(name, storage)
      MUTEX.synchronize do
        @stubs ||= {}
        @stubs[storage] ||= {}
        @stubs[storage][name] ||= begin
          klass = stub_class(name)
          addr = stub_address(storage)
          creds = stub_creds(storage)
          klass.new(addr, creds, interceptors: interceptors, channel_args: channel_args)
        end
      end
    end

    def self.interceptors
      return [] unless Labkit::Tracing.enabled?

      [Labkit::Tracing::GRPC::ClientInterceptor.instance]
    end
    private_class_method :interceptors

    def self.channel_args
      # These values match the go Gitaly client
      # https://gitlab.com/gitlab-org/gitaly/-/blob/bf9f52bc/client/dial.go#L78
      {
        'grpc.keepalive_time_ms': 20000,
        'grpc.keepalive_permit_without_calls': 1
      }
    end
    private_class_method :channel_args

    def self.stub_creds(storage)
      if URI(address(storage)).scheme == 'tls'
        GRPC::Core::ChannelCredentials.new ::Gitlab::X509::Certificate.ca_certs_bundle
      else
        :this_channel_is_insecure
      end
    end

    def self.stub_class(name)
      if name == :health_check
        Grpc::Health::V1::Health::Stub
      else
        Gitaly.const_get(name.to_s.camelcase.to_sym, false).const_get(:Stub, false)
      end
    end

    def self.stub_address(storage)
      address(storage).sub(%r{^tcp://|^tls://}, '')
    end

    def self.clear_stubs!
      MUTEX.synchronize do
        @stubs = nil
      end
    end

    def self.random_storage
      Gitlab.config.repositories.storages.keys.sample
    end

    def self.address(storage)
      params = Gitlab.config.repositories.storages[storage]
      raise "storage not found: #{storage.inspect}" if params.nil?

      address = params['gitaly_address']
      unless address.present?
        raise "storage #{storage.inspect} is missing a gitaly_address"
      end

      unless %w(tcp unix tls).include?(URI(address).scheme)
        raise "Unsupported Gitaly address: #{address.inspect} does not use URL scheme 'tcp' or 'unix' or 'tls'"
      end

      address
    end

    def self.address_metadata(storage)
      Base64.strict_encode64(Gitlab::Json.dump(storage => connection_data(storage)))
    end

    def self.connection_data(storage)
      { 'address' => address(storage), 'token' => token(storage) }
    end

    # All Gitaly RPC call sites should use GitalyClient.call. This method
    # makes sure that per-request authentication headers are set.
    #
    # This method optionally takes a block which receives the keyword
    # arguments hash 'kwargs' that will be passed to gRPC. This allows the
    # caller to modify or augment the keyword arguments. The block must
    # return a hash.
    #
    # For example:
    #
    # GitalyClient.call(storage, service, rpc, request) do |kwargs|
    #   kwargs.merge(deadline: Time.now + 10)
    # end
    #
    # The optional remote_storage keyword argument is used to enable
    # inter-gitaly calls. Say you have an RPC that needs to pull data from
    # one repository to another. For example, to fetch a branch from a
    # (non-deduplicated) fork into the fork parent. In that case you would
    # send an RPC call to the Gitaly server hosting the fork parent, and in
    # the request, you would tell that Gitaly server to pull Git data from
    # the fork. How does that Gitaly server connect to the Gitaly server the
    # forked repo lives on? This is the problem `remote_storage:` solves: it
    # adds address and authentication information to the call, as gRPC
    # metadata (under the `gitaly-servers` header). The request would say
    # "pull from repo X on gitaly-2". In the Ruby code you pass
    # `remote_storage: 'gitaly-2'`. And then the metadata would say
    # "gitaly-2 is at network address tcp://10.0.1.2:8075".
    #
    def self.call(storage, service, rpc, request, remote_storage: nil, timeout: default_timeout, &block)
      Gitlab::GitalyClient::Call.new(storage, service, rpc, request, remote_storage, timeout).call(&block)
    end

    def self.execute(storage, service, rpc, request, remote_storage:, timeout:)
      enforce_gitaly_request_limits(:call)
      Gitlab::RequestContext.instance.ensure_deadline_not_exceeded!

      kwargs = request_kwargs(storage, timeout: timeout.to_f, remote_storage: remote_storage)
      kwargs = yield(kwargs) if block_given?

      stub(service, storage).__send__(rpc, request, kwargs) # rubocop:disable GitlabSecurity/PublicSend
    end

    def self.query_time
      query_time = Gitlab::SafeRequestStore[:gitaly_query_time] || 0
      query_time.round(Gitlab::InstrumentationHelper::DURATION_PRECISION)
    end

    def self.add_query_time(duration)
      return unless Gitlab::SafeRequestStore.active?

      Gitlab::SafeRequestStore[:gitaly_query_time] ||= 0
      Gitlab::SafeRequestStore[:gitaly_query_time] += duration
    end

    # For some time related tasks we can't rely on `Time.now` since it will be
    # affected by Timecop in some tests, and the clock of some gitaly-related
    # components (grpc's c-core and gitaly server) use system time instead of
    # timecop's time, so tests will fail.
    # `Time.at(Process.clock_gettime(Process::CLOCK_REALTIME))` will circumvent
    # timecop.
    def self.real_time
      Time.at(Process.clock_gettime(Process::CLOCK_REALTIME))
    end
    private_class_method :real_time

    def self.authorization_token(storage)
      token = token(storage).to_s
      issued_at = real_time.to_i.to_s
      hmac = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('SHA256'), token, issued_at)

      "v2.#{hmac}.#{issued_at}"
    end
    private_class_method :authorization_token

    def self.request_kwargs(storage, timeout:, remote_storage: nil)
      metadata = {
        'authorization' => "Bearer #{authorization_token(storage)}",
        'client_name' => CLIENT_NAME
      }

      context_data = Gitlab::ApplicationContext.current

      feature_stack = Thread.current[:gitaly_feature_stack]
      feature = feature_stack && feature_stack[0]
      metadata['call_site'] = feature.to_s if feature
      metadata['gitaly-servers'] = address_metadata(remote_storage) if remote_storage
      metadata['x-gitlab-correlation-id'] = Labkit::Correlation::CorrelationId.current_id if Labkit::Correlation::CorrelationId.current_id
      metadata['gitaly-session-id'] = session_id
      metadata['username'] = context_data['meta.user'] if context_data&.fetch('meta.user', nil)
      metadata['remote_ip'] = context_data['meta.remote_ip'] if context_data&.fetch('meta.remote_ip', nil)
      metadata.merge!(Feature::Gitaly.server_feature_flags)
      metadata.merge!(route_to_primary)

      deadline_info = request_deadline(timeout)
      metadata.merge!(deadline_info.slice(:deadline_type))

      { metadata: metadata, deadline: deadline_info[:deadline] }
    end

    # Gitlab::Git::HookEnv will set the :gitlab_git_env variable in case we're
    # running in the context of a Gitaly hook call, which may make use of
    # quarantined object directories. We thus need to pass along the path of
    # the quarantined object directory to Gitaly, otherwise it won't be able to
    # find these quarantined objects. Given that the quarantine directory is
    # generated with a random name, they'll have different names when multiple
    # Gitaly nodes take part in a single transaction. As a result, we are
    # forced to route all requests to the primary node which has injected the
    # quarantine object directory to us.
    def self.route_to_primary
      return {} unless Gitlab::SafeRequestStore.active?

      return {} if Gitlab::SafeRequestStore[:gitlab_git_env].blank?

      { 'gitaly-route-repository-accessor-policy' => 'primary-only' }
    end
    private_class_method :route_to_primary

    def self.request_deadline(timeout)
      # timeout being 0 means the request is allowed to run indefinitely.
      # We can't allow that inside a request, but this won't count towards Gitaly
      # error budgets
      regular_deadline = real_time.to_i + timeout if timeout > 0

      return { deadline: regular_deadline } if Sidekiq.server?
      return { deadline: regular_deadline } unless Gitlab::RequestContext.instance.request_deadline

      limited_deadline = [regular_deadline, Gitlab::RequestContext.instance.request_deadline].compact.min
      limited = limited_deadline < regular_deadline

      { deadline: limited_deadline, deadline_type: limited ? "limited" : "regular" }
    end
    private_class_method :request_deadline

    def self.session_id
      Gitlab::SafeRequestStore[:gitaly_session_id] ||= SecureRandom.uuid
    end

    def self.token(storage)
      params = Gitlab.config.repositories.storages[storage]
      raise "storage not found: #{storage.inspect}" if params.nil?

      params['gitaly_token'].presence || Gitlab.config.gitaly['token']
    end

    # Ensures that Gitaly is not being abuse through n+1 misuse etc
    def self.enforce_gitaly_request_limits(call_site)
      # Only count limits in request-response environments
      return unless Gitlab::SafeRequestStore.active?

      # This is this actual number of times this call was made. Used for information purposes only
      actual_call_count = increment_call_count("gitaly_#{call_site}_actual")

      return unless enforce_gitaly_request_limits?

      # Check if this call is nested within a allow_n_plus_1_calls
      # block and skip check if it is
      return if get_call_count(:gitaly_call_count_exception_block_depth) > 0

      # This is the count of calls outside of a `allow_n_plus_1_calls` block
      # It is used for enforcement but not statistics
      permitted_call_count = increment_call_count("gitaly_#{call_site}_permitted")

      count_stack

      return if permitted_call_count <= MAXIMUM_GITALY_CALLS

      raise TooManyInvocationsError.new(call_site, actual_call_count, max_call_count, max_stacks)
    end

    def self.enforce_gitaly_request_limits?
      return false if ENV["GITALY_DISABLE_REQUEST_LIMITS"]

      # We typically don't want to enforce request limits in production
      # However, we have some production-like test environments, i.e., ones
      # where `Rails.env.production?` returns `true`. We do want to be able to
      # check if the limit is being exceeded while testing in those environments
      # In that case we can use a feature flag to indicate that we do want to
      # enforce request limits.
      return true if Feature::Gitaly.enabled?('enforce_requests_limits')

      !Rails.env.production?
    end
    private_class_method :enforce_gitaly_request_limits?

    def self.allow_n_plus_1_calls
      return yield unless Gitlab::SafeRequestStore.active?

      begin
        increment_call_count(:gitaly_call_count_exception_block_depth)
        yield
      ensure
        decrement_call_count(:gitaly_call_count_exception_block_depth)
      end
    end

    # Normally a FindCommit RPC will cache the commit with its SHA
    # instead of a ref name, since it's possible the branch is mutated
    # afterwards. However, for read-only requests that never mutate the
    # branch, this method allows caching of the ref name directly.
    def self.allow_ref_name_caching
      return yield unless Gitlab::SafeRequestStore.active?
      return yield if ref_name_caching_allowed?

      begin
        Gitlab::SafeRequestStore[:allow_ref_name_caching] = true
        yield
      ensure
        Gitlab::SafeRequestStore[:allow_ref_name_caching] = false
      end
    end

    def self.ref_name_caching_allowed?
      Gitlab::SafeRequestStore[:allow_ref_name_caching]
    end

    def self.get_call_count(key)
      Gitlab::SafeRequestStore[key] || 0
    end
    private_class_method :get_call_count

    def self.increment_call_count(key)
      Gitlab::SafeRequestStore[key] ||= 0
      Gitlab::SafeRequestStore[key] += 1
    end
    private_class_method :increment_call_count

    def self.decrement_call_count(key)
      Gitlab::SafeRequestStore[key] -= 1
    end
    private_class_method :decrement_call_count

    # Returns the of the number of Gitaly calls made for this request
    def self.get_request_count
      get_call_count("gitaly_call_actual")
    end

    def self.reset_counts
      return unless Gitlab::SafeRequestStore.active?

      Gitlab::SafeRequestStore["gitaly_call_actual"] = 0
      Gitlab::SafeRequestStore["gitaly_call_permitted"] = 0
    end

    def self.add_call_details(details)
      Gitlab::SafeRequestStore['gitaly_call_details'] ||= []
      Gitlab::SafeRequestStore['gitaly_call_details'] << details
    end

    def self.list_call_details
      return [] unless Gitlab::PerformanceBar.enabled_for_request?

      Gitlab::SafeRequestStore['gitaly_call_details'] || []
    end

    def self.expected_server_version
      path = Rails.root.join(SERVER_VERSION_FILE)
      path.read.chomp
    end

    def self.timestamp(time)
      Google::Protobuf::Timestamp.new(seconds: time.to_i)
    end

    # The default timeout on all Gitaly calls
    def self.default_timeout
      timeout(:gitaly_timeout_default)
    end

    def self.fast_timeout
      timeout(:gitaly_timeout_fast)
    end

    def self.medium_timeout
      timeout(:gitaly_timeout_medium)
    end

    def self.long_timeout
      if Gitlab::Runtime.puma?
        default_timeout
      else
        6.hours
      end
    end

    def self.storage_metadata_file_path(storage)
      Gitlab::GitalyClient::StorageSettings.allow_disk_access do
        File.join(
          Gitlab.config.repositories.storages[storage].legacy_disk_path, GITALY_METADATA_FILENAME
        )
      end
    end

    def self.can_use_disk?(storage)
      cached_value = MUTEX.synchronize do
        @can_use_disk ||= {}
        @can_use_disk[storage]
      end

      return cached_value unless cached_value.nil?

      gitaly_filesystem_id = filesystem_id(storage)
      direct_filesystem_id = filesystem_id_from_disk(storage)

      MUTEX.synchronize do
        @can_use_disk[storage] = gitaly_filesystem_id.present? &&
          gitaly_filesystem_id == direct_filesystem_id
      end
    end

    def self.filesystem_id(storage)
      Gitlab::GitalyClient::ServerService.new(storage).storage_info&.filesystem_id
    end

    def self.filesystem_id_from_disk(storage)
      metadata_file = File.read(storage_metadata_file_path(storage))
      metadata_hash = Gitlab::Json.parse(metadata_file)
      metadata_hash['gitaly_filesystem_id']
    rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError
      nil
    end

    def self.filesystem_disk_available(storage)
      Gitlab::GitalyClient::ServerService.new(storage).storage_disk_statistics&.available
    end

    def self.filesystem_disk_used(storage)
      Gitlab::GitalyClient::ServerService.new(storage).storage_disk_statistics&.used
    end

    def self.timeout(timeout_name)
      Gitlab::CurrentSettings.current_application_settings[timeout_name]
    end
    private_class_method :timeout

    # Count a stack. Used for n+1 detection
    def self.count_stack
      return unless Gitlab::SafeRequestStore.active?

      stack_string = Gitlab::BacktraceCleaner.clean_backtrace(caller).drop(1).join("\n")

      Gitlab::SafeRequestStore[:stack_counter] ||= {}

      count = Gitlab::SafeRequestStore[:stack_counter][stack_string] || 0
      Gitlab::SafeRequestStore[:stack_counter][stack_string] = count + 1
    end
    private_class_method :count_stack

    # Returns a count for the stack which called Gitaly the most times. Used for n+1 detection
    def self.max_call_count
      return 0 unless Gitlab::SafeRequestStore.active?

      stack_counter = Gitlab::SafeRequestStore[:stack_counter]
      return 0 unless stack_counter

      stack_counter.values.max
    end
    private_class_method :max_call_count

    # Returns the stacks that calls Gitaly the most times. Used for n+1 detection
    def self.max_stacks
      return unless Gitlab::SafeRequestStore.active?

      stack_counter = Gitlab::SafeRequestStore[:stack_counter]
      return unless stack_counter

      max = max_call_count
      return if max == 0

      stack_counter.select { |_, v| v == max }.keys
    end
    private_class_method :max_stacks
  end
end
