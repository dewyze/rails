# ActiveRecord Testing Patterns: Complete Reference

## Overview

ActiveRecord tests use Minitest with fixtures. There are two distinct testing styles: ActiveRecord-level tests (using `ActiveRecord::TestCase`) and Arel-level tests (using `Arel::Spec` with Minitest::Spec DSL).

---

## 1. Test Infrastructure

### Base Class

**File:** `activerecord/test/cases/helper.rb`

All AR tests inherit from `ActiveRecord::TestCase`, which provides:
- Fixture loading and management
- Query counting helpers
- SQL capture helpers
- Database adapter detection
- Transaction-wrapped test isolation

### File Organization

```
activerecord/test/
  cases/                          # Test files
    associations/                 # Association-specific tests
      inner_join_association_test.rb
      left_outer_join_association_test.rb
      eager_test.rb
      ...
    relation/                     # Relation method tests
      merging_test.rb
      where_test.rb
      or_test.rb
      with_test.rb
      ...
    arel/                         # Arel-level tests
      select_manager_test.rb
      ...
    relations_test.rb             # General relation tests
  models/                         # Test model definitions
    post.rb, author.rb, comment.rb, ...
  fixtures/                       # YAML fixture data
    posts.yml, authors.yml, comments.yml, ...
  schema/                         # Test database schemas
    schema.rb
```

---

## 2. Test Class Structure

### Standard AR Test

```ruby
# frozen_string_literal: true

require "cases/helper"
require "models/author"
require "models/post"
require "models/comment"

class InnerJoinAssociationTest < ActiveRecord::TestCase
  fixtures :authors, :author_addresses, :essays, :posts, :comments, :categories,
           :categories_posts, :categorizations, :taggings, :tags

  def test_construct_finder_sql_applies_inner_join
    # Test body
  end

  def test_some_other_behavior
    # ...
  end
end
```

Key patterns:
- `require "cases/helper"` always first
- Explicit `require "models/..."` for each model used
- `fixtures :name1, :name2` declares which fixtures to load
- Methods named `def test_descriptive_name`

### Alternative Test Naming (both styles are idiomatic)

```ruby
# def-style (traditional)
def test_construct_finder_sql_applies_inner_join
  # ...
end

# test-block style (declarative)
test "construct finder sql applies inner join" do
  # ...
end
```

Both styles coexist in the codebase. The `test "string"` style is used for newer tests.

### Arel Test Style

**File:** `activerecord/test/cases/arel/select_manager_test.rb`

```ruby
require_relative "helper"

module Arel
  class SelectManagerTest < Arel::Spec
    def test_join_sources
      # def-style test
    end

    describe "join" do
      it "responds to join" do
        left      = Table.new :users
        right     = left.alias
        predicate = left[:id].eq(right[:id])
        manager   = Arel::SelectManager.new

        manager.from left
        manager.join(right).on(predicate)
        _(manager.to_sql).must_be_like %{
           SELECT FROM "users"
             INNER JOIN "users" "users_2"
               ON "users"."id" = "users_2"."id"
        }
      end
    end
  end
end
```

Arel tests use Minitest::Spec DSL (`describe`/`it`) with `must_be_like` for whitespace-insensitive SQL comparison.

---

## 3. The Five SQL Assertion Strategies

**File:** `activerecord/lib/active_record/testing/query_assertions.rb`

### Strategy 1: `assert_queries_count(n)` -- Exact query count

```ruby
author = assert_queries_count(3) {
  Author.all.merge!(includes: { posts_with_comments: :comments }).find(author_id)
}
```

### Strategy 2: `assert_no_queries` -- Zero queries (proves preload worked)

The **dominant pattern** in eager loading tests:
```ruby
post = Post.includes(:comments).joins(:comments).order("posts.id desc").to_a.first
assert_no_queries do
  assert_not_equal 0, post.comments.to_a.count
end
```

### Strategy 3: `assert_queries_match(regex)` -- SQL pattern matching

```ruby
assert_queries_match(/agents_people_2/i) do
  assert_equal [expected], Person.joins(:agents).joins(string_join)
end
```

### Strategy 4: `capture_sql` + manual inspection

```ruby
queries = capture_sql { Author.left_outer_joins(:posts).to_a }
assert queries.any? { |sql| /LEFT OUTER JOIN/i.match?(sql) }
```

`capture_sql` uses `SQLCounter` subscribed to `"sql.active_record"` notifications. Cached queries are excluded; SCHEMA queries are excluded from `log` but included in `log_all`.

### Strategy 5: `.to_sql` inspection (no execution needed)

```ruby
sql = Author.joins(:essays).to_sql
assert_match(/writer_type.*?=.*?Author/i, sql)
assert_no_match(/WHERE/i, sql)

# Also used for equivalence testing:
assert_equal Post.left_outer_joins(:comments).to_sql, Post.left_joins(:comments).to_sql
```

### Record Assertions

```ruby
def test_inner_join_returns_correct_records
  authors = Author.joins(:posts)
  assert_equal [authors(:david)], authors.where(posts: { title: "Welcome" })
end

def test_left_join_includes_unmatched
  authors = Author.left_joins(:posts)
  assert_includes authors, authors(:bob)  # bob has no posts
end
```

### Error Assertions

```ruby
def test_raises_on_invalid_join
  assert_raises(ActiveRecord::ConfigurationError) do
    Post.joins(:nonexistent_association).to_a
  end
end

def test_error_message_content
  error = assert_raises(ArgumentError) do
    Author.and({})
  end
  assert_equal(
    "You have passed Hash object to #and. Pass an ActiveRecord::Relation object instead.",
    error.message
  )
end
```

