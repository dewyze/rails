# ActiveRecord Join Infrastructure: Architectural Findings

This document summarizes deep research into how ActiveRecord implements SQL JOINs, from the public API through to SQL generation. Each section links to a detailed doc for the full analysis.

---

## JOIN PIPELINE OVERVIEW

The join system is a 3-layer architecture: **Relation** (state accumulation) -> **Arel** (AST construction) -> **Visitor** (SQL generation).

Key insights:
- All query methods are lazy -- they store symbols/hashes/strings in `@values`, no SQL until `arel()` is called
- `build_join_buckets` partitions joins into 4 categories: `leading_join`, `named_join`, `stashed_join`, `join_node`
- Association names (symbols/hashes) are resolved through `JoinDependency` which builds a tree of `JoinAssociation` nodes
- `left_joins` is a pure alias for `left_outer_joins` (line 887, query_methods.rb)
- The spawn/clone pattern ensures every chain call returns a new Relation (immutability)

Full details: [docs/JOIN_PIPELINE.md](docs/JOIN_PIPELINE.md)

---

## AREL LAYER

Arel is the SQL AST library embedded in ActiveRecord. Joins are represented as a node hierarchy:

Key insights:
- `Arel::Nodes::Join` and `Arel::Nodes::On` are created via **metaprogramming** (`const_set` in binary.rb and unary.rb), not in dedicated files
- Join subtypes (`InnerJoin`, `OuterJoin`, `FullOuterJoin`, `RightOuterJoin`, `StringJoin`) exist purely for visitor dispatch -- their class bodies are empty
- `JoinSource` holds `left` (FROM table) + `right` (Array of join nodes) -- deviates from strict Binary tree
- `SelectManager#on` retroactively modifies the **last** join's constraint -- positionally coupled to `join()`
- The visitor uses class-name-to-method dispatch with ancestor-chain fallback (e.g., `LeadingJoin` falls through to `visit_Arel_Nodes_InnerJoin`)
- PostgreSQL visitor overrides `InnerJoin` to emit `CROSS JOIN` when no ON clause is present

Full details: [docs/AREL_LAYER.md](docs/AREL_LAYER.md)

---

## REFLECTION SYSTEM

Reflections are the **single source of truth** for all association metadata. Both lazy loading (AssociationScope) and eager loading (JoinDependency) use the same reflection methods.

Key insights:
- `join_primary_key` / `join_foreign_key` semantics are **reversed** between `belongs_to` and `has_many/has_one` -- the naming is from the ON clause perspective: `table[join_primary_key] = foreign_table[join_foreign_key]`
- `ThroughReflection` is a **decorator** wrapping a delegate reflection, not a subclass
- The `chain` method returns an array of reflections for multi-table through joins, processed in reverse
- `PolymorphicReflection` only exists for through associations with polymorphic sources
- Composite primary keys are fully supported via `Array()` wrapping and `.zip()` pairing throughout

Full details: [docs/REFLECTIONS.md](docs/REFLECTIONS.md)

---

## RELATION BUILDING

The Relation object is the central query builder. Its `@values` hash stores all query state.

Key insights:
- Three value categories: `MULTI_VALUE_METHODS` (arrays), `SINGLE_VALUE_METHODS` (scalars), `CLAUSE_METHODS` (value objects like WhereClause)
- Accessors are generated dynamically via `class_eval` at class-definition time
- `build_arel` assembles components in fixed order: joins, where, having, limit, offset, group, order, with, select, hints, comments, distinct, from, lock
- The spawn/clone pattern: every public method calls `spawn` (clone), then the `!` variant mutates the clone
- `merge` delegates to `Relation::Merger` which processes values in a specific order, handling same-model vs cross-model merges differently

Full details: [docs/RELATION_BUILDING.md](docs/RELATION_BUILDING.md)

---

## TESTING PATTERNS

ActiveRecord tests use Minitest with fixtures, following consistent conventions.

