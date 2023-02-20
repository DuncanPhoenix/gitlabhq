# frozen_string_literal: true

require 'active_support/inflector'

require_relative 'base'
require_relative '../../../../lib/gitlab_edition'

# Returns system specs files that are related to the JS files that were changed in the MR.
module Tooling
  module Mappings
    class JsToSystemSpecsMappings < Base
      def initialize(js_base_folder: 'app/assets/javascripts', system_specs_base_folder: 'spec/features')
        @js_base_folder           = js_base_folder
        @js_base_folders          = folders_for_available_editions(js_base_folder)
        @system_specs_base_folder = system_specs_base_folder

        # Cannot be extracted to a constant, as it depends on a variable
        @first_js_folder_extract_regexp = %r{
          (?:.*/)?             # Skips the GitLab edition (e.g. ee/, jh/)
          #{@js_base_folder}/  # Most likely app/assets/javascripts/
          ([\w-]*)             # Captures the first folder
        }x
      end

      def execute(changed_files)
        filter_files(changed_files).flat_map do |edition, js_files|
          js_keywords_regexp = Regexp.union(construct_js_keywords(js_files))

          system_specs_for_edition(edition).select do |system_spec_file|
            system_spec_file if js_keywords_regexp.match?(system_spec_file)
          end
        end
      end

      # Keep the files that are in the @js_base_folders folders
      #
      # Returns a hash, where the key is the GitLab edition, and the values the JS specs
      def filter_files(changed_files)
        selected_files = changed_files.select do |filename|
          filename.start_with?(*@js_base_folders) && File.exist?(filename)
        end

        selected_files.group_by { |filename| filename[/^#{Regexp.union(::GitlabEdition.extensions)}/] }
      end

      # Extract keywords in the JS filenames to be used for searching matching system specs
      def construct_js_keywords(js_files)
        js_files.map do |js_file|
          filename = js_file.scan(@first_js_folder_extract_regexp).flatten.first
          filename.singularize
        end.uniq
      end

      def system_specs_for_edition(edition)
        all_files_in_folders_glob = File.join(@system_specs_base_folder, '**', '*')
        all_files_in_folders_glob = File.join(edition, all_files_in_folders_glob) if edition
        Dir[all_files_in_folders_glob].select { |f| File.file?(f) }
      end
    end
  end
end
