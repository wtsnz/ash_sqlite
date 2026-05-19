<!--
SPDX-FileCopyrightText: 2020 Zach Daniel

SPDX-License-Identifier: MIT
-->

# What is AshSqlite?

AshSqlite is the SQLite `Ash.DataLayer` for [Ash Framework](https://hexdocs.pm/ash). This doesn't have all of the features of [AshPostgres](https://hexdocs.pm/ash_postgres), but it does support most of the features of Ash data layers. Related `count`, `sum`, `avg`, `min`, `max`, `exists`, `first`, `list`, and `custom` aggregates can be loaded, filtered, sorted, and used in expression calculations over normal relationship paths, and over one-hop many-to-many relationships. Parent-independent unrelated aggregates are also supported. Aggregate filters and aggregate `join_filter`s are supported for those same paths when they do not depend on parent row values. `list` aggregates use SQLite JSON aggregation, and `custom` aggregates require a SQLite-compatible aggregate implementation. Full aggregate parity with AshPostgres is not available yet; unsupported cases include inline query-level `list`/`custom` aggregate expressions, unrelated aggregates that reference the parent row, manual relationships, `no_attributes?` relationships, multi-hop paths that include many-to-many relationships, parent-dependent relationship filters, parent-dependent aggregate filters, parent-dependent `join_filter`s, aggregate filters that reference other aggregates, expression sorts on `first`/`list` aggregates, `uniq` list aggregates sorted by fields other than the listed field, and fanout-prone `sum`, `avg`, or field-based `count` aggregate filters over to-many relationship references.

Use this to persist records in a SQLite table. For example, the resource below would be persisted in a table called `tweets`:

```elixir
defmodule MyApp.Tweet do
  use Ash.Resource,
    data_layer: AshSQLite.DataLayer

  attributes do
    integer_primary_key :id
    attribute :text, :string
  end

  relationships do
    belongs_to :author, MyApp.User
  end

  sqlite do
    table "tweets"
    repo MyApp.Repo
  end
end
```

The table might look like this:

| id  | text            | author_id |
| --- | --------------- | --------- |
| 1   | "Hello, world!" | 1         |

Creating records would add to the table, destroying records would remove from the table, and updating records would update the table.