Key insights:
- Test classes inherit from `ActiveRecord::TestCase` which provides fixtures, query counting, and SQL capture
- Two naming styles coexist: `def test_method_name` and `test "descriptive string" do` (both are idiomatic)
- SQL assertions use `assert_queries_count`, `assert_no_queries`, `capture_sql`, and direct `to_sql` string matching
- Arel tests use Minitest::Spec style (`describe`/`it`) with `must_be_like` for whitespace-insensitive SQL comparison
- Fixtures are YAML files loaded via `fixtures :posts, :authors, :comments` declarations
- Database-specific tests use `if current_adapter?(:PostgreSQLAdapter)` guards
- Test models in `activerecord/test/models/` define real associations used across many test files

Full details: [docs/TESTING.md](docs/TESTING.md)

---

## CODING CONVENTIONS

Rails ActiveRecord follows strict conventions that make contributions recognizable.

Key insights:
- Every public query method follows the pattern: `def method(*args); check_if_method_has_arguments!; spawn.method!(*args); end`
- Private methods use 2-space indent under the `private` keyword (indented once more)
- `# :nodoc:` on internal classes/modules, RDoc with `#` comments for public API
- CHANGELOG entries: `*   Description.\n\n    Code example.\n\n    *Author Name*`
- `frozen_string_literal: true` in every file
- No trailing whitespace, no blank lines at end of file
- Deprecation warnings via `ActiveRecord.deprecator.warn`
- Error classes defined in a central errors file, not inline
- Keyword arguments for options, positional for required values

Full details: [docs/CONVENTIONS.md](docs/CONVENTIONS.md)

---

## KEY FILE INDEX

### ActiveRecord Layer
| File | Purpose |
|------|---------|
| `activerecord/lib/active_record/relation.rb` | Relation object, `@values` hash, `eager_loading?`, `to_sql` |
| `activerecord/lib/active_record/relation/query_methods.rb` | All query methods, `build_arel`, `build_joins`, `build_join_buckets` |
| `activerecord/lib/active_record/relation/spawn_methods.rb` | `spawn`, `merge`, `except`, `only` |
| `activerecord/lib/active_record/relation/merger.rb` | Cross-relation merging logic |
| `activerecord/lib/active_record/associations/join_dependency.rb` | Join tree construction, constraint generation |
| `activerecord/lib/active_record/associations/join_dependency/join_association.rb` | Per-association join node builder |
| `activerecord/lib/active_record/associations/alias_tracker.rb` | Table alias collision prevention |
| `activerecord/lib/active_record/reflection.rb` | All reflection classes, `join_scope`, `join_primary_key`/`join_foreign_key` |
| `activerecord/lib/active_record/associations.rb` | `has_many`/`has_one`/`belongs_to` macro definitions |

### Arel Layer
| File | Purpose |
|------|---------|
| `activerecord/lib/arel/nodes/binary.rb:114-123` | Defines `Join` via metaprogramming |
| `activerecord/lib/arel/nodes/unary.rb:25-42` | Defines `On` via metaprogramming |
| `activerecord/lib/arel/nodes/inner_join.rb` | `InnerJoin < Join` |
| `activerecord/lib/arel/nodes/outer_join.rb` | `OuterJoin < Join` |
| `activerecord/lib/arel/nodes/join_source.rb` | FROM + joins container |
| `activerecord/lib/arel/select_manager.rb` | `join()`, `on()`, `outer_join()`, `join_sources` |
| `activerecord/lib/arel/visitors/to_sql.rb:499-557` | Join SQL generation visitor methods |
| `activerecord/lib/arel/visitors/visitor.rb` | Dispatch mechanism with ancestor fallback |

### Test Infrastructure
| File | Purpose |
|------|---------|
| `activerecord/test/cases/associations/inner_join_association_test.rb` | Inner join tests |
| `activerecord/test/cases/associations/left_outer_join_association_test.rb` | Left join tests |
| `activerecord/test/cases/relation/merging_test.rb` | Relation merge tests |
| `activerecord/test/cases/arel/select_manager_test.rb` | Arel-level join tests |
| `activerecord/test/models/` | Test model definitions with associations |
| `activerecord/test/fixtures/` | YAML fixture data |
