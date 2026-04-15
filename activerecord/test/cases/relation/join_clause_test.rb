# frozen_string_literal: true

require "cases/helper"
require "models/post"
require "models/comment"
require "models/author"

class JoinClauseTest < ActiveRecord::TestCase
  fixtures :authors, :posts, :comments

  def test_inner_joins_with_on
    post_ids = Post.joins(:comments, on: { post_id: :id }).distinct.pluck(:id).sort
    expected = Comment.distinct.pluck(:post_id).sort

    assert_equal expected, post_ids
  end

  def test_inner_joins_with_on_returns_correct_count
    post = posts(:welcome)
    results = Post.joins(:comments, on: { post_id: :id }).where(id: post.id)

    assert_equal post.comments.count, results.count
  end

  def test_left_outer_joins_with_on_preserves_all_records
    posts = Post.left_outer_joins(:comments, on: { post_id: :id })

    assert_equal Post.count, posts.distinct.count
  end

  def test_left_joins_with_on_preserves_all_records
    posts = Post.left_joins(:comments, on: { post_id: :id })

    assert_equal Post.count, posts.distinct.count
  end

  def test_joins_with_on_multiple_conditions
    # Joining on both post_id and type narrows results compared to post_id alone
    broad = Post.joins(:comments, on: { post_id: :id }).count
    narrow = Post.joins(:comments, on: { post_id: :id, type: :type }).count

    assert_operator narrow, :<=, broad
  end

  def test_joins_with_on_and_alias
    sql = Post.joins(:comments, on: { post_id: :id }, as: :post_comments).to_sql

    assert_match(/post_comments/i, sql)
  end

  def test_joins_same_table_twice_with_aliases
    sql = Post.joins(:comments, on: { post_id: :id }, as: :comments_a)
              .joins(:comments, on: { post_id: :id }, as: :comments_b).to_sql

    assert_match(/comments_a/i, sql)
    assert_match(/comments_b/i, sql)
  end

  def test_joins_with_subquery_returns_correct_records
    welcome_comments = Comment.where("comments.body LIKE '%welcome%'")
    post_ids = Post.joins(welcome_comments, on: { post_id: :id }, as: :welcome_comments)
                   .distinct.pluck(:id).sort

    expected_ids = Comment.where("body LIKE '%welcome%'").distinct.pluck(:post_id).sort
    assert_equal expected_ids, post_ids
  end

  def test_left_outer_joins_with_subquery_preserves_all_records
    active_comments = Comment.where("comments.body LIKE '%welcome%'")
    posts = Post.left_outer_joins(active_comments, on: { post_id: :id }, as: :welcome_comments)

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
    results = Post.joins(:author).joins(:comments, on: { post_id: :id })

    assert_not_empty results
  end

  def test_joins_with_on_does_not_interfere_with_association_hash_joins
    results = Post.joins(comments: :post)

    assert_not_empty results
  end
end
