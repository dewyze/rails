# frozen_string_literal: true

module ActiveRecord
  class Relation
    class JoinClause # :nodoc:
      attr_reader :source, :on, :alias_name

      def initialize(source, on, alias_name = nil)
        @source = source
        @on = on
        @alias_name = alias_name
      end

      def ==(other)
        self.class == other.class &&
          source == other.source &&
          on == other.on &&
          alias_name == other.alias_name
      end

      # Builds the Arel join node for this clause.
      #
      # +source_table+ is the Arel::Table of the relation being queried (the FROM table).
      # +join_type+ is the Arel join node class (e.g. Arel::Nodes::InnerJoin).
      def build_join_node(source_table, join_type)
        join_table = build_join_table
        constraint = build_constraint(join_table, source_table)

        join_type.new(join_table, Arel::Nodes::On.new(constraint))
      end

      private
        def build_join_table
          case source
          when ActiveRecord::Relation
            subquery = source.arel
            name = alias_name || raise(ArgumentError, "An alias is required when joining a subquery. Use `as:` to provide one.")
            Arel::Nodes::TableAlias.new(Arel::Nodes::Grouping.new(subquery), name.to_s)
          else
            table_name = source.to_s
            arel_table = Arel::Table.new(table_name)

            if alias_name && alias_name.to_s != table_name
              Arel::Nodes::TableAlias.new(arel_table, alias_name.to_s)
            else
              arel_table
            end
          end
        end

        def build_constraint(join_table, source_table)
          conditions = on.map do |join_column, source_column|
            join_table[join_column].eq(source_table[source_column])
          end

          if conditions.size == 1
            conditions.first
          else
            Arel::Nodes::And.new(conditions)
          end
        end
    end
  end
end
