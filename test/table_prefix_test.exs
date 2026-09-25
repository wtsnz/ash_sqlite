# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.TablePrefixTest do
  @moduledoc """
  SQLite has no table prefixes, so a schema in a relationship's context must
  not become one.
  """
  use AshSqlite.RepoCase, async: false

  require Ash.Query

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered?(true)
    end
  end

  defmodule Comment do
    use Ash.Resource, domain: Domain, data_layer: AshSqlite.DataLayer

    sqlite do
      table("comments")
      repo(AshSqlite.TestRepo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:post_id, :uuid)
      attribute(:title, :string)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule Post do
    use Ash.Resource, domain: Domain, data_layer: AshSqlite.DataLayer

    sqlite do
      table("posts")
      repo(AshSqlite.TestRepo)
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read])
    end

    relationships do
      has_many :comments, Comment do
        destination_attribute(:post_id)
        relationship_context(%{data_layer: %{schema: "main"}})
      end
    end
  end

  test "a relationship's schema context doesn't become a table prefix" do
    post = Ash.Seed.seed!(%AshSqlite.Test.Post{title: "post"})
    Ash.Seed.seed!(%AshSqlite.Test.Comment{post_id: post.id, title: "expected"})

    assert [%{id: id}] = Post |> Ash.Query.filter(comments.title == "expected") |> Ash.read!()
    assert id == post.id
  end
end
