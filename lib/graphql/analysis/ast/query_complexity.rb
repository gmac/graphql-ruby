# frozen_string_literal: true
module GraphQL
  module Analysis
    # Calculate the complexity of a query, using {Field#complexity} values.
    module AST
      class QueryComplexity < Analyzer
        # State for the query complexity calculation:
        # - `complexities_on_type` holds complexity scores for each type
        def initialize(query)
          super
          @complexities_on_type_by_query = {}
        end

        # Overide this method to use the complexity result
        def result
          max_possible_complexity
        end

        # ScopedTypeComplexity models a tree of GraphQL types mapped to inner selections, ie:
        # Hash<GraphQL::BaseType, Hash<String, ScopedTypeComplexity>>
        class ScopedTypeComplexity < Hash
          # A proc for defaulting empty namespace requests as a new scope hash.
          DEFAULT_PROC = ->(h, k) { h[k] = {} }

          attr_reader :field_definition, :response_path, :query

          # @param parent_type [Class] The owner of `field_definition`
          # @param field_definition [GraphQL::Field, GraphQL::Schema::Field] Used for getting the `.complexity` configuration
          # @param query [GraphQL::Query] Used for `query.possible_types`
          # @param response_path [Array<String>] The path to the response key for the field
          # @return [Hash<GraphQL::BaseType, Hash<String, ScopedTypeComplexity>>]
          def initialize(parent_type, field_definition, query, response_path)
            super(&DEFAULT_PROC)
            @parent_type = parent_type
            @field_definition = field_definition
            @query = query
            @response_path = response_path
            @nodes = []
          end

          # @return [Array<GraphQL::Language::Nodes::Field>]
          attr_reader :nodes

          def own_complexity(child_complexity)
            @field_definition.calculate_complexity(query: @query, nodes: @nodes, child_complexity: child_complexity)
          end

          def composite?
            !empty?
          end
        end

        def on_enter_field(node, parent, visitor)
          # We don't want to visit fragment definitions,
          # we'll visit them when we hit the spreads instead
          return if visitor.visiting_fragment_definition?
          return if visitor.skipping?
          parent_type = visitor.parent_type_definition
          field_key = node.alias || node.name

          # Find or create a complexity scope stack for this query.
          scopes_stack = @complexities_on_type_by_query[visitor.query] ||= [ScopedTypeComplexity.new(nil, nil, query, visitor.response_path)]

          # Find or create the complexity costing node for this field.
          scope = scopes_stack.last[parent_type][field_key] ||= ScopedTypeComplexity.new(parent_type, visitor.field_definition, visitor.query, visitor.response_path)
          scope.nodes.push(node)
          scopes_stack.push(scope)
        end

        def on_leave_field(node, parent, visitor)
          # We don't want to visit fragment definitions,
          # we'll visit them when we hit the spreads instead
          return if visitor.visiting_fragment_definition?
          return if visitor.skipping?
          scopes_stack = @complexities_on_type_by_query[visitor.query]
          scopes_stack.pop
        end

        private

        # @return [Integer]
        def max_possible_complexity
          @complexities_on_type_by_query.reduce(0) do |total, (query, scopes_stack)|
            total + merged_max_complexity_for_scopes(query, [scopes_stack.first])
          end
        end

        # @param query [GraphQL::Query] Used for `query.possible_types`
        # @param scopes [Array<ScopedTypeComplexity>] Array of scoped type complexities
        # @return [Integer]
        def merged_max_complexity_for_scopes(query, scopes)
          # Aggregate a set of all possible scope types encountered (scope keys).
          # Use a hash, but ignore the values; it's just a fast way to work with the keys.
          possible_scope_types = scopes.each_with_object({}) do |scope, memo|
            memo.merge!(scope)
          end

          # Expand abstract scope types into their concrete implementations;
          # overlapping abstracts coalesce through their intersecting types.
          possible_scope_types.keys.each do |possible_scope_type|
            next unless possible_scope_type.kind.abstract?

            query.possible_types(possible_scope_type).each do |impl_type|
              possible_scope_types[impl_type] ||= true
            end
            possible_scope_types.delete(possible_scope_type)
          end

          # Aggregate the lexical selections that may apply to each possible type,
          # and then return the maximum cost among possible typed selections.
          possible_scope_types.each_key.reduce(0) do |max, possible_scope_type|
            # Collect inner selections from all scopes that intersect with this possible type.
            all_inner_selections = scopes.each_with_object([]) do |scope, memo|
              scope.each do |scope_type, inner_selections|
                memo << inner_selections if types_intersect?(query, scope_type, possible_scope_type)
              end
            end

            # Find the maximum complexity for the scope type among possible lexical branches.
            complexity = merged_max_complexity(query, all_inner_selections)
            complexity > max ? complexity : max
          end
        end

        def types_intersect?(query, a, b)
          return true if a == b

          a_types = query.possible_types(a)
          query.possible_types(b).any? { |t| a_types.include?(t) }
        end

        # A hook which is called whenever a field's max complexity is calculated.
        # Override this method to capture individual field complexity details.
        #
        # @param scoped_type_complexity [ScopedTypeComplexity]
        # @param max_complexity [Numeric] Field's maximum complexity including child complexity
        # @param child_complexity [Numeric, nil] Field's child complexity
        def field_complexity(scoped_type_complexity, max_complexity:, child_complexity: nil)
        end

        # @param inner_selections [Array<Hash<String, ScopedTypeComplexity>>] Field selections for a scope
        # @return [Integer] Total complexity value for all these selections in the parent scope
        def merged_max_complexity(query, inner_selections)
          # Aggregate a set of all unique field selection keys across all scopes.
          # Use a hash, but ignore the values; it's just a fast way to work with the keys.
          unique_field_keys = inner_selections.each_with_object({}) do |inner_selection, memo|
            memo.merge!(inner_selection)
          end

          # Add up the total cost for each unique field name's coalesced selections
          unique_field_keys.each_key.reduce(0) do |total, field_key|
            # Collect all child scopes for this field key (always finds results)
            child_scopes = inner_selections.filter_map { |inner_selection| inner_selection[field_key] }

            # Extract just composite scopes (without duplicating the array, if possible)
            composite_scope_count = child_scopes.count(&:composite?)
            composite_scopes = if composite_scope_count == composite_scopes.length
              child_scopes
            elsif composite_scope_count > 0
              child_scopes.select(&:composite?)
            else
              EMPTY_ARRAY
            end

            # Compute the merged maximum child complexity among composite scopes
            maximum_child_complexity = if composite_scopes.any?
              merged_max_complexity_for_scopes(query, composite_scopes)
            else
              0
            end

            # Identify the maximum cost and possibility among child scopes
            maximum_cost = 0
            maximum_scope = child_scopes.reduce(child_scopes.last) do |max_scope, possible_scope|
              inner_cost = possible_scope.composite? ? maximum_child_complexity : 0
              scope_cost = possible_scope.own_complexity(inner_cost)
              if scope_cost > maximum_cost
                maximum_cost = scope_cost
                possible_scope
              else
                max_scope
              end
            end

            # Callback with maximums. Note that max child complexity does not necessarily
            # correspond to the maximum scope; an expensive top-level field could outweigh
            # a cheaper field with the highest child selection cost.
            field_complexity(
              maximum_scope,
              max_complexity: maximum_cost,
              child_complexity: maximum_scope.composite? ? maximum_child_complexity : nil,
            )

            total + maximum_cost
          end
        end
      end
    end
  end
end
