# ActiveRecord Reflection System: Complete Technical Reference

## Overview

Reflections are the **single source of truth** for all association metadata. They determine foreign keys, table names, join conditions, and class names. Both lazy loading (`post.comments`) and eager loading (`Post.joins(:comments)`) call back into the same reflection methods.

---

## 1. Reflection Class Hierarchy

**File:** `activerecord/lib/active_record/reflection.rb`

```
AbstractReflection                    (line 60)
  MacroReflection                     (line 369)
    AssociationReflection             (line 493)
      HasManyReflection               (line 900)
      HasOneReflection                (line 914)
      BelongsToReflection             (line 928)
      HasAndBelongsToManyReflection   (line 978)
  ThroughReflection                   (line 988) -- DECORATOR, not subclass of AssociationReflection
  PolymorphicReflection               (line 1271)
  RuntimeReflection                   (line 1301)
```

### Builder Hierarchy (separate from Reflections)

```
Builder::Association                  # Base builder
  Builder::SingularAssociation        # has_one, belongs_to
    Builder::BelongsTo
    Builder::HasOne
  Builder::CollectionAssociation      # has_many
    Builder::HasMany
    Builder::HasAndBelongsToMany
```

---

## 2. How Associations Create Reflections

When you write `has_many :comments`:

**Step 1:** Macro method (`associations.rb`, line 1427):
```ruby
def has_many(name, scope = nil, **options, &extension)
  reflection = Builder::HasMany.build(self, name, scope, options, &extension)
  Reflection.add_reflection(self, name, reflection)
end
```

**Step 2:** Builder.build (`builder/association.rb`, line 25):
```ruby
def self.build(model, name, scope, options, &block)
  reflection = create_reflection(model, name, scope, options, &block)
  define_accessors(model, reflection)
  define_callbacks(model, reflection)
  define_validations(model, reflection)
  define_change_tracking_methods(model, reflection)
  reflection
end
```

**Step 3:** Reflection.create (`reflection.rb`, line 18):
```ruby
def self.create(macro, name, scope, options, ar)
  reflection = reflection_class_for(macro).new(name, scope, options, ar)
  options[:through] ? ThroughReflection.new(reflection) : reflection
end
```

**Critical:** If `options[:through]` is present, the concrete reflection is **wrapped** in a `ThroughReflection`. So `has_many :tags, through: :taggings` creates a `ThroughReflection` whose `@delegate_reflection` is a `HasManyReflection`.

**Step 4:** Registration (`reflection.rb`, line 23):
```ruby
def self.add_reflection(ar, name, reflection)
  ar.clear_reflections_cache
  ar._reflections = ar._reflections.except(name).merge!(name => reflection)
end
```

Stored in the `_reflections` class attribute (a frozen hash per class).

---

## 3. Core Reflection Attributes

### MacroReflection (line 369)
- `@name` -- association name (`:comments`)
- `@scope` -- optional lambda for additional conditions
- `@options` -- options hash (`:foreign_key`, `:class_name`, `:through`, `:as`, etc.)
- `@active_record` -- the declaring class (`Post`)

### AssociationReflection (line 493)
- `@type` -- for polymorphic `has_many :as` (e.g., `"commentable_type"`)
- `@foreign_type` -- for polymorphic `belongs_to` (e.g., `"commentable_type"`)
- `@foreign_key` -- lazily computed, memoized

### Key Computed Properties

**`foreign_key`** (line 562): Priority:
1. `options[:foreign_key]` if explicit
2. `options[:query_constraints]` if set
3. `derive_foreign_key` (line 843):
   - `belongs_to`: `"#{name}_id"`
   - `has_many :as`: `"#{options[:as]}_id"`
   - Otherwise: `active_record.model_name.to_s.foreign_key`

**`klass`** (line 422): Lazily resolved via `compute_class(class_name)`. `class_name` comes from `options[:class_name]` or camelized association name.

---

## 4. The join_primary_key / join_foreign_key System

This is the **critical interface** for building ON clauses. The semantics differ by association type.

### For has_many / has_one (AssociationReflection, lines 614-624):
```ruby
def join_primary_key(klass = nil)
  foreign_key          # e.g., "post_id" (on the JOINED table)
end
def join_foreign_key
  active_record_primary_key  # e.g., "id" (on the OWNER table)
end
```

### For belongs_to (BelongsToReflection, lines 960-966):
```ruby
def join_primary_key(klass = nil)
  polymorphic? ? association_primary_key(klass) : association_primary_key
  # e.g., "id" (on the JOINED table)
end
def join_foreign_key
  foreign_key    # e.g., "post_id" (on the OWNER table)
end
```

### The ON Clause Formula

In `AbstractReflection#join_scope` (line 200):
```ruby
klass_scope.where!(table[join_primary_key].eq(foreign_table[join_foreign_key]))
```

This always produces: `joined_table.join_primary_key = owner_table.join_foreign_key`

| Association | join_primary_key | join_foreign_key | ON clause |
|-------------|-----------------|------------------|-----------|
| `Post has_many :comments` | `post_id` (on comments) | `id` (on posts) | `comments.post_id = posts.id` |
| `Comment belongs_to :post` | `id` (on posts) | `post_id` (on comments) | `posts.id = comments.post_id` |

---

## 5. join_scope -- Building ON Conditions

