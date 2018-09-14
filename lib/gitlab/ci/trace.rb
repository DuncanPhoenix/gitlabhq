module Gitlab
  module Ci
    class Trace
      include ExclusiveLeaseGuard

      LEASE_TIMEOUT = 1.hour

      ArchiveError = Class.new(StandardError)
      AlreadyArchivedError = Class.new(StandardError)

      attr_reader :job

      delegate :old_trace, to: :job

      def initialize(job)
        @job = job
      end

      def html(last_lines: nil)
        read do |stream|
          stream.html(last_lines: last_lines)
        end
      end

      def raw(last_lines: nil)
        read do |stream|
          stream.raw(last_lines: last_lines)
        end
      end

      def extract_coverage(regex)
        read do |stream|
          stream.extract_coverage(regex)
        end
      end

      def extract_sections
        read do |stream|
          stream.extract_sections
        end
      end

      def set(data)
        write('w+b') do |stream|
          data = job.hide_secrets(data)
          stream.set(data)
        end
      end

      def append(data, offset)
        write('a+b') do |stream|
          current_length = stream.size
          break current_length unless current_length == offset

          data = job.hide_secrets(data)
          stream.append(data, offset)
          stream.size
        end
      end

      def exist?
        trace_artifact&.exists? || job.trace_chunks.any? || current_path.present? || old_trace.present?
      end

      def read
        stream = Gitlab::Ci::Trace::Stream.new do
          if trace_artifact
            trace_artifact.open
          elsif job.trace_chunks.any?
            Gitlab::Ci::Trace::ChunkedIO.new(job)
          elsif current_path
            File.open(current_path, "rb")
          elsif old_trace
            StringIO.new(old_trace)
          end
        end

        yield stream
      ensure
        stream&.close
      end

      def write(mode)
        stream = Gitlab::Ci::Trace::Stream.new do
          if trace_artifact
            raise AlreadyArchivedError, 'Could not write to the archived trace'
          elsif current_path
            File.open(current_path, mode)
          else
            Gitlab::Ci::Trace::ChunkedIO.new(job)
          end
        end

        yield(stream).tap do
          job.touch if job.needs_touch?
        end
      ensure
        stream&.close
      end

      def erase!
        ##
        # Erase the archived trace
        trace_artifact&.destroy!

        ##
        # Erase the live trace
        job.trace_chunks.fast_destroy_all # Destroy chunks of a live trace
        FileUtils.rm_f(current_path) if current_path # Remove a trace file of a live trace
        job.erase_old_trace! if job.has_old_trace? # Remove a trace in database of a live trace
      ensure
        @current_path = nil
      end

      def archive!
        try_obtain_lease do
          unsafe_archive!
        end
      end

      private

      def unsafe_archive!
        raise AlreadyArchivedError, 'Could not archive again' if trace_artifact
        raise ArchiveError, 'Job is not finished yet' unless job.complete?

        if job.trace_chunks.any?
          Gitlab::Ci::Trace::ChunkedIO.new(job) do |stream|
            archive_stream!(stream)
            stream.destroy!
          end
        elsif current_path
          File.open(current_path) do |stream|
            archive_stream!(stream)
            FileUtils.rm(current_path)
          end
        elsif old_trace
          StringIO.new(old_trace, 'rb').tap do |stream|
            archive_stream!(stream)
            job.erase_old_trace!
          end
        end
      end

      def archive_stream!(stream)
        clone_file!(stream, JobArtifactUploader.workhorse_upload_path) do |clone_path|
          create_build_trace!(job, clone_path)
        end
      end

      def clone_file!(src_stream, temp_dir)
        FileUtils.mkdir_p(temp_dir)
        Dir.mktmpdir('tmp-trace', temp_dir) do |dir_path|
          temp_path = File.join(dir_path, "job.log")
          FileUtils.touch(temp_path)
          size = IO.copy_stream(src_stream, temp_path)
          raise ArchiveError, 'Failed to copy stream' unless size == src_stream.size

          yield(temp_path)
        end
      end

      def create_build_trace!(job, path)
        File.open(path) do |stream|
          # TODO: Set `file_format: :raw` after we've cleaned up legacy traces migration
          # https://gitlab.com/gitlab-org/gitlab-ce/merge_requests/20307
          job.create_job_artifacts_trace!(
            project: job.project,
            file_type: :trace,
            file: stream,
            file_sha256: Digest::SHA256.file(path).hexdigest)
        end
      end

      def ensure_path
        return current_path if current_path

        ensure_directory
        default_path
      end

      def ensure_directory
        unless Dir.exist?(default_directory)
          FileUtils.mkdir_p(default_directory)
        end
      end

      def current_path
        @current_path ||= paths.find do |trace_path|
          File.exist?(trace_path)
        end
      end

      def paths
        [
          default_path,
          deprecated_path
        ].compact
      end

      def default_directory
        File.join(
          Settings.gitlab_ci.builds_path,
          job.created_at.utc.strftime("%Y_%m"),
          job.project_id.to_s
        )
      end

      def default_path
        File.join(default_directory, "#{job.id}.log")
      end

      def deprecated_path
        File.join(
          Settings.gitlab_ci.builds_path,
          job.created_at.utc.strftime("%Y_%m"),
          job.project.ci_id.to_s,
          "#{job.id}.log"
        ) if job.project&.ci_id
      end

      def trace_artifact
        job.job_artifacts_trace
      end

      # For ExclusiveLeaseGuard concern
      def lease_key
        @lease_key ||= "trace:archive:#{job.id}"
      end

      # For ExclusiveLeaseGuard concern
      def lease_timeout
        LEASE_TIMEOUT
      end
    end
  end
end
