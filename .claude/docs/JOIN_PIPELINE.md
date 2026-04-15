# ActiveRecord JOIN Pipeline: Complete Technical Reference

## Overview

The JOIN pipeline traces the path from `Model.joins(:foo).where(bar: 1)` through to the final SQL string. It involves three layers: Relation state accumulation, Arel AST construction, and visitor-based SQL generation.

---

## 1. Public Query Methods -- The Storage Layer

**File:** `activerecord/lib/active_record/relation/query_methods.rb`

All join-related values are stored in the `@values` hash on the `Relation`, accessed through dynamically generated accessor methods (lines 162-183). The relevant `MULTI_VALUE_METHODS` are:

```
:includes, :eager_load, :preload, :joins, :left_outer_joins, :references
```

Each gets `_values` / `_values=` accessors. All default to `FROZEN_EMPTY_ARRAY` (`[].freeze`).

### Method Signatures and Storage

| Method | Lines | Storage Key | Default Join Type |
|--------|-------|-------------|-------------------|
| `joins(*args)` | 868-876 | `:joins` | `InnerJoin` |
| `left_outer_joins(*args)` | 883-892 | `:left_outer_joins` | `OuterJoin` |
| `includes(*args)` | 250-258 | `:includes` | Depends on context |
| `eager_load(*args)` | 290-298 | `:eager_load` | `OuterJoin` |
| `preload(*args)` | 322-330 | `:preload` | Separate queries |
| `references(*table_names)` | 355-363 | `:references` | N/A (metadata) |

### Aliasing

```ruby
alias :left_joins :left_outer_joins   # line 887
```

`left_joins` is a pure alias. They share storage key `:left_outer_joins` and bang method `left_outer_joins!`.

### The Spawn/Clone Pattern

Every public method follows:

```ruby
def joins(*args)
  check_if_method_has_arguments!(__callee__, args)
  spawn.joins!(*args)             # clone via spawn, mutate clone
end

def joins!(*args)
  self.joins_values |= args       # set-union to accumulate + deduplicate
  self
end
```

`spawn` (from `SpawnMethods`) duplicates the Relation so chaining is non-destructive.

### WhereChain Integration (lines 88-148)

- `where.associated(:author)` -> adds INNER JOIN + NOT NULL condition
- `where.missing(:author)` -> adds LEFT OUTER JOIN + IS NULL condition

---

## 2. build_arel -- The Central Assembly Point

**File:** `activerecord/lib/active_record/relation/query_methods.rb`, line 1750

```ruby
def build_arel(aliases)
  arel = Arel::SelectManager.new(table)
  build_joins(arel.join_sources, aliases)   # JOIN construction
  arel.where(where_clause.ast) unless where_clause.empty?
  arel.having(having_clause.ast) unless having_clause.empty?
  arel.take(build_cast_value("LIMIT", limit_value)) if limit_value
  arel.skip(build_cast_value("OFFSET", offset_value.to_i)) if offset_value
  arel.group(*arel_columns(group_values)) unless group_values.empty?
  build_order(arel)
  build_with(arel)
  build_select(arel)
  # ... optimizer_hints, annotations, distinct, from, lock
  arel
end
```

Memoized via `@arel ||= build_arel(aliases)` in the `arel` method (line 1595).

---

## 3. build_join_buckets -- The Partitioning Engine

**File:** `activerecord/lib/active_record/relation/query_methods.rb`, lines 1820-1874

This is the most intricate method. It classifies all join values into four buckets:

```ruby
buckets = {
  leading_join: [],   # Arel join nodes that must precede association joins
  named_join:   [],   # Association names (symbols/hashes) for JoinDependency
  stashed_join: [],   # Pre-built JoinDependency objects (from merges, eager_load)
  join_node:    [],   # Raw Arel Join nodes and StringJoins
}
```

### Algorithm

**Step 1: Process `left_outer_joins_values`** (lines 1823-1839):
- Partition into CTE joins vs association names
- If no inner joins exist: return left join associations as `named_join` with `OuterJoin` type
- If inner joins also exist: wrap left join associations in a `JoinDependency` with `OuterJoin` type, place in `stashed_joins`

