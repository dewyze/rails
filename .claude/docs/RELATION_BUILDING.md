# ActiveRecord Relation Building Pipeline: Complete Reference

## Overview

The Relation object is the central query builder in ActiveRecord. It accumulates query state lazily in a `@values` hash, then constructs an Arel AST on demand, which is visited to produce SQL.

---

## 1. The Relation Object

**File:** `activerecord/lib/active_record/relation.rb`

### Constructor (lines 77-95)

```ruby
def initialize(model, table: nil, predicate_builder: nil, values: {})
  @model  = model
  @table  = table            # Arel::Table instance
  @values = values           # THE central state hash
  @loaded = false
  @predicate_builder = predicate_builder
  @delegate_to_model = false
  @future_result = nil
  @records = nil
  @async = false
  @none = false
end
```

### The Three Value Categories (lines 54-65)

```ruby
MULTI_VALUE_METHODS  = [:includes, :eager_load, :preload, :select, :group,
                        :order, :joins, :left_outer_joins, :references,
                        :extending, :unscope, :optimizer_hints, :annotate, :with]

SINGLE_VALUE_METHODS = [:limit, :offset, :lock, :readonly, :reordering,
                        :strict_loading, :reverse_order, :distinct, :create_with,
                        :skip_query_cache]

CLAUSE_METHODS = [:where, :having, :from]
```

| Category | Accessor Pattern | Default |
|----------|-----------------|---------|
| Multi-value | `#{name}_values` / `#{name}_values=` | `FROZEN_EMPTY_ARRAY` |
| Single-value | `#{name}_value` / `#{name}_value=` | `nil` |
| Clause | `#{name}_clause` / `#{name}_clause=` | `WhereClause.empty` / `FromClause.empty` |

### Dynamic Accessor Generation

**File:** `activerecord/lib/active_record/relation/query_methods.rb` (lines 162-183)

Accessors are generated at class-definition time via `class_eval`. Every accessor reads from `@values` using `fetch` with the default:

```ruby
def includes_values
  @values.fetch(:includes, FROZEN_EMPTY_ARRAY)
end
```

Setters call `assert_modifiable!` which raises if the relation is already loaded or has a cached `@arel`.

---

## 2. Immutability via Clone

### The spawn Pattern

**File:** `activerecord/lib/active_record/relation/spawn_methods.rb` (line 9-11)

```ruby
def spawn
  already_in_scope?(model.scope_registry) ? model.all : clone
end
```

Every public chaining method:
1. Calls `spawn` to get a clone
2. Calls the `!` variant on the clone
3. Returns the clone

### initialize_copy (relation.rb, line 97-100)

```ruby
def initialize_copy(other)
  @values = @values.dup   # shallow dup of the hash
  reset                    # clears @arel, @to_sql, @loaded, @records
end
```

The shallow dup means inner values (arrays, WhereClause) may be shared until `|=` or `+=` creates new objects.

---

## 3. SpawnMethods: merge, except, only

**File:** `activerecord/lib/active_record/relation/spawn_methods.rb`

- **`merge(other)`** (line 33-41): Delegates to `Relation::Merger`
- **`except(*skips)`** (line 59-61): Returns relation with specified keys removed
- **`only(*onlies)`** (line 67-69): Returns relation with only specified keys

---

## 4. The Merger

**File:** `activerecord/lib/active_record/relation/merger.rb`

### Processing Order (line 58-81)

1. Normal values (group, distinct, etc.)
2. Set `none!` if other is null relation
3. Merge select values
4. Merge multi values (order, extensions)
5. Merge single values (lock, create_with)
6. Merge clauses (where, having, from) -- where uses `WhereClause#merge` which replaces same-attribute conditions
7. Merge preloads
8. Merge joins and outer joins

### Same-Model vs Cross-Model Merges

**Joins** (line 117):
- Same model: `relation.joins_values |= other.joins_values`
- Different model: wraps in `JoinDependency`, adds as `stashed_join`

**Preloads** (line 96):
- Same model: direct combine
- Different model: nests under association reflection

---

## 5. The WhereClause

**File:** `activerecord/lib/active_record/relation/where_clause.rb`

A value object holding an array of Arel predicate nodes. Supports:
- `+` (concatenation)
- `-` (removal)
- `|` (union)
- `merge` (replaces same-attribute conditions)
- `or` (OR combination)
- `invert` (NOT)
- `ast` -- converts to Arel::Nodes::And or returns single predicate

### build_where_clause (query_methods.rb, lines 1614-1654)

Handles three input types:
```ruby
case opts
when String
  # Raw SQL, optionally with binds
when Hash
  # Attribute conditions -- uses predicate_builder
when Arel::Nodes::Node
  # Direct Arel node
end
```

