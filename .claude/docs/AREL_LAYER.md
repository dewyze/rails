# Arel Join Infrastructure: Complete Technical Reference

## Overview

Arel is the SQL AST library embedded in ActiveRecord. It represents queries as node trees, uses a visitor pattern to generate SQL, and provides a fluent builder API.

---

## 1. Node Class Hierarchy for Joins

```
Arel::Nodes::Node
  +-- Arel::Nodes::NodeExpression
        +-- Arel::Nodes::Unary
        |     +-- Arel::Nodes::On          (metaprogrammed in unary.rb:37)
        |     +-- Arel::Nodes::Lateral     (metaprogrammed in unary.rb:32)
        |
        +-- Arel::Nodes::Binary
              +-- Arel::Nodes::Join         (metaprogrammed in binary.rb:117)
              |     +-- InnerJoin           (inner_join.rb -- empty body)
              |     |     +-- LeadingJoin   (leading_join.rb -- empty body)
              |     +-- OuterJoin           (outer_join.rb -- empty body)
              |     +-- FullOuterJoin       (full_outer_join.rb -- empty body)
              |     +-- RightOuterJoin      (right_outer_join.rb -- empty body)
              |     +-- StringJoin          (string_join.rb -- empty body)
              |
              +-- JoinSource               (join_source.rb)
```

### Metaprogramming Details

**`Join`** is created in `activerecord/lib/arel/nodes/binary.rb` (lines 114-123):
```ruby
%w{ Assignment Join Union UnionAll Intersect Except }.each do |name|
  const_set name, Class.new(Binary)
end
```

**`On`** is created in `activerecord/lib/arel/nodes/unary.rb` (lines 25-42):
```ruby
%w{ Bin Cube DistinctOn Group GroupingElement GroupingSet
    Lateral Limit Lock Not Offset On OptimizerHints RollUp }.each do |name|
  const_set(name, Class.new(Unary))
end
```

### Join Node Structure

For all join nodes (subclasses of `Binary`):
- **`left`** = the table being joined (Arel::Table, TableAlias, subquery, or Lateral)
- **`right`** = the join constraint (Arel::Nodes::On, or nil for cross joins)

For `On` (subclass of `Unary`):
- **`expr`** = the predicate (Equality, And, or any Arel predicate node)

---

## 2. JoinSource -- The FROM + Joins Container

**File:** `activerecord/lib/arel/nodes/join_source.rb`

```ruby
class JoinSource < Arel::Nodes::Binary
  def initialize(single_source, joinop = [])
    super
  end
  def empty?
    !left && right.empty?
  end
end
```