**Step 2: Process `joins_values`** (lines 1842-1873):
- Convert string joins to `Arel::Nodes::StringJoin`
- `LeadingJoin` nodes always go to `leading_join`
- Symbols/Hashes/Arrays go to `named_join`
- `JoinDependency` objects go to `stashed_join`
- Other `Arel::Nodes::Join` go to `join_node`

**Returns:** `(buckets, join_type)` where `join_type` is `InnerJoin` or `OuterJoin`

### CTE Join Detection

Symbols matching `with_values` keys become CTE joins built via `build_with_join_node` (lines 1950-1956).

---

## 4. build_joins -- Assembling the Final Join Sources

**File:** `activerecord/lib/active_record/relation/query_methods.rb`, lines 1876-1896

```ruby
def build_joins(join_sources, aliases = nil)
  return join_sources if joins_values.empty? && left_outer_joins_values.empty?

  buckets, join_type = build_join_buckets

  named_joins   = buckets[:named_join]
  stashed_joins = buckets[:stashed_join]
  leading_joins = buckets[:leading_join]
  join_nodes    = buckets[:join_node]

  # 1. Leading joins go first
  join_sources.concat(leading_joins)

  # 2. Named (association) joins resolved through JoinDependency
  unless named_joins.empty? && stashed_joins.empty?
    alias_tracker = alias_tracker(leading_joins + join_nodes, aliases)
    join_dependency = construct_join_dependency(named_joins, join_type)
    join_sources.concat(
      join_dependency.join_constraints(stashed_joins, alias_tracker, references_values)
    )
  end

  # 3. Explicit join nodes go last
  join_sources.concat(join_nodes)
  join_sources
end
```

**Ordering matters:** Leading joins -> Association joins (with aliases) -> Explicit join nodes.

---

## 5. JoinDependency -- The Join Tree Builder

**File:** `activerecord/lib/active_record/associations/join_dependency.rb`

### Architecture

Models the join graph as a **tree** of `JoinPart` nodes:
- **Root:** `JoinBase` representing the primary model/table
- **Children:** `JoinAssociation` nodes, one per association

### Constructor (line 71)

```ruby
def initialize(base, table, associations, join_type)
  tree = self.class.make_tree(associations)     # Normalize to hash-of-hashes
  @join_root = JoinBase.new(base, table, build(tree, base))
  @join_type = join_type
end
```

### make_tree / walk_tree (lines 47-69)

Normalizes heterogeneous inputs:
- `:posts` -> `{ posts: {} }`
- `[:posts, :comments]` -> `{ posts: {}, comments: {} }`
- `{ posts: :comments }` -> `{ posts: { comments: {} } }`

### build (private, line 228)

Recursively resolves association names to reflections and creates `JoinAssociation` nodes.

### join_constraints (line 85)

The core method that generates Arel join nodes:

```ruby
def join_constraints(joins_to_add, alias_tracker, references)
  @alias_tracker = alias_tracker
  @joined_tables = {}

  joins = make_join_constraints(join_root, join_type)

  # Merge stashed JoinDependencies
  joins.concat joins_to_add.flat_map { |oj|
    if join_root.match?(oj.join_root)
      walk(join_root, oj.join_root, oj.join_type)   # Same root: merge trees
    else
      make_join_constraints(oj.join_root, oj.join_type)  # Different root
    end
  }
end
```

### Tree Merging: walk (line 214)

Avoids duplicate joins when merging two JoinDependencies with the same root by matching children and reusing table aliases.

---

## 6. JoinAssociation -- Per-Association Join Builder

**File:** `activerecord/lib/active_record/associations/join_dependency/join_association.rb`

### join_constraints (line 24)