For Hash: calls `predicate_builder.build_from_hash(opts)` which creates Equality nodes. Also extracts `references` for eager loading detection.

---

## 6. build_arel -- The Central Assembly

**File:** `activerecord/lib/active_record/relation/query_methods.rb` (line 1750)

Assembly order:
1. Create `Arel::SelectManager.new(table)`
2. **`build_joins`** -- JOIN construction
3. **WHERE** -- `arel.where(where_clause.ast)`
4. **HAVING** -- `arel.having(having_clause.ast)`
5. **LIMIT** -- `arel.take(limit_value)`
6. **OFFSET** -- `arel.skip(offset_value)`
7. **GROUP BY** -- `arel.group(*arel_columns(group_values))`
8. **ORDER BY** -- `build_order(arel)`
9. **WITH** (CTEs) -- `build_with(arel)`
10. **SELECT** -- `build_select(arel)`
11. **Optimizer hints**
12. **Annotations/Comments**
13. **DISTINCT**
14. **FROM override**
15. **LOCK**

Memoized: `@arel ||= build_arel(aliases)` (line 1595)

---

## 7. SQL Generation: Connection to Visitor

### to_sql on Relation (relation.rb, lines 1242-1253)

```ruby
def to_sql
  @to_sql ||= if eager_loading?
    apply_join_dependency do |relation, join_dependency|
      relation = join_dependency.apply_column_aliases(relation)
      relation.to_sql
    end
  else
    model.with_connection do |conn|
      conn.unprepared_statement { conn.to_sql(arel) }
    end
  end
end
```

### to_sql on Connection (database_statements.rb, lines 12-51)

```ruby
def to_sql_and_binds(arel_or_sql_string, binds = [], preparable = nil)
  if arel_or_sql_string.respond_to?(:ast)
    arel_or_sql_string = arel_or_sql_string.ast   # SelectManager -> SelectStatement
  end

  if Arel.arel_node?(arel_or_sql_string)
    collector = collector()
    if prepared_statements
      collector.preparable = true
      sql, binds = visitor.compile(arel_or_sql_string, collector)
    else
      sql = visitor.compile(arel_or_sql_string, collector)
    end
  end
end
```

### Adapter-Specific Visitors

```ruby
# abstract_adapter.rb:
def arel_visitor
  Arel::Visitors::ToSql.new(self)    # default
end
# PostgreSQL, MySQL, SQLite override this
```

### Collectors

```ruby
# With prepared statements:
Arel::Collectors::Composite.new(
  Arel::Collectors::SQLString.new,    # SQL template with $1, $2, etc.
  Arel::Collectors::Bind.new,         # bind parameter values
)

# Without prepared statements:
Arel::Collectors::SubstituteBinds.new(
  self,                                # connection for quoting
  Arel::Collectors::SQLString.new,     # SQL with values inlined
)
```

---

## 8. The Eager Loading Fork

### eager_loading? (relation.rb, line 1270)

```ruby
def eager_loading?
  @should_eager_load ||=
    eager_load_values.any? ||
    includes_values.any? && (joined_includes_values.any? || references_eager_loaded_tables?)
end
```

`includes` becomes LEFT OUTER JOIN when:
1. `eager_load_values` present, OR
2. `includes_values` overlap with `joins_values`, OR
3. `references_values` mention included tables

### apply_join_dependency (finder_methods.rb, line 458)

```ruby
def apply_join_dependency(eager_loading: group_values.empty?)
  join_dependency = construct_join_dependency(
    eager_load_values | includes_values, Arel::Nodes::OuterJoin
  )
  relation = except(:includes, :eager_load, :preload).joins!(join_dependency)
end
```

Strips includes/eager_load/preload, injects a `JoinDependency` with `OuterJoin` type.

---

## 9. Key Architectural Observations

1. **Lazy evaluation everywhere:** `@arel` only built when SQL is needed. `@to_sql` memoized on top. `@values` keys lazily populated.

2. **Immutability via clone:** Every public method spawns a new Relation. Bang methods mutate in-place (used internally after spawn).

3. **Three-layer architecture:**
   - **Relation layer** manages query state in `@values`
   - **Arel Manager layer** translates state to AST
   - **Visitor layer** walks AST to produce SQL

4. **Adapter-specific SQL:** PostgreSQL, MySQL, SQLite each subclass `Arel::Visitors::ToSql` for dialect differences.

5. **Collector controls bind handling:** Prepared statements collect binds separately; inline substitution quotes values into the SQL string.

6. **Join ordering is deliberate:** Leading joins first, association joins (with aliases) in the middle, explicit nodes last.

7. **WhereClause is a value object:** Supports set operations (+, -, |, merge, or, invert). Its `ast` method produces the Arel predicate tree.
