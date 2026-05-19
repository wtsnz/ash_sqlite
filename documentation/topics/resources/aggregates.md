<!--
SPDX-FileCopyrightText: 2020 Zach Daniel

SPDX-License-Identifier: MIT
-->

# Aggregates

AshSqlite supports resource aggregates that can be loaded, filtered, sorted, and used in expression calculations. For general Ash aggregate usage, see the [Ash aggregates guide](https://hexdocs.pm/ash/aggregates.html).

## Supported Aggregates

AshSqlite supports related `count`, `sum`, `avg`, `min`, `max`, `exists`, `first`, `list`, and `custom` aggregates over normal relationship paths.

```elixir
aggregates do
  count :total_tickets, :tickets
  exists :has_open_tickets, :tickets do
    filter expr(status == :open)
  end

  first :latest_ticket_subject, :tickets, :subject do
    sort inserted_at: :desc
  end

  list :ticket_subjects, :tickets, :subject do
    sort inserted_at: :desc
  end
end
```

Aggregates are translated to SQL and can be used in queries.

```elixir
require Ash.Query

Helpdesk.Support.Representative
|> Ash.Query.filter(total_tickets > 2)
|> Ash.Query.sort(total_tickets: :desc)
|> Ash.Query.load([:total_tickets, :latest_ticket_subject])
|> Ash.read!()
```

Aggregates can also be loaded on records that have already been read.

```elixir
representatives = Helpdesk.Support.read!(Helpdesk.Support.Representative)

Ash.load!(representatives, [:total_tickets, :ticket_subjects])
```

## Calculations

Expression calculations can reference aggregates and be pushed down to SQLite.

```elixir
aggregates do
  count :total_tickets, :tickets

  count :open_tickets, :tickets do
    filter expr(status == :open)
  end
end

calculations do
  calculate :percent_open, :float, expr(open_tickets / total_tickets)
end
```

Calculations that reference aggregates can be loaded, filtered, and sorted in the same way.

```elixir
require Ash.Query

Helpdesk.Support.Representative
|> Ash.Query.filter(percent_open > 0.25)
|> Ash.Query.sort(:percent_open)
|> Ash.Query.load(:percent_open)
|> Ash.read!()
```

## Relationship Paths

Aggregates are supported over normal relationship paths, including multi-hop paths.

```elixir
aggregates do
  count :comment_count, [:posts, :comments]
  sum :paid_total, [:orders, :payments], :amount
end
```

One-hop many-to-many relationship aggregates are supported.

```elixir
aggregates do
  count :linked_post_count, :linked_posts

  first :latest_linked_post_title, :linked_posts, :title do
    sort inserted_at: :desc
  end
end
```

Parent-independent unrelated aggregates are supported when the aggregate query does not need values from the parent row.

```elixir
aggregates do
  count :published_post_count, Post do
    filter expr(published == true)
  end
end
```

## Aggregate Filters

Aggregate filters and aggregate `join_filter`s are supported for normal paths and one-hop many-to-many paths when they do not depend on parent row values.

```elixir
aggregates do
  count :open_ticket_count, :tickets do
    filter expr(status == :open)
  end

  count :matching_ticket_count, :tickets do
    join_filter :tickets, expr(priority == :high)
  end
end
```

## SQLite Requirements

`first` and `list` aggregates use SQLite features that are available in modern SQLite versions:

- window functions
- aggregate `FILTER`
- JSON aggregation
- explicit null ordering

`list` aggregates return lists through SQLite JSON aggregation. `custom` aggregates require a SQLite-compatible aggregate expression or function.

## Performance

AshSqlite builds aggregate queries as grouped subqueries or windowed subqueries and joins those results back to the parent query. Add indexes for the relationship keys used by those subqueries.

Useful indexes usually include:

- child foreign keys, like `tickets.representative_id`
- many-to-many join resource key pairs
- fields used by aggregate filters
- fields used by `first` and `list` aggregate sorts

## Unsupported Cases

Full aggregate parity with [AshPostgres](https://hexdocs.pm/ash_postgres) is not available. Unsupported cases include:

- inline query-level `list` and `custom` aggregate expressions
- unrelated aggregates that reference the parent row
- manual relationships
- `no_attributes?` relationships
- multi-hop paths that include many-to-many relationships
- parent-dependent relationship filters
- parent-dependent aggregate filters
- parent-dependent `join_filter`s
- aggregate filters that reference other aggregates
- expression sorts on `first` and `list` aggregates
- `uniq` list aggregates sorted by fields other than the listed field
- fanout-prone `sum`, `avg`, `list`, `custom`, or field-based `count` aggregate filters over to-many relationship references
