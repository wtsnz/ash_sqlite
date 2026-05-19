# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.AggregatesTest do
  use AshSqlite.RepoCase, async: false

  require Ash.Query
  alias AshSqlite.Test.{Comment, Post, PostLink}

  test "a count with a filter returns the appropriate value" do
    Ash.Seed.seed!(%Post{title: "foo"})
    Ash.Seed.seed!(%Post{title: "foo"})
    Ash.Seed.seed!(%Post{title: "bar"})

    count =
      Post
      |> Ash.Query.filter(title == "foo")
      |> Ash.count!()

    assert count == 2
  end

  test "pagination returns the count" do
    Ash.Seed.seed!(%Post{title: "foo"})
    Ash.Seed.seed!(%Post{title: "foo"})
    Ash.Seed.seed!(%Post{title: "bar"})

    Post
    |> Ash.Query.page(offset: 1, limit: 1, count: true)
    |> Ash.Query.for_read(:paginated)
    |> Ash.read!()
  end

  test "related scalar aggregates can be loaded" do
    post = create_post!("loaded")
    empty_post = create_post!("empty")

    create_comment!(post, "match", 1)
    create_comment!(post, "other", 4)
    create_comment!(post, "other", 10)

    loaded_post =
      post
      |> Ash.load!([
        :count_of_comments,
        :count_of_popular_comments,
        :count_of_comments_called_match,
        :sum_of_comment_likes,
        :avg_comment_likes,
        :min_comment_likes,
        :max_comment_likes,
        :has_comment_called_match
      ])

    assert loaded_post.count_of_comments == 3
    assert loaded_post.count_of_popular_comments == 0
    assert loaded_post.count_of_comments_called_match == 1
    assert loaded_post.sum_of_comment_likes == 15
    assert loaded_post.avg_comment_likes == 5.0
    assert loaded_post.min_comment_likes == 1
    assert loaded_post.max_comment_likes == 10
    assert loaded_post.has_comment_called_match == true

    empty_post =
      empty_post
      |> Ash.load!([
        :count_of_comments,
        :sum_of_comment_likes,
        :avg_comment_likes,
        :has_comment_called_match
      ])

    assert empty_post.count_of_comments == 0
    assert empty_post.sum_of_comment_likes == nil
    assert empty_post.avg_comment_likes == nil
    assert empty_post.has_comment_called_match == false

    assert [
             %Post{title: "empty", count_of_comments: 0},
             %Post{title: "loaded", count_of_comments: 3}
           ] =
             Post
             |> Ash.Query.load(:count_of_comments)
             |> Ash.Query.sort(:title)
             |> Ash.read!()
  end

  test "relationship filters are applied to loaded aggregates" do
    post = create_post!("relationship filter")

    create_comment!(post, "quiet", 1)
    create_comment!(post, "popular", 11)

    assert %{count_of_popular_comments: 1} =
             Ash.load!(post, :count_of_popular_comments)
  end

  test "resource queries can sort by related aggregates" do
    one_comment = create_post!("one comment")
    two_comments = create_post!("two comments")
    no_comments = create_post!("no comments")

    create_comment!(one_comment, "only", 1)
    create_comment!(two_comments, "first", 1)
    create_comment!(two_comments, "second", 1)

    assert [
             %Post{id: two_comments_id, count_of_comments: 2},
             %Post{id: one_comment_id, count_of_comments: 1},
             %Post{id: no_comments_id, count_of_comments: 0}
           ] =
             Post
             |> Ash.Query.load(:count_of_comments)
             |> Ash.Query.sort(count_of_comments: :desc)
             |> Ash.read!()

    assert two_comments_id == two_comments.id
    assert one_comment_id == one_comment.id
    assert no_comments_id == no_comments.id
  end

  test "aggregate sorting works with pagination and aggregate filters" do
    one_comment = create_post!("one comment")
    two_comments = create_post!("two comments")
    three_comments = create_post!("three comments")
    create_post!("no comments")

    create_comment!(one_comment, "only", 1)
    create_comment!(two_comments, "first", 1)
    create_comment!(two_comments, "second", 1)
    create_comment!(three_comments, "first", 1)
    create_comment!(three_comments, "second", 1)
    create_comment!(three_comments, "third", 1)

    assert [%Post{id: two_comments_id, count_of_comments: 2}] =
             Post
             |> Ash.Query.load(:count_of_comments)
             |> Ash.Query.filter(count_of_comments > 0)
             |> Ash.Query.sort(count_of_comments: :desc)
             |> Ash.Query.limit(1)
             |> Ash.Query.offset(1)
             |> Ash.read!()

    assert two_comments_id == two_comments.id
  end

  test "resource queries can filter on related aggregates" do
    post = create_post!("with comments")
    create_comment!(post, "match", 1)
    create_comment!(post, "other", 1)

    create_post!("without comments")

    assert [%Post{id: post_id, count_of_comments: 2}] =
             Post
             |> Ash.Query.load(:count_of_comments)
             |> Ash.Query.filter(count_of_comments > 1)
             |> Ash.read!()

    assert post_id == post.id
  end

  test "calculations can reference related aggregates" do
    post = create_post!("with aggregate calculation", %{score: 3})
    empty_post = create_post!("without aggregate calculation", %{score: 7})

    create_comment!(post, "first", 4)
    create_comment!(post, "second", 6)

    assert [
             %Post{
               id: post_id,
               has_comments: true,
               comment_likes_with_score: 13
             },
             %Post{
               id: empty_post_id,
               has_comments: false,
               comment_likes_with_score: 7
             }
           ] =
             Post
             |> Ash.Query.load([:has_comments, :comment_likes_with_score])
             |> Ash.Query.sort(comment_likes_with_score: :desc)
             |> Ash.read!()

    assert post_id == post.id
    assert empty_post_id == empty_post.id
  end

  test "many_to_many scalar aggregates can be loaded" do
    source = create_post!("source", %{score: 5})
    match = create_post!("match", %{score: 2})
    other = create_post!("other", %{score: 6})
    archived = create_post!("archived", %{score: 20})
    empty = create_post!("empty", %{score: 1})

    link_posts!(source, [match, other])
    create_post_link!(source, archived, :archived)

    loaded_source =
      Ash.load!(source, [
        :count_of_linked_posts,
        :sum_of_linked_post_scores,
        :avg_linked_post_score,
        :min_linked_post_score,
        :max_linked_post_score,
        :has_linked_post_called_match
      ])

    assert loaded_source.count_of_linked_posts == 2
    assert loaded_source.sum_of_linked_post_scores == 8
    assert loaded_source.avg_linked_post_score == 4.0
    assert loaded_source.min_linked_post_score == 2
    assert loaded_source.max_linked_post_score == 6
    assert loaded_source.has_linked_post_called_match == true

    loaded_empty =
      Ash.load!(empty, [
        :count_of_linked_posts,
        :sum_of_linked_post_scores,
        :avg_linked_post_score,
        :has_linked_post_called_match
      ])

    assert loaded_empty.count_of_linked_posts == 0
    assert loaded_empty.sum_of_linked_post_scores == nil
    assert loaded_empty.avg_linked_post_score == nil
    assert loaded_empty.has_linked_post_called_match == false
  end

  test "many_to_many aggregates can be filtered, sorted and used in calculations" do
    one_link = create_post!("one link", %{score: 1})
    two_links = create_post!("two links", %{score: 2})
    no_links = create_post!("no links", %{score: 3})

    linked_a = create_post!("linked a", %{score: 4})
    linked_b = create_post!("linked b", %{score: 5})

    link_posts!(one_link, [linked_a])
    link_posts!(two_links, [linked_a, linked_b])

    assert [
             %Post{
               id: two_links_id,
               count_of_linked_posts: 2,
               linked_post_score_with_score: 11
             },
             %Post{
               id: one_link_id,
               count_of_linked_posts: 1,
               linked_post_score_with_score: 5
             }
           ] =
             Post
             |> Ash.Query.load([
               :count_of_linked_posts,
               :linked_post_score_with_score
             ])
             |> Ash.Query.filter(count_of_linked_posts > 0)
             |> Ash.Query.sort(count_of_linked_posts: :desc)
             |> Ash.read!()

    assert two_links_id == two_links.id
    assert one_link_id == one_link.id

    assert %{linked_post_score_with_score: 3} =
             Ash.load!(no_links, :linked_post_score_with_score)
  end

  defp create_post!(title, attrs \\ %{}) do
    Post
    |> Ash.Changeset.for_create(:create, Map.put(attrs, :title, title))
    |> Ash.create!()
  end

  defp create_comment!(post, title, likes) do
    Comment
    |> Ash.Changeset.for_create(:create, %{title: title, likes: likes})
    |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
    |> Ash.create!()
  end

  defp link_posts!(source, destinations) do
    source
    |> Ash.Changeset.new()
    |> Ash.Changeset.manage_relationship(:linked_posts, destinations, type: :append_and_remove)
    |> Ash.update!()
  end

  defp create_post_link!(source, destination, state) do
    PostLink
    |> Ash.Changeset.new()
    |> Ash.Changeset.change_attribute(:state, state)
    |> Ash.Changeset.manage_relationship(:source_post, source, type: :append)
    |> Ash.Changeset.manage_relationship(:destination_post, destination, type: :append)
    |> Ash.create!()
  end
end