```ruby
def join_constraints(foreign_table, foreign_klass, join_type, alias_tracker)
  joins = []
  chain = []

  # Walk the reflection chain, allocating tables
  reflection.chain.each_with_index do |reflection, index|
    table, terminated = yield reflection, reflection_chain[index..]
    @table ||= table
    break if terminated
    chain << [reflection, table]
  end

  # Build joins in reverse (from owner toward target)
  chain.reverse_each do |reflection, table|
    scope = reflection.join_scope(table, foreign_table, foreign_klass)
    arel = scope.arel(alias_tracker.aliases)
    nodes = arel.constraints.first

    # Separate ON-clause predicates from cross-table predicates
    if nodes.is_a?(Arel::Nodes::And)
      others = nodes.children.extract! { |node|
        !Arel.fetch_attribute(node) { |attr| attr.relation.name == table.name }
      }
    end

    joins << join_type.new(table, Arel::Nodes::On.new(nodes))

    if others && !others.empty?
      joins.concat arel.join_sources
      append_constraints(joins.last, others)
    end

    foreign_table, foreign_klass = table, klass
  end
  joins
end
```

Key: Uses `reflection.join_scope` to get ON conditions, then wraps in `join_type.new(table, Arel::Nodes::On.new(nodes))`.

---

## 7. AliasTracker -- Table Alias Management

**File:** `activerecord/lib/active_record/associations/alias_tracker.rb`

Prevents table name collisions. First use of a name gets the original; subsequent uses get suffixed aliases (`comments_posts`, `comments_posts_2`, etc.).

```ruby
def aliased_table_for(arel_table, table_name = nil)
  if aliases[table_name] == 0
    aliases[table_name] = 1
    arel_table.alias(table_name) if arel_table.name != table_name
  else
    aliased_name = table_alias_for(yield)
    count = aliases[aliased_name] += 1
    aliased_name = "#{truncate(aliased_name)}_#{count}" if count > 1
    arel_table.alias(aliased_name)
  end
end
```

---

## 8. Merger -- Cross-Relation Join Merging

**File:** `activerecord/lib/active_record/relation/merger.rb`

### merge_joins (line 117)

- **Same model:** direct set-union of joins_values
- **Different model:** wraps associations in a `JoinDependency`, places in `stashed_joins`

### merge_outer_joins (line 136)

Same pattern using `OuterJoin` type and `left_outer_joins!`.

---

## 9. The includes Decision Fork

**File:** `activerecord/lib/active_record/relation.rb`

`includes` auto-switches from preload (separate queries) to eager_load (LEFT OUTER JOIN) when:
1. `eager_load_values` are present, OR
2. `includes_values` overlap with `joins_values`, OR
3. `references_values` mention included association tables

```ruby
def eager_loading?
  @should_eager_load ||=
    eager_load_values.any? ||
    includes_values.any? && (joined_includes_values.any? || references_eager_loaded_tables?)
end
```

---

## 10. Complete Pipeline Trace

```
Post.joins(:comments).where(title: "hello")

Phase 1: State Accumulation
  Post.all -> Relation.new(Post, values: {})
  .joins(:comments) -> spawn, joins_values |= [:comments]
  .where(title: "hello") -> spawn, where_clause += WhereClause([equality_node])

Phase 2: Arel AST Construction (build_arel)
  arel = Arel::SelectManager.new(posts_table)
  build_joins:
    build_join_buckets -> named_joins: [:comments], join_type: InnerJoin
    construct_join_dependency([:comments], InnerJoin)
      -> JoinDependency: JoinBase(Post) -> JoinAssociation(comments)
    join_dependency.join_constraints(...)
      -> reflection.join_scope(comments_table, posts_table, Post)
      -> WHERE comments.post_id = posts.id
      -> InnerJoin.new(comments_table, On.new(equality))
  arel.where(where_clause.ast) -> posts.title = 'hello'
  build_select -> project(posts.*)

Phase 3: SQL Generation (visitor)
  conn.to_sql(arel)
    -> visitor.compile(ast, collector)
    -> visit_SelectStatement -> visit_SelectCore
      -> "SELECT" + projections
      -> "FROM" + visit JoinSource
        -> visit posts_table: "posts"
        -> visit InnerJoin: INNER JOIN "comments" ON "comments"."post_id" = "posts"."id"
      -> "WHERE" + visit equality: "posts"."title" = 'hello'

Final: SELECT "posts".* FROM "posts"
       INNER JOIN "comments" ON "comments"."post_id" = "posts"."id"
       WHERE "posts"."title" = 'hello'
```
