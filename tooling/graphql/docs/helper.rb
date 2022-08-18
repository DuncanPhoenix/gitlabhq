# frozen_string_literal: true

require 'gitlab/utils/strong_memoize'

module Tooling
  module Graphql
    module Docs
      # We assume a few things about the schema. We use the graphql-ruby gem, which enforces:
      # - All mutations have a single input field named 'input'
      # - All mutations have a payload type, named after themselves
      # - All mutations have an input type, named after themselves
      # If these things change, then some of this code will break. Such places
      # are guarded with an assertion that our assumptions are not violated.
      ViolatedAssumption = Class.new(StandardError)

      SUGGESTED_ACTION = <<~MSG
        We expect it to be impossible to violate our assumptions about
        how mutation arguments work.

        If that is not the case, then something has probably changed in the
        way we generate our schema, perhaps in the library we use: graphql-ruby

        Please ask for help in the #f_graphql or #backend channels.
      MSG

      CONNECTION_ARGS = %w[after before first last].to_set

      FIELD_HEADER = <<~MD
        #### Fields

        | Name | Type | Description |
        | ---- | ---- | ----------- |
      MD

      ARG_HEADER = <<~MD
        # Arguments

        | Name | Type | Description |
        | ---- | ---- | ----------- |
      MD

      CONNECTION_NOTE = <<~MD
        This field returns a [connection](#connections). It accepts the
        four standard [pagination arguments](#connection-pagination-arguments):
        `before: String`, `after: String`, `first: Int`, `last: Int`.
      MD

      # Helper with functions to be used by HAML templates
      # This includes graphql-docs gem helpers class.
      # You can check the included module on: https://github.com/gjtorikian/graphql-docs/blob/v1.6.0/lib/graphql-docs/helpers.rb
      module Helper
        include GraphQLDocs::Helpers
        include Gitlab::Utils::StrongMemoize

        def auto_generated_comment
          <<-MD.strip_heredoc
            ---
            stage: Ecosystem
            group: Integrations
            info: To determine the technical writer assigned to the Stage/Group associated with this page, see https://about.gitlab.com/handbook/engineering/ux/technical-writing/#assignments
            ---

            <!---
              This documentation is auto generated by a script.

              Please do not edit this file directly, check compile_docs task on lib/tasks/gitlab/graphql.rake.
            --->
          MD
        end

        # Template methods:
        # Methods that return chunks of Markdown for insertion into the document

        def render_full_field(field, heading_level: 3, owner: nil)
          conn = connection?(field)
          args = field[:arguments].reject { |arg| conn && CONNECTION_ARGS.include?(arg[:name]) }
          arg_owner = [owner, field[:name]]

          chunks = [
            render_name_and_description(field, level: heading_level, owner: owner),
            render_return_type(field),
            render_input_type(field),
            render_connection_note(field),
            render_argument_table(heading_level, args, arg_owner),
            render_return_fields(field, owner: owner)
          ]

          join(:block, chunks)
        end

        def render_argument_table(level, args, owner)
          arg_header = ('#' * level) + ARG_HEADER
          render_field_table(arg_header, args, owner)
        end

        def render_name_and_description(object, owner: nil, level: 3)
          content = []

          heading = '#' * level
          name = [owner, object[:name]].compact.join('.')

          content << "#{heading} `#{name}`"
          content << render_description(object, owner, :block)

          join(:block, content)
        end

        def render_object_fields(fields, owner:, level_bump: 0)
          return if fields.blank?

          (with_args, no_args) = fields.partition { |f| args?(f) }
          type_name = owner[:name] if owner
          header_prefix = '#' * level_bump
          sections = [
            render_simple_fields(no_args, type_name, header_prefix),
            render_fields_with_arguments(with_args, type_name, header_prefix)
          ]

          join(:block, sections)
        end

        def render_enum_value(enum, value)
          render_row(render_name(value, enum[:name]), render_description(value, enum[:name], :inline))
        end

        def render_union_member(member)
          "- [`#{member}`](##{member.downcase})"
        end

        # QUERIES:

        # Methods that return parts of the schema, or related information:

        def connection_object_types
          objects.select { |t| t[:is_edge] || t[:is_connection] }
        end

        def object_types
          objects.reject { |t| t[:is_edge] || t[:is_connection] || t[:is_payload] }
        end

        def interfaces
          graphql_interface_types.map { |t| t.merge(fields: t[:fields] + t[:connections]) }
        end

        def fields_of(type_name)
          graphql_operation_types
            .find { |type| type[:name] == type_name }
            .values_at(:fields, :connections)
            .flatten
            .then { |fields| sorted_by_name(fields) }
        end

        # Place the arguments of the input types on the mutation itself.
        # see: `#input_types` - this method must not call `#input_types` to avoid mutual recursion
        def mutations
          @mutations ||= sorted_by_name(graphql_mutation_types).map do |t|
            inputs = t[:input_fields]
            input = inputs.first
            name = t[:name]

            assert!(inputs.one?, "Expected exactly 1 input field named #{name}. Found #{inputs.count} instead.")
            assert!(input[:name] == 'input', "Expected the input of #{name} to be named 'input'")

            input_type_name = input[:type][:name]
            input_type = graphql_input_object_types.find { |t| t[:name] == input_type_name }
            assert!(input_type.present?, "Cannot find #{input_type_name} for #{name}.input")

            arguments = input_type[:input_fields]
            seen_type!(input_type_name)
            t.merge(arguments: arguments)
          end
        end

        # We assume that the mutations have been processed first, marking their
        # inputs as `seen_type?`
        def input_types
          mutations # ensure that mutations have seen their inputs first
          graphql_input_object_types.reject { |t| seen_type?(t[:name]) }
        end

        # We ignore the built-in enum types, and sort values by name
        def enums
          graphql_enum_types
            .reject { |type| type[:values].empty? }
            .reject { |enum_type| enum_type[:name].start_with?('__') }
            .map { |type| type.merge(values: sorted_by_name(type[:values])) }
        end

        private # DO NOT CALL THESE METHODS IN TEMPLATES

        # Template methods

        def render_return_type(query)
          return unless query[:type] # for example, mutations

          "Returns #{render_field_type(query[:type])}."
        end

        def render_simple_fields(fields, type_name, header_prefix)
          render_field_table(header_prefix + FIELD_HEADER, fields, type_name)
        end

        def render_fields_with_arguments(fields, type_name, header_prefix)
          return if fields.empty?

          level = 5 + header_prefix.length
          sections = sorted_by_name(fields).map do |f|
            render_full_field(f, heading_level: level, owner: type_name)
          end

          <<~MD.chomp
            #{header_prefix}#### Fields with arguments

            #{join(:block, sections)}
          MD
        end

        def render_field_table(header, fields, owner)
          return if fields.empty?

          fields = sorted_by_name(fields)
          header + join(:table, fields.map { |f| render_field(f, owner) })
        end

        def render_field(field, owner)
          render_row(
            render_name(field, owner),
            render_field_type(field[:type]),
            render_description(field, owner, :inline)
          )
        end

        def render_return_fields(mutation, owner:)
          fields = mutation[:return_fields]
          return if fields.blank?

          name = owner.to_s + mutation[:name]
          render_object_fields(fields, owner: { name: name })
        end

        def render_connection_note(field)
          return unless connection?(field)

          CONNECTION_NOTE.chomp
        end

        def render_row(*values)
          "| #{values.map { |val| val.to_s.squish }.join(' | ')} |"
        end

        def render_name(object, owner = nil)
          rendered_name = "`#{object[:name]}`"
          rendered_name += ' **{warning-solid}**' if deprecated?(object, owner)

          return rendered_name unless owner

          owner = Array.wrap(owner).join('')
          id = (owner + object[:name]).downcase

          %(<a id="#{id}"></a>) + rendered_name
        end

        # Returns the object description. If the object has been deprecated,
        # the deprecation reason will be returned in place of the description.
        def render_description(object, owner = nil, context = :block)
          if deprecated?(object, owner)
            render_deprecation(object, owner, context)
          else
            render_description_of(object, owner, context)
          end
        end

        def deprecated?(object, owner)
          return true if object[:is_deprecated] # only populated for fields, not arguments!

          key = [*Array.wrap(owner), object[:name]].join('.')
          deprecations.key?(key)
        end

        def render_description_of(object, owner, context = nil)
          desc = if object[:is_edge]
                   base = object[:name].chomp('Edge')
                   "The edge type for [`#{base}`](##{base.downcase})."
                 elsif object[:is_connection]
                   base = object[:name].chomp('Connection')
                   "The connection type for [`#{base}`](##{base.downcase})."
                 else
                   object[:description]&.strip
                 end

          return if desc.blank?

          desc += '.' unless desc.ends_with?('.')
          see = doc_reference(object, owner)
          desc += " #{see}" if see
          desc += " (see [Connections](#connections))" if connection?(object) && context != :block
          desc
        end

        def doc_reference(object, owner)
          field = schema_field(owner, object[:name]) if owner
          return unless field

          ref = field.try(:doc_reference)
          return if ref.blank?

          parts = ref.to_a.map do |(title, url)|
            "[#{title.strip}](#{url.strip})"
          end

          "See #{parts.join(', ')}."
        end

        def render_deprecation(object, owner, context)
          buff = []
          deprecation = schema_deprecation(owner, object[:name])
          original_description = deprecation&.original_description || render_description_of(object, owner)

          buff << original_description if context == :block
          buff << if deprecation
                    deprecation.markdown(context: context)
                  else
                    "**Deprecated:** #{object[:deprecation_reason]}"
                  end

          buff << original_description if context == :inline && deprecation&.alpha?

          join(context, buff)
        end

        def render_field_type(type)
          "[`#{type[:info]}`](##{type[:name].downcase})"
        end

        def join(context, chunks)
          chunks.compact!
          return if chunks.blank?

          case context
          when :block
            chunks.join("\n\n")
          when :inline
            chunks.join(" ").squish.presence
          when :table
            chunks.join("\n")
          end
        end

        # Queries

        def sorted_by_name(objects)
          return [] unless objects.present?

          objects.sort_by { |o| o[:name] }
        end

        def connection?(field)
          type_name = field.dig(:type, :name)
          type_name.present? && type_name.ends_with?('Connection')
        end

        # We are ignoring connections and built in types for now,
        # they should be added when queries are generated.
        def objects
          strong_memoize(:objects) do
            mutations = schema.mutation&.fields&.keys&.to_set || []

            graphql_object_types
              .reject { |object_type| object_type[:name]["__"] || object_type[:name] == 'Subscription' } # We ignore introspection and subscription types.
              .map do |type|
                name = type[:name]
                type.merge(
                  is_edge: name.ends_with?('Edge'),
                  is_connection: name.ends_with?('Connection'),
                  is_payload: name.ends_with?('Payload') && mutations.include?(name.chomp('Payload').camelcase(:lower)),
                  fields: type[:fields] + type[:connections]
                )
              end
          end
        end

        def args?(field)
          args = field[:arguments]
          return false if args.blank?
          return true unless connection?(field)

          args.any? { |arg| CONNECTION_ARGS.exclude?(arg[:name]) }
        end

        # returns the deprecation information for a field or argument
        # See: Gitlab::Graphql::Deprecation
        def schema_deprecation(type_name, field_name)
          key = [*Array.wrap(type_name), field_name].join('.')
          deprecations[key]
        end

        def render_input_type(query)
          input_field = query[:input_fields]&.first
          return unless input_field

          "Input type: `#{input_field[:type][:name]}`"
        end

        def schema_field(type_name, field_name)
          type = schema.types[type_name]
          return unless type && type.kind.fields?

          type.fields[field_name]
        end

        def deprecations
          strong_memoize(:deprecations) do
            mapping = {}

            schema.types.each do |type_name, type|
              if type.kind.fields?
                type.fields.each do |field_name, field|
                  mapping["#{type_name}.#{field_name}"] = field.try(:deprecation)
                  field.arguments.each do |arg_name, arg|
                    mapping["#{type_name}.#{field_name}.#{arg_name}"] = arg.try(:deprecation)
                  end
                end
              elsif type.kind.enum?
                type.values.each do |member_name, enum|
                  mapping["#{type_name}.#{member_name}"] = enum.try(:deprecation)
                end
              end
            end

            mapping.compact
          end
        end

        def assert!(claim, message)
          raise ViolatedAssumption, "#{message}\n#{SUGGESTED_ACTION}" unless claim
        end
      end
    end
  end
end