### Cross-Adapter SQL Compatibility

Tests use flexible patterns to work across SQLite3/PostgreSQL/MySQL:
```ruby
# ARTest::QUOTED_TYPE handles column quoting differences
where: "comments.body like 'Normal%' OR comments.#{ARTest::QUOTED_TYPE} = 'SpecialComment'"

# quote_table_name helper for assertions
assert_match %r(#{Regexp.escape(quote_table_name("friendships.friend_id"))}), sql

# Flexible regex for different bind parameter styles
assert queries.any? { |sql| /writer_type.*?=.*?(Author|\?|\$1|:a1)/i.match?(sql) }
```

---

## 4. Fixture Patterns

### YAML Fixtures

**File:** `activerecord/test/fixtures/posts.yml`

```yaml
welcome:
  id: 1
  author_id: 1
  title: Welcome to the weblog
  body: Such a lovely day

thinking:
  id: 2
  author_id: 1
  title: So I was thinking
  body: Like I said, I was thinking
```

### Accessing Fixtures in Tests

```ruby
def test_something
  david = authors(:david)           # load by fixture name
  david_and_mary = authors(:david, :mary)  # load multiple
  post = posts(:welcome)
end
```

### Test Models

**File:** `activerecord/test/models/post.rb` (example associations):

```ruby
class Post < ActiveRecord::Base
  belongs_to :author
  has_many :comments
  has_many :tags, through: :taggings
  has_and_belongs_to_many :categories
  # ... many more associations for testing various scenarios
end
```

Test models in `activerecord/test/models/` define **real associations** used across many test files. They are intentionally rich with associations to test edge cases.

---

## 5. Database Adapter Guards

```ruby
if current_adapter?(:PostgreSQLAdapter)
  def test_postgres_specific_behavior
    # ...
  end
end

# Or using skip:
def test_something_adapter_specific
  skip unless current_adapter?(:Mysql2Adapter)
  # ...
end
```

---

## 6. Join-Specific Test Files

### Inner Join Tests

**File:** `activerecord/test/cases/associations/inner_join_association_test.rb`

Tests cover:
- Basic `joins(:association)` SQL generation
- Nested joins (`joins(posts: :comments)`)
- String joins (`joins("JOIN ...")`)
- Joining through associations
- Deduplicate joins
- Interaction with where, order, group, distinct
- `where.associated(:assoc)` behavior

### Left Outer Join Tests

**File:** `activerecord/test/cases/associations/left_outer_join_association_test.rb`

Tests cover:
- Basic `left_joins(:association)` and `left_outer_joins(:association)`
- Alias behavior (both methods produce same SQL)
- Including records with no associated records (the key left join use case)
- `where.missing(:assoc)` behavior
- Interaction with eager loading
- Count/aggregation with left joins

### Eager Loading Tests

**File:** `activerecord/test/cases/associations/eager_test.rb`

Tests cover:
- `includes` switching between preload and eager_load
- `eager_load` always producing LEFT OUTER JOIN
- `preload` always producing separate queries
- `references` forcing eager_load path
- Nested eager loading
- Polymorphic eager loading
- Query count verification

### Merging Tests

**File:** `activerecord/test/cases/relation/merging_test.rb`

Tests cover:
- Merging joins across same model
- Merging joins across different models
- Merging left outer joins
- Where clause collapse behavior on merge

### Arel Join Tests

**File:** `activerecord/test/cases/arel/select_manager_test.rb` (lines 533-660)

Tests cover:
- `join` / `on` / `outer_join` API
- All join types (InnerJoin, OuterJoin, FullOuterJoin, RightOuterJoin)
- Nil argument (no-op)
- Empty string (EmptyJoinError)
- String joins
- Multiple joins

---

## 7. Common Test Patterns for Join Features

### Pattern 1: Verify SQL Output

```ruby
def test_joins_produces_correct_sql
  relation = Post.joins(:comments)
  assert_includes relation.to_sql, "INNER JOIN"
  assert_includes relation.to_sql, "comments"
end
```

### Pattern 2: Verify Records Returned

```ruby
def test_joins_returns_matching_records
  posts_with_comments = Post.joins(:comments).distinct
  assert_includes posts_with_comments, posts(:welcome)
  assert_not_includes posts_with_comments, posts(:authorless)
end
```

### Pattern 3: Verify Query Count

```ruby
def test_eager_load_uses_single_query
  assert_queries_count(1) do
    Post.eager_load(:comments).to_a
  end
end
```

### Pattern 4: Verify Error Handling

```ruby
def test_invalid_association_raises
  assert_raises(ActiveRecord::AssociationNotFoundError) do
    Post.joins(:fake_association).to_a
  end
end
```

### Pattern 5: Arel-level SQL Verification

```ruby
it "generates inner join SQL" do
  table = Table.new :users
  aliaz = table.alias
  manager = Arel::SelectManager.new
  manager.from left
  manager.join(right).on(predicate)
  _(manager.to_sql).must_be_like %{
    SELECT FROM "users" INNER JOIN "users" "users_2" ON "users"."id" = "users_2"."id"
  }
end
```

---

## 8. Key Testing Conventions

1. **Require models explicitly** -- every test file requires the specific models it uses
2. **Declare fixtures explicitly** -- list all needed fixtures in the class
3. **Test one behavior per method** -- clear, focused test methods
4. **Name tests descriptively** -- the name should explain what's being tested
5. **Use fixtures for data, not factories** -- Rails uses YAML fixtures throughout
6. **Verify both SQL and results** -- some tests check SQL string, others check returned records
7. **Guard adapter-specific tests** -- use `current_adapter?` or `skip`
8. **Don't test internal implementation** -- test the public API behavior