- **`left`** = the primary FROM table
- **`right`** = an **Array** of join nodes (pragmatic deviation from Binary's single-value pattern)

This is the backbone of `SelectCore`:
```ruby
# select_core.rb:
@source = JoinSource.new(relation)
```

---

## 3. SelectStatement AST Structure

```
SelectStatement
  +-- @with:    nil | With | WithRecursive
  +-- @cores:   [SelectCore]
  |     +-- @source:          JoinSource
  |     |     +-- left:       Arel::Table
  |     |     +-- right:      [InnerJoin, OuterJoin, StringJoin, ...]
  |     +-- @projections:     [Attribute, SqlLiteral, ...]
  |     +-- @wheres:          [predicate nodes]
  |     +-- @groups:          [Group nodes]
  |     +-- @havings:         [predicate nodes]
  |     +-- @windows:         [NamedWindow]
  |     +-- @comment:         Comment | nil
  |     +-- @set_quantifier:  Distinct | DistinctOn | nil
  |     +-- @optimizer_hints: OptimizerHints | nil
  +-- @orders:  [Ascending, Descending, SqlLiteral]
  +-- @limit:   Limit | nil
  +-- @offset:  Offset | nil
  +-- @lock:    Lock | nil
```

---

## 4. SelectManager API

**File:** `activerecord/lib/arel/select_manager.rb`

### join(relation, klass = Nodes::InnerJoin) -- lines 109-120

```ruby
def join(relation, klass = Nodes::InnerJoin)
  return self unless relation
  case relation
  when String, Nodes::SqlLiteral
    raise EmptyJoinError if relation.empty?
    klass = Nodes::StringJoin
  end
  @ctx.source.right << create_join(relation, nil, klass)
  self
end
```

Creates a join with nil constraint, appends to `source.right`. Constraint set separately via `on`.

### on(*exprs) -- lines 71-73

```ruby
def on(*exprs)
  @ctx.source.right.last.right = Nodes::On.new(collapse(exprs))
  self
end
```

Retroactively sets the constraint on the **last** join. The `collapse` helper wraps multiple expressions in `And`.

### outer_join(relation) -- lines 122-124

```ruby
def outer_join(relation)
  join(relation, Nodes::OuterJoin)
end
```

### join_sources -- lines 251-253

```ruby
def join_sources
  @ctx.source.right
end
```

Direct access to the joins array for manipulation.

---

## 5. Table API

**File:** `activerecord/lib/arel/table.rb`

### join(relation, klass) -- lines 38-48

Creates a `SelectManager` via `from`, then delegates to `SelectManager#join`.

### Key methods:
- `alias(name)` -- creates `TableAlias` for self-joins
- `[](name)` -- returns `Attribute` for use in ON conditions (e.g., `users[:id]`)
- `outer_join(relation)` -- convenience for `join(relation, OuterJoin)`

---

## 6. FactoryMethods

**File:** `activerecord/lib/arel/factory_methods.rb`

Included in both `Arel::Nodes::Node` and `Arel::TreeManager`:

```ruby
def create_join(to, constraint = nil, klass = Nodes::InnerJoin)
  klass.new(to, constraint)
end

def create_string_join(to)
  create_join to, nil, Nodes::StringJoin
end

def create_on(expr)
  Nodes::On.new expr
end
```

---

## 7. Visitor Pattern -- SQL Generation

### Dispatch Mechanism

**File:** `activerecord/lib/arel/visitors/visitor.rb`

```ruby
def self.dispatch_cache
  @dispatch_cache ||= Hash.new do |hash, klass|
    hash[klass] = :"visit_#{(klass.name || "").gsub("::", "_")}"
  end.compare_by_identity
end
```

Maps class names to method names. If a method is not found, walks the ancestor chain (lines 34-41) and caches the result.

Example: `LeadingJoin` has no dedicated visitor method -> walks to `InnerJoin` -> dispatches to `visit_Arel_Nodes_InnerJoin`.

### Join Visitor Methods

**File:** `activerecord/lib/arel/visitors/to_sql.rb`

**visit_Arel_Nodes_JoinSource** (lines 499-508):
```ruby
def visit_Arel_Nodes_JoinSource(o, collector)
  if o.left
    collector = visit o.left, collector      # FROM table
  end
  if o.right.any?
    collector << " " if o.left
    collector = inject_join o.right, collector, " "  # space-separated joins
  end
  collector
end
```

**visit_Arel_Nodes_InnerJoin** (lines 543-552):
```ruby
def visit_Arel_Nodes_InnerJoin(o, collector)
  collector << "INNER JOIN "
  collector = visit o.left, collector
  if o.right
    collector << " "
    visit(o.right, collector)
  else
    collector
  end
end
```

**visit_Arel_Nodes_OuterJoin** (lines 529-534): `"LEFT OUTER JOIN " + table + " " + on_clause`

**visit_Arel_Nodes_FullOuterJoin** (lines 522-527): `"FULL OUTER JOIN " + table + " " + on_clause`

**visit_Arel_Nodes_RightOuterJoin** (lines 536-541): `"RIGHT OUTER JOIN " + table + " " + on_clause`

**visit_Arel_Nodes_StringJoin** (lines 518-520): Emits only `left` (raw SQL), ignores `right`

**visit_Arel_Nodes_On** (lines 554-557): `"ON " + expr`

### PostgreSQL Overrides

**File:** `activerecord/lib/arel/visitors/postgresql.rb` (lines 118-122):

```ruby
def visit_Arel_Nodes_InnerJoin(o, collector)
  return super if o.right          # has ON -> normal INNER JOIN
  collector << "CROSS JOIN "       # no ON -> CROSS JOIN
  visit o.left, collector
end
```

---

## 8. Programmatic Arel Join API

### Basic Inner Join
```ruby
users = Arel::Table.new(:users)
posts = Arel::Table.new(:posts)
users.join(posts).on(users[:id].eq(posts[:user_id])).project(users[Arel.star])
# INNER JOIN "posts" ON "users"."id" = "posts"."user_id"
```

### Left Outer Join
```ruby
users.outer_join(posts).on(users[:id].eq(posts[:user_id]))
# or: users.join(posts, Arel::Nodes::OuterJoin).on(...)
# LEFT OUTER JOIN "posts" ON ...
```

### Self-Join with Alias
```ruby
managers = users.alias(:managers)
users.join(managers).on(users[:manager_id].eq(managers[:id]))
# INNER JOIN "users" "managers" ON "users"."manager_id" = "managers"."id"
```

### Complex ON with Multiple Conditions
```ruby
users.join(posts).on(users[:id].eq(posts[:user_id]), posts[:published].eq(true))
# ON "users"."id" = "posts"."user_id" AND "posts"."published" = TRUE
```

### Direct Node Construction
```ruby
join_node = manager.create_join(
  posts,
  manager.create_on(users[:id].eq(posts[:user_id])),
  Arel::Nodes::OuterJoin
)
manager.join_sources << join_node
```

### String Join (Raw SQL)
```ruby
users.join("JOIN posts ON posts.user_id = users.id")
# or: users.join(Arel.sql("JOIN posts ON posts.user_id = users.id"))
```

---

## 9. Key Design Patterns

1. **Metaprogramming for type hierarchy:** `Join` and `On` are dynamically created. Concrete subtypes exist in separate files with empty bodies solely for visitor dispatch.

2. **Visitor ancestor walking:** Enables subclasses like `LeadingJoin` to inherit SQL generation behavior without explicit visitor methods.

3. **Fluent builder with positional coupling:** `join()` creates the node, `on()` modifies the last node's constraint. Must be called in sequence.

4. **JoinSource breaks the Binary contract:** Its `right` is an Array, not a single node. Pragmatic choice for accumulating multiple joins.

5. **StringJoin as escape hatch:** Allows raw SQL strings. The visitor emits only the `left` (the SQL text).

6. **Collector-based generation:** The visitor doesn't build strings directly -- it appends to a collector that may handle bind parameters differently (prepared statements vs inline substitution).
