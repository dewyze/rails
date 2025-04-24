# frozen_string_literal: true

require "cases/helper"
require "models/post"
require "models/comment"
require "models/author"
require "models/categorization"
require "models/category"
require "models/developer"
require "models/computer"
require "models/project"
require "models/company"
require "models/topic"
require "models/reply"
require "models/person"

module ActiveRecord
  class JoinsOnTest < ActiveRecord::TestCase
    fixtures :authors, :author_addresses, :posts, :comments, :developers, :projects, :developers_projects
    
    def test_joins_on_with_table_name
      author_count = Author.count
      
      # Join with table name and explicit ON condition
      relation = Author.joins_on(:posts, on: { id: :author_id })
      
      assert_equal author_count, relation.count
      assert_match(/INNER JOIN "posts" ON "authors"."id" = "posts"."author_id"/, relation.to_sql)
    end
    
    def test_joins_on_with_table_alias
      author_count = Author.count
      
      # Join with table name, explicit alias and ON condition
      relation = Author.joins_on(:posts, as: "authored_posts", on: { id: :author_id })
      
      assert_equal author_count, relation.count
      assert_match(/INNER JOIN "posts" AS authored_posts ON "authors"."id" = "authored_posts"."author_id"/, relation.to_sql)
    end
    
    def test_joins_on_with_subquery
      published_posts = Post.where(published: true)
      author_count = Author.joins(:posts).where(posts: { published: true }).count
      
      # Join with subquery and condition
      relation = Author.joins_on(published_posts, on: { id: :author_id })
      
      assert_equal author_count, relation.count
      assert_match(/INNER JOIN \(SELECT .*FROM "posts".*WHERE "posts"."published" = (?:|'t'|TRUE)\) ON "authors"."id" = "(?:_subselect_1|subquery)"."author_id"/, relation.to_sql)
    end
    
    def test_joins_on_with_named_subquery
      published_posts = Post.where(published: true)
      author_count = Author.joins(:posts).where(posts: { published: true }).count
      
      # Join with subquery, alias and condition
      relation = Author.joins_on(published_posts, as: "published_posts", on: { id: :author_id })
      
      assert_equal author_count, relation.count
      assert_match(/INNER JOIN \(SELECT .*FROM "posts".*WHERE "posts"."published" = (?:|'t'|TRUE)\) AS published_posts ON "authors"."id" = "published_posts"."author_id"/, relation.to_sql)
    end
    
    def test_joins_on_with_left_outer_join
      # There should be more authors than authors with posts
      authors_with_posts = Author.joins(:posts).distinct.count
      all_authors = Author.count
      assert_operator all_authors, :>, authors_with_posts, "Test requires some authors without posts"
      
      # Left outer join should include all authors
      relation = Author.joins_on(:posts, on: { id: :author_id }, type: :left)
      assert_equal all_authors, relation.distinct.count
      assert_match(/LEFT OUTER JOIN "posts" ON "authors"."id" = "posts"."author_id"/, relation.to_sql)
    end
    
    def test_joins_on_with_multiple_conditions
      relation = Author.joins_on(:posts, 
        on: { id: :author_id, name: :title }, # Nonsensical but tests multiple conditions
        type: :left)
        
      assert_match(/LEFT OUTER JOIN "posts" ON "authors"."id" = "posts"."author_id" AND "authors"."name" = "posts"."title"/, relation.to_sql)
    end
    
    def test_joins_on_without_conditions_raises_error
      assert_raises(ArgumentError) do
        Author.joins_on(:posts).to_a
      end
    end
    
    def test_joins_on_with_invalid_condition_format_raises_error
      assert_raises(ArgumentError) do
        Author.joins_on(:posts, on: "invalid").to_a
      end
    end
    
    def test_chaining_multiple_joins_on
      relation = Author.joins_on(:posts, as: "authored_posts", on: { id: :author_id })
                      .joins_on(:comments, as: "post_comments", on: { id: :author_id })
      
      sql = relation.to_sql
      assert_match(/INNER JOIN "posts" AS authored_posts/, sql)
      assert_match(/INNER JOIN "comments" AS post_comments/, sql)
    end
  end
end