# frozen_string_literal: true

require "cases/helper"
require "models/post"
require "models/comment"
require "models/author"

module ActiveRecord
  class JoinClauseTest < ActiveRecord::TestCase
    fixtures :authors, :posts, :comments

    def test_inner_joins_with_on
      posts = Post.joins(:comments, on: { post_id: :id })

      assert_includes posts.to_sql, "INNER JOIN"
      assert_includes posts.to_sql, %("comments"."post_id" = "posts"."id")
      assert_equal posts.distinct.pluck(:id).sort, Comment.distinct.pluck(:post_id).sort
    end

    def test_inner_joins_with_on_returns_correct_records
      post = posts(:welcome)
      results = Post.joins(:comments, on: { post_id: :id }).where(id: post.id)

      assert_equal post.comments.count, results.count
    end

    def test_left_outer_joins_with_on
      posts = Post.left_outer_joins(:comments, on: { post_id: :id })

      assert_includes posts.to_sql, "LEFT OUTER JOIN"
      assert_includes posts.to_sql, %("comments"."post_id" = "posts"."id")
      # LEFT JOIN preserves posts without comments
      assert_equal Post.count, posts.distinct.count
    end

    def test_left_joins_with_on
      posts = Post.left_joins(:comments, on: { post_id: :id })

      assert_includes posts.to_sql, "LEFT OUTER JOIN"
      assert_equal Post.count, posts.distinct.count
    end

    def test_joins_with_on_multiple_conditions
      posts = Post.joins(:comments, on: { post_id: :id, type: :type })

      sql = posts.to_sql
      assert_includes sql, %("comments"."post_id" = "posts"."id")
      assert_includes sql, %("comments"."type" = "posts"."type")
    end

    def test_joins_with_on_and_alias
      posts = Post.joins(:comments, on: { post_id: :id }, as: :post_comments)

      sql = posts.to_sql
      assert_includes sql, %("post_comments")
      assert_includes sql, %("post_comments"."post_id" = "posts"."id")
    end

    def test_joins_same_table_twice_with_aliases
      posts = Post.joins(:comments, on: { post_id: :id }, as: :comments_a)
                   .joins(:comments, on: { post_id: :id }, as: :comments_b)

      sql = posts.to_sql
      assert_includes sql, %("comments_a")
      assert_includes sql, %("comments_b")
    end

    def test_joins_with_subquery
      active_comments = Comment.where("comments.body LIKE '%welcome%'")
      posts = Post.joins(active_comments, on: { post_id: :id }, as: :welcome_comments)

      sql = posts.to_sql
      assert_includes sql, "INNER JOIN"
      assert_includes sql, %("welcome_comments")
      assert_includes sql, %("welcome_comments"."post_id" = "posts"."id")
    end

    def test_joins_with_subquery_returns_correct_records
      welcome_comments = Comment.where("comments.body LIKE '%welcome%'")
      post_ids = Post.joins(welcome_comments, on: { post_id: :id }, as: :welcome_comments)
                     .distinct.pluck(:id).sort

      expected_ids = Comment.where("body LIKE '%welcome%'").distinct.pluck(:post_id).sort
      assert_equal expected_ids, post_ids
    end

    def test_left_outer_joins_with_subquery
      active_comments = Comment.where("comments.body LIKE '%welcome%'")
      posts = Post.left_outer_joins(active_comments, on: { post_id: :id }, as: :welcome_comments)

      sql = posts.to_sql
      assert_includes sql, "LEFT OUTER JOIN"
      assert_includes sql, %("welcome_comments")
      # LEFT JOIN preserves all posts
      assert_equal Post.count, posts.distinct.count
    end

    def test_joins_with_subquery_requires_alias
      error = assert_raises(ArgumentError) do
        Post.joins(Comment.where(post_id: 1), on: { post_id: :id }).to_sql
      end

      assert_match(/alias.*required/i, error.message)
    end

    def test_joins_with_on_requires_hash
      error = assert_raises(ArgumentError) do
        Post.joins(:comments, on: "invalid").to_sql
      end

      assert_match(/must be a Hash/, error.message)
    end

    def test_joins_with_on_requires_single_source
      error = assert_raises(ArgumentError) do
        Post.joins(:comments, :authors, on: { post_id: :id }).to_sql
      end

      assert_match(/expected exactly one/, error.message)
    end

    def test_joins_with_on_and_where
      results = Post.joins(:comments, on: { post_id: :id })
                     .where(comments: { body: "Thank you for the welcome" })

      assert_not_empty results
      results.each do |post|
        assert post.comments.any? { |c| c.body == "Thank you for the welcome" }
      end
    end

    def test_joins_with_on_and_select
      results = Post.joins(:comments, on: { post_id: :id })
                     .select("posts.*, comments.body AS comment_body")

      assert_not_empty results
      assert_respond_to results.first, :comment_body
    end

    def test_joins_with_on_chained_with_association_joins
      results = Author.joins(:posts)
                       .joins(:comments, on: { post_id: :id })

      sql = results.to_sql
      # Association join
      assert_match(/"posts"\."author_id" = "authors"\."id"/, sql)
      # Explicit ON join
      assert_includes sql, %("comments"."post_id" = "authors"."id")
    end
  end
end
