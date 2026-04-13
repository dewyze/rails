# ActiveRecord Coding Conventions: Complete Reference

## Overview

These conventions are derived from reading the actual ActiveRecord source code, recent commits, and CHANGELOG. Following these patterns produces code indistinguishable from core Rails contributors.

---

## 1. File Structure

### Every Ruby File

```ruby
# frozen_string_literal: true

require "dependency" if needed

module ActiveRecord
  class SomeClass
    # ...
  end
end
```

- `frozen_string_literal: true` is mandatory on every file
- No trailing whitespace
- No blank lines at end of file
- Single newline between method definitions
- Two newlines between class/module definitions within a file

### Module Nesting

```ruby
# Standard nesting for new classes:
module ActiveRecord
  module Associations
    class JoinDependency
      class JoinAssociation < JoinPart
        # ...
      end
    end
  end
end

# Compact form also used:
module ActiveRecord::Associations::Builder # :nodoc:
  class HasMany < CollectionAssociation # :nodoc:
  end
end
```

---

## 2. Method Definition Patterns

### Public Query Method Pattern

Every public query method on Relation follows this exact template:

```ruby
def method_name(*args)
  check_if_method_has_arguments!(__callee__, args)
  spawn.method_name!(*args)
end

def method_name!(*args) # :nodoc:
  self.method_name_values |= args
  self
end
```

The public method clones via `spawn`, the bang method mutates in-place. Always return `self` from bang methods.

### Method Visibility

```ruby
class SomeClass
  # Public methods first (no explicit `public` keyword)
  def public_method
  end

  protected
    def protected_method    # indented 2 spaces under keyword
    end

  private
    def private_method      # indented 2 spaces under keyword
    end
end
```

Rails indents method bodies under `private`/`protected` keywords. This is a distinctive Rails convention.

### Parameter Conventions

- **Keyword arguments** for options: `def method(name, scope = nil, **options)`
- **Positional args** for required values: `def initialize(base, table, associations, join_type)`
- **Splat for variable args**: `def joins(*args)`
- **Block params with &**: `def has_many(name, scope = nil, **options, &extension)`

---

## 3. Documentation Style

### Public API Documentation

```ruby
# Returns a new relation by performing a join on +args+.
#
#   User.joins(:posts)
#   # SELECT "users".* FROM "users" INNER JOIN "posts" ON "posts"."user_id" = "users"."id"
#
# You can use strings in order to customize your joins:
#
#   User.joins("LEFT JOIN bookmarks ON bookmarks.bookmarkable_type = 'Post'")
#   # SELECT "users".* FROM "users" LEFT JOIN bookmarks ON bookmarks.bookmarkable_type = 'Post'
def joins(*args)
```

Patterns:
- RDoc style with `#` comment blocks
- Method description in imperative form
- Code examples indented with 2 spaces
- SQL output shown in comments within examples
- Use `+code+` for inline code references in descriptions

### Internal Classes

```ruby
class JoinDependency # :nodoc:
  class JoinAssociation < JoinPart # :nodoc:
```

`# :nodoc:` suppresses RDoc generation for internal classes. Applied liberally to implementation details.

---

## 4. Error Handling

### Error Class Definitions

```ruby
# Centralized in errors files, not inline
module ActiveRecord
  class AssociationNotFoundError < ConfigurationError
    def initialize(record = nil, association_name = nil)
      if record && association_name
        super("Association named '#{association_name}' was not found on #{record.class.name}...")
      else
        super("Association was not found.")
      end
    end
  end
end
```

### Raising Errors

```ruby
# Use specific error classes
raise ActiveRecord::EagerLoadPolymorphicError.new(reflection)

# Guard clauses with clear messages
raise ArgumentError, "Unsupported argument type: #{opts} (#{opts.class})"

# check_if_method_has_arguments! pattern for query methods
def check_if_method_has_arguments!(method_name, args)
  if args.blank?
    raise ArgumentError, "The method .#{method_name}() must contain arguments."
  end
end
```

### Deprecation Warnings

```ruby
ActiveRecord.deprecator.warn(<<~MSG)
  Passing a column name to `sum` as a positional argument is deprecated.
  Use `sum(:column_name)` keyword argument instead.
MSG
```

---

## 5. CHANGELOG Format

**File:** `activerecord/CHANGELOG.md`

```markdown
*   Short description of the change.

    Longer explanation if needed, wrapping at ~80 characters.
    Can include multiple paragraphs.

    ```ruby
    # Code example showing the new behavior
    User.joins(:posts).where(posts: { active: true })
    ```

    *Author Name*
```

Key rules:
- Entry starts with `*   ` (asterisk, 3 spaces)
- Body indented with 4 spaces
- Code examples in fenced blocks
- Author attribution: `*Name*` (italic) on its own line
- Blank line between entries
- New entries go at the TOP of the file

---

## 6. Commit Message Style

```
Short summary in imperative mood (under 72 chars)

Optional longer description wrapping at 72 chars. Explains the "why"
not the "what". References issue numbers when applicable.
```

Examples from recent history:
- `EventReporter: filter events before building the payload`
- `Fix badly named test`
- `Use schema cache for primary key lookup during insert`
- `Fix typo ineficiently -> inefficiently [ci-skip]`

`[ci-skip]` suffix skips CI for docs-only changes.

---

## 7. Ruby Idioms

### Preferred Patterns

```ruby
# Frozen empty collections as defaults
FROZEN_EMPTY_ARRAY = [].freeze
FROZEN_EMPTY_HASH = {}.freeze

# Set union for accumulating values
self.joins_values |= args

# Case/when for type dispatch
case join
when String
  Arel::Nodes::StringJoin.new(Arel.sql(join.strip))
when Hash, Symbol, Array
  named_joins << join
when Arel::Nodes::Join
  join_nodes << join
end

# Safe navigation and conditional assignment
@type ||= compute_type

# Array() for normalizing to array
primary_keys = Array(join_primary_key)

# .zip for pairing columns
primary_keys.zip(foreign_keys).each do |pk, fk|
  # ...
end
```

### Avoided Patterns

```ruby
# DON'T use unless with else
# DO use if/else instead

# DON'T use ternary for complex expressions
# DO use if/else

# DON'T use string interpolation for SQL
# DO use Arel or sanitize_sql

# DON'T add comments for obvious code
# DO add comments only for non-obvious decisions
```

---

## 8. Class/Module Organization

### Autoload Pattern

**File:** `activerecord/lib/active_record.rb`

```ruby
module ActiveRecord
  extend ActiveSupport::Autoload

  autoload :Base
  autoload :Relation
  # ...

  module Associations
    extend ActiveSupport::Autoload

    autoload :JoinDependency
    # ...
  end
end
```

New classes must be registered in the appropriate autoload block.

### Constants

```ruby
# Define at class level, SCREAMING_SNAKE_CASE
MULTI_VALUE_METHODS = [:includes, :eager_load, :preload, :select, :group,
                       :order, :joins, :left_outer_joins, :references,
                       :extending, :unscope, :optimizer_hints, :annotate,
                       :with]
```

### Delegation

```ruby
# Use delegate for clean forwarding
delegate :table_name, :column_names, :primary_key, to: :base_klass
delegate :source_reflection, to: :reflection
```

---

## 9. What a Complete Feature PR Looks Like

When adding a new query method feature, the typical PR touches:

1. **Implementation:** `activerecord/lib/active_record/relation/query_methods.rb`
   - Add to `MULTI_VALUE_METHODS` or `SINGLE_VALUE_METHODS`
   - Define public method + bang method
   - Add private builder in `build_arel`

2. **Arel nodes (if needed):** `activerecord/lib/arel/nodes/`
   - New node class file
   - Register in `activerecord/lib/arel/nodes.rb`

3. **Visitor (if needed):** `activerecord/lib/arel/visitors/to_sql.rb`
   - Add `visit_Arel_Nodes_NewNode` method

4. **Tests:** `activerecord/test/cases/`
   - Test the public API
   - Test edge cases
   - Test SQL output
   - Test interaction with other methods

5. **CHANGELOG:** `activerecord/CHANGELOG.md`
   - New entry at top

6. **Documentation:** Inline RDoc on the new public methods

---

## 10. Anti-Patterns to Avoid

1. **Don't add unnecessary abstractions** -- Rails prefers straightforward code over clever indirection
2. **Don't add feature flags** -- just change the code
3. **Don't add backwards-compatibility shims** -- use deprecation warnings, then remove
4. **Don't add comments for obvious code** -- the code should be self-documenting
5. **Don't add type annotations** -- Rails doesn't use them
6. **Don't wrap single-use patterns in helpers** -- three similar lines are better than a premature abstraction
7. **Don't add error handling for impossible cases** -- trust the framework
8. **Don't add configuration for things that should just work** -- Rails is opinionated