**File:** `activerecord/lib/active_record/reflection.rb`, lines 200-225

```ruby
def join_scope(table, foreign_table, foreign_klass)
  predicate_builder = klass.predicate_builder.with(TableMetadata.new(klass, table))
  scope_chain_items = join_scopes(table, predicate_builder)      # user-defined scopes
  klass_scope       = klass_join_scope(table, predicate_builder)  # default scope

  if type
    klass_scope.where!(type => foreign_klass.polymorphic_name)    # polymorphic type
  end

  scope_chain_items.inject(klass_scope, &:merge!)

  # PK = FK equality
  primary_key_column_names = Array(join_primary_key)
  foreign_key_column_names = Array(join_foreign_key)
  primary_key_column_names.zip(foreign_key_column_names).each do |pk, fk|
    klass_scope.where!(table[pk].eq(foreign_table[fk]))
  end

  # STI type condition
  if klass.finder_needs_type_condition?
    klass_scope.where!(klass.send(:type_condition, table))
  end

  klass_scope
end
```

Produces conditions like:
```sql
ON comments.post_id = posts.id
   [AND comments.type = 'Comment']          -- STI
   [AND comments.commentable_type = 'Post'] -- polymorphic
   [AND <scope conditions>]                  -- user scope
```

---

## 6. ThroughReflection -- The Decorator Pattern

**File:** `activerecord/lib/active_record/reflection.rb`, line 988

A `ThroughReflection` wraps a delegate reflection. Key navigational methods:

```ruby
def through_reflection
  active_record._reflect_on_association(options[:through])
end

def source_reflection
  through_reflection.klass._reflect_on_association(source_reflection_name)
end
```

### Delegation (line 989):
```ruby
delegate :foreign_key, :foreign_type, :association_foreign_key,
         :join_id_for, :type, :active_record_primary_key,
         :join_foreign_key, to: :source_reflection
```

### Chain Building -- collect_join_chain (line 1067)

For `Post has_many :tags, through: :taggings`:
```ruby
chain = [ThroughReflection(:tags), HasManyReflection(:taggings)]
```

For nested through associations, the chain recurses deeper via `collect_join_reflections` (line 1236).

### Chain Processing in JoinAssociation

The chain is **reversed** for join construction (JoinAssociation line 43):
- First join: taggings -> `taggings.post_id = posts.id`
- Then join: tags -> `tags.id = taggings.tag_id`

Result:
```sql
INNER JOIN taggings ON taggings.post_id = posts.id
INNER JOIN tags ON tags.id = taggings.tag_id
```

---

## 7. Polymorphic Association Handling

### Polymorphic belongs_to (`belongs_to :commentable, polymorphic: true`):
- `polymorphic?` returns true
- `klass` cannot be computed statically
- `join_primary_key` takes a runtime `klass` argument

### Polymorphic has_many :as (`has_many :comments, as: :commentable`):
- `@type` set to `"commentable_type"`
- In `join_scope`: adds `WHERE commentable_type = 'Post'`
- `derive_foreign_key` returns `"commentable_id"`

### PolymorphicReflection (line 1271):
Only for through associations with polymorphic sources. Injects `source_type_scope`:
```ruby
def source_type_scope
  type = @previous_reflection.foreign_type
  source_type = @previous_reflection.options[:source_type]
  lambda { |object| where(type => source_type) }
end
```

---

## 8. AssociationScope -- Runtime Loading

**File:** `activerecord/lib/active_record/associations/association_scope.rb`

Used for lazy loading (`post.comments`), not eager loading. Builds scope using the reflection chain:

- `last_chain_scope`: For the final link, binds actual FK value from the owner record
- `next_chain_scope`: For intermediate links (through associations), creates table equality conditions

---

## 9. Complete Data Flow

```
1. BOOT TIME: has_many :comments
   -> Builder::HasMany.build(Post, :comments, nil, {})
   -> HasManyReflection.new(:comments, nil, {}, Post)
   -> Stored in Post._reflections[:comments]

2. QUERY TIME: Post.joins(:comments)
   -> joins_values << :comments
   -> build_join_buckets: :comments -> named_joins
   -> construct_join_dependency([:comments], InnerJoin)
   -> JoinDependency: JoinBase(Post) -> JoinAssociation(comments)

3. JOIN GENERATION:
   -> JoinAssociation#join_constraints(posts_table, Post, InnerJoin, tracker)
   -> reflection.chain -> [HasManyReflection(:comments)]
   -> reflection.join_scope(comments_table, posts_table, Post)
     -> where!(comments_table[:post_id].eq(posts_table[:id]))
   -> InnerJoin.new(comments_table, On.new(constraints))

4. RESULT: INNER JOIN "comments" ON "comments"."post_id" = "posts"."id"
```

---

## 10. Key Design Observations

1. **Reflection is the single source of truth.** Both lazy and eager loading use the same `join_primary_key`/`join_foreign_key` methods.

2. **join_primary_key / join_foreign_key are semantically reversed** between belongs_to and has_many. The naming is from the ON clause perspective.

3. **ThroughReflection is a decorator**, not a subclass. It wraps a delegate reflection and provides chain-building.

4. **Composite PKs supported throughout** via `Array()` wrapping and `.zip()` pairing.

5. **The chain is always processed in reverse** in JoinAssociation -- closest to owner first, target last.
