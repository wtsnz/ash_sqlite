# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Aggregate do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  def add_aggregates(query, aggregates, resource, opts \\ []) do
    select? = Keyword.get(opts, :select?, true)

    do_add_aggregates(query, aggregates, resource, select?)
  end

  def add_sort_aggregates(query, sort, _resource) when sort in [nil, []], do: {:ok, query}

  def add_sort_aggregates(query, sort, resource) do
    with {:ok, aggregates} <- aggregates_from_sort(query, sort, resource) do
      add_aggregates(query, aggregates, resource, select?: false)
    end
  end

  def relationship_filter_uses_parent?(%{filter: nil}), do: false

  def relationship_filter_uses_parent?(%{filter: filter}) do
    filter
    |> Ash.Filter.flat_map(fn
      %Ash.Query.Parent{} -> [:parent]
      _ -> []
    end)
    |> Enum.any?()
  end

  defp do_add_aggregates(query, [], _resource, _select?), do: {:ok, query}

  defp do_add_aggregates(query, aggregates, resource, select?) do
    primary_key = Ash.Resource.Info.primary_key(resource)

    cond do
      primary_key == [] ->
        {:error, "AshSqlite cannot load aggregates on resources with no primary key"}

      Enum.any?(aggregates, &(not supported?(&1))) ->
        {:error,
         "AshSqlite only supports loading related count, sum, avg, min, max and exists aggregates"}

      true ->
        aggregates
        |> Enum.group_by(& &1.relationship_path)
        |> Enum.reduce_while({:ok, query, []}, fn {relationship_path, aggregates},
                                                  {:ok, query, dynamics} ->
          case add_aggregate_group(query, resource, relationship_path, aggregates) do
            {:ok, query, new_dynamics} ->
              {:cont, {:ok, query, new_dynamics ++ dynamics}}

            {:error, error} ->
              {:halt, {:error, error}}
          end
        end)
        |> case do
          {:ok, query, dynamics} ->
            if select? do
              {:ok, select_aggregates(query, dynamics)}
            else
              {:ok, query}
            end

          {:error, error} ->
            {:error, error}
        end
    end
  end

  defp supported?(%{kind: kind, related?: related?, relationship_path: path})
       when kind in [:count, :sum, :avg, :max, :min, :exists] do
    related? != false && match?([_], path)
  end

  defp supported?(_), do: false

  defp aggregates_from_sort(query, sort, resource) do
    sort
    |> List.wrap()
    |> Enum.reduce_while({:ok, []}, fn sort, {:ok, aggregates} ->
      case sort_aggregates(query, sort, resource) do
        {:ok, new_aggregates} ->
          {:cont, {:ok, new_aggregates ++ aggregates}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, aggregates} -> {:ok, Enum.uniq(aggregates)}
      {:error, error} -> {:error, error}
    end
  end

  defp sort_aggregates(query, {sort, _order}, resource) do
    sort_key_aggregates(query, sort, resource)
  end

  defp sort_aggregates(query, sort, resource) do
    sort_key_aggregates(query, sort, resource)
  end

  defp sort_key_aggregates(_query, %Ash.Query.Aggregate{} = aggregate, _resource) do
    {:ok, [aggregate]}
  end

  defp sort_key_aggregates(query, %Ash.Query.Calculation{} = calculation, resource) do
    calculation_aggregates(query, calculation, resource)
  end

  defp sort_key_aggregates(query, sort, resource) when is_atom(sort) do
    case Ash.Resource.Info.field(resource, sort) do
      %Ash.Resource.Aggregate{} = aggregate ->
        query_aggregate(resource, aggregate)

      %Ash.Resource.Calculation{} = calculation ->
        calculation_aggregates(query, calculation, resource)

      _ ->
        {:ok, []}
    end
  end

  defp sort_key_aggregates(_query, _sort, _resource), do: {:ok, []}

  defp calculation_aggregates(query, %Ash.Resource.Calculation{} = calculation, resource) do
    {module, opts} = calculation.calculation

    with {:ok, calculation} <-
           Ash.Query.Calculation.new(
             calculation.name,
             module,
             opts,
             calculation.type,
             calculation.constraints
           ) do
      calculation =
        Ash.Actions.Read.add_calc_context(
          calculation,
          query.__ash_bindings__.context[:private][:actor],
          query.__ash_bindings__.context[:private][:authorize?],
          query.__ash_bindings__.context[:private][:tenant],
          query.__ash_bindings__.context[:private][:tracer],
          query.__ash_bindings__.context[:private][:domain],
          query.__ash_bindings__.context[:private][:resource],
          parent_stack: query.__ash_bindings__[:parent_resources] || []
        )

      calculation_aggregates(query, calculation, resource)
    end
  end

  defp calculation_aggregates(query, %Ash.Query.Calculation{} = calculation, resource) do
    calculation.opts
    |> calculation.module.expression(calculation.context)
    |> Ash.Filter.hydrate_refs(%{
      resource: resource,
      aggregates: %{},
      parent_stack: query.__ash_bindings__[:parent_resources] || [],
      calculations: %{},
      public?: false
    })
    |> case do
      {:ok, expression} ->
        {:ok, Ash.Filter.used_aggregates(expression)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp query_aggregate(resource, aggregate) do
    related = Ash.Resource.Info.related(resource, aggregate.relationship_path)

    read_action =
      aggregate.read_action ||
        Ash.Resource.Info.primary_action!(related, :read).name

    with %{valid?: true} = aggregate_query <- Ash.Query.for_read(related, read_action),
         %{valid?: true} = aggregate_query <-
           Ash.Query.build(aggregate_query,
             filter: aggregate.filter,
             sort: aggregate.sort
           ),
         {:ok, aggregate} <-
           Ash.Query.Aggregate.new(
             resource,
             aggregate.name,
             aggregate.kind,
             path: aggregate.relationship_path,
             query: aggregate_query,
             field: aggregate.field,
             default: aggregate.default,
             filterable?: aggregate.filterable?,
             type: aggregate.type,
             sortable?: aggregate.sortable?,
             include_nil?: aggregate.include_nil?,
             constraints: aggregate.constraints,
             implementation: aggregate.implementation,
             uniq?: aggregate.uniq?,
             read_action: read_action,
             authorize?: aggregate.authorize?,
             join_filters: aggregate.join_filters
           ) do
      {:ok, [aggregate]}
    else
      %{errors: errors} ->
        {:error, errors}

      {:error, error} ->
        {:error, error}
    end
  end

  defp add_aggregate_group(query, resource, [relationship_name], aggregates) do
    relationship = Ash.Resource.Info.relationship(resource, relationship_name)

    cond do
      is_nil(relationship) ->
        {:error, "No such relationship #{inspect(resource)}.#{relationship_name}"}

      match?(%{manual: {_, _}}, relationship) ->
        {:error, "AshSqlite does not support loading aggregates over manual relationships"}

      Map.get(relationship, :no_attributes?, false) ->
        {:error,
         "AshSqlite does not support loading aggregates over no_attributes? relationships"}

      relationship_filter_uses_parent?(relationship) ->
        {:error,
         "AshSqlite does not support loading aggregates over relationships with parent-dependent filters"}

      join_relationship_filter_uses_parent?(relationship) ->
        {:error,
         "AshSqlite does not support loading aggregates over many_to_many relationships with parent-dependent join filters"}

      true ->
        do_add_aggregate_group(query, relationship, aggregates)
    end
  end

  defp add_aggregate_group(_query, resource, relationship_path, _aggregates) do
    {:error,
     "AshSqlite only supports loading aggregates over one relationship from #{inspect(resource)}, got: #{inspect(relationship_path)}"}
  end

  defp do_add_aggregate_group(query, relationship, aggregates) do
    binding = query.__ash_bindings__.current

    with {:ok, aggregate_query} <-
           aggregate_query(query, relationship, aggregates, binding) do
      aggregate_query = Ecto.Query.subquery(aggregate_query)
      root_binding = query.__ash_bindings__.root_binding

      query =
        from(_row in query,
          left_join: aggregate in ^aggregate_query,
          as: ^binding,
          on:
            field(as(^root_binding), ^relationship.source_attribute) ==
              field(aggregate, ^aggregate_join_attribute(relationship))
        )

      query =
        AshSql.Bindings.add_binding(query, %{
          type: :aggregate,
          path: [],
          aggregates: aggregates
        })

      dynamics =
        Enum.map(aggregates, fn aggregate ->
          {aggregate.load, aggregate.name, loaded_aggregate_dynamic(aggregate, binding)}
        end)

      {:ok, query, dynamics}
    end
  end

  defp aggregate_query(parent_query, relationship, aggregates, binding) do
    if relationship.type == :many_to_many do
      many_to_many_aggregate_query(parent_query, relationship, aggregates, binding)
    else
      related_aggregate_query(parent_query, relationship, aggregates, binding)
    end
  end

  defp related_aggregate_query(parent_query, relationship, aggregates, binding) do
    with {:ok, query} <- related_query(parent_query, relationship, hd(aggregates), binding) do
      root_binding = query.__ash_bindings__.root_binding

      query =
        from(row in query,
          group_by: field(as(^root_binding), ^relationship.destination_attribute),
          select: %{
            ^relationship.destination_attribute =>
              field(as(^root_binding), ^relationship.destination_attribute)
          }
        )

      Enum.reduce_while(aggregates, {:ok, query}, fn aggregate, {:ok, query} ->
        case aggregate_dynamic(query, relationship, aggregate, root_binding) do
          {:ok, query, dynamic} ->
            {:cont, {:ok, Ecto.Query.select_merge(query, ^%{aggregate.name => dynamic})}}

          {:error, error} ->
            {:halt, {:error, error}}
        end
      end)
    end
  end

  defp many_to_many_aggregate_query(parent_query, relationship, aggregates, binding) do
    through_binding = binding + 1

    with {:ok, query} <- related_query(parent_query, relationship, hd(aggregates), binding),
         {:ok, through_query} <- through_query(parent_query, relationship, through_binding) do
      root_binding = query.__ash_bindings__.root_binding
      through_query = Ecto.Query.subquery(through_query)

      query =
        from(row in query,
          join: through in ^through_query,
          as: ^through_binding,
          on:
            field(through, ^relationship.destination_attribute_on_join_resource) ==
              field(as(^root_binding), ^relationship.destination_attribute),
          group_by: field(through, ^relationship.source_attribute_on_join_resource),
          select: %{
            ^relationship.source_attribute_on_join_resource =>
              field(through, ^relationship.source_attribute_on_join_resource)
          }
        )

      Enum.reduce_while(aggregates, {:ok, query}, fn aggregate, {:ok, query} ->
        case aggregate_dynamic(query, relationship, aggregate, root_binding) do
          {:ok, query, dynamic} ->
            {:cont, {:ok, Ecto.Query.select_merge(query, ^%{aggregate.name => dynamic})}}

          {:error, error} ->
            {:halt, {:error, error}}
        end
      end)
    end
  end

  defp related_query(parent_query, relationship, aggregate, binding) do
    aggregate.query
    |> Ash.Query.unset([:filter, :sort, :distinct, :select, :limit, :offset])
    |> Ash.Query.set_context(relationship.context)
    |> Ash.Query.do_filter(relationship.filter, parent_stack: [relationship.source])
    |> Ash.Query.set_context(%{
      data_layer: %{
        start_bindings_at: binding,
        parent_bindings: parent_query.__ash_bindings__
      }
    })
    |> Ash.Query.data_layer_query(run_return_query?: false)
    |> case do
      {:ok, query} ->
        {:ok,
         query
         |> Ecto.Query.exclude(:select)
         |> Ecto.Query.exclude(:order_by)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp through_query(parent_query, relationship, binding) do
    join_relationship =
      Ash.Resource.Info.relationship(relationship.source, relationship.join_relationship)

    relationship.through
    |> Ash.Query.new()
    |> Ash.Query.set_context(%{
      data_layer: %{
        start_bindings_at: binding,
        parent_bindings: parent_query.__ash_bindings__
      }
    })
    |> Ash.Query.set_context(join_relationship.context)
    |> Ash.Query.do_filter(join_relationship.filter)
    |> Ash.Query.data_layer_query(run_return_query?: false)
    |> case do
      {:ok, query} ->
        {:ok,
         query
         |> Ecto.Query.exclude(:select)
         |> Ecto.Query.exclude(:order_by)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp aggregate_join_attribute(%{type: :many_to_many} = relationship) do
    relationship.source_attribute_on_join_resource
  end

  defp aggregate_join_attribute(relationship), do: relationship.destination_attribute

  defp join_relationship_filter_uses_parent?(%{type: :many_to_many} = relationship) do
    relationship.source
    |> Ash.Resource.Info.relationship(relationship.join_relationship)
    |> relationship_filter_uses_parent?()
  end

  defp join_relationship_filter_uses_parent?(_relationship), do: false

  defp aggregate_dynamic(query, relationship, %{kind: :exists} = aggregate, binding) do
    count_field = count_field(relationship, aggregate)
    count_dynamic = Ecto.Query.dynamic(count(field(as(^binding), ^count_field)))

    {query, count_dynamic} =
      maybe_filter_aggregate(query, aggregate, count_dynamic)

    {:ok, query, Ecto.Query.dynamic(^count_dynamic > 0)}
  end

  defp aggregate_dynamic(query, relationship, %{kind: :count} = aggregate, binding) do
    count_field = count_field(relationship, aggregate)

    dynamic =
      if aggregate.uniq? do
        Ecto.Query.dynamic(count(field(as(^binding), ^count_field), :distinct))
      else
        Ecto.Query.dynamic(count(field(as(^binding), ^count_field)))
      end

    {query, dynamic} = maybe_filter_aggregate(query, aggregate, dynamic)
    {:ok, query, maybe_default_aggregate(dynamic, aggregate)}
  end

  defp aggregate_dynamic(query, _relationship, aggregate, binding)
       when aggregate.kind in [:sum, :avg, :max, :min] and is_atom(aggregate.field) do
    field = Ecto.Query.dynamic(field(as(^binding), ^aggregate.field))

    dynamic =
      case aggregate.kind do
        :sum -> Ecto.Query.dynamic(sum(^field))
        :avg -> Ecto.Query.dynamic(avg(^field))
        :max -> Ecto.Query.dynamic(max(^field))
        :min -> Ecto.Query.dynamic(min(^field))
      end

    {query, dynamic} = maybe_filter_aggregate(query, aggregate, dynamic)
    {:ok, query, maybe_default_aggregate(dynamic, aggregate)}
  end

  defp aggregate_dynamic(_query, _relationship, aggregate, _binding) do
    {:error,
     "AshSqlite cannot load aggregate #{inspect(aggregate.name)} with field #{inspect(aggregate.field)}"}
  end

  defp count_field(_relationship, %{field: field}) when is_atom(field) and not is_nil(field) do
    field
  end

  defp count_field(relationship, _aggregate) do
    relationship.destination
    |> Ash.Resource.Info.primary_key()
    |> List.first()
    |> case do
      nil -> relationship.destination_attribute
      field -> field
    end
  end

  defp maybe_filter_aggregate(query, aggregate, dynamic) do
    case aggregate.query.filter do
      nil ->
        {query, dynamic}

      %{expression: nil} ->
        {query, dynamic}

      filter ->
        {filter_dynamic, acc} =
          AshSql.Expr.dynamic_expr(
            query,
            filter,
            Map.put(query.__ash_bindings__, :location, :aggregate),
            false
          )

        {AshSql.Bindings.merge_expr_accumulator(query, acc),
         Ecto.Query.dynamic(filter(^dynamic, ^filter_dynamic))}
    end
  end

  defp maybe_default_aggregate(dynamic, %{default_value: nil}), do: dynamic

  defp maybe_default_aggregate(dynamic, aggregate) do
    Ecto.Query.dynamic(coalesce(^dynamic, ^aggregate.default_value))
  end

  defp loaded_aggregate_dynamic(%{kind: :exists, default_value: nil} = aggregate, binding) do
    aggregate
    |> loaded_aggregate_field(binding)
    |> then(&Ecto.Query.dynamic(coalesce(^&1, false)))
  end

  defp loaded_aggregate_dynamic(aggregate, binding) do
    aggregate
    |> loaded_aggregate_field(binding)
    |> maybe_default_aggregate(aggregate)
  end

  defp loaded_aggregate_field(aggregate, binding) do
    Ecto.Query.dynamic(field(as(^binding), ^aggregate.name))
  end

  defp select_aggregates(query, dynamics) do
    {in_aggregates, in_body} =
      Enum.split_with(dynamics, fn {load, _name, _dynamic} -> is_nil(load) end)

    aggregates =
      in_body
      |> Map.new(fn {load, _name, dynamic} -> {load, dynamic} end)

    aggregates =
      if Enum.empty?(in_aggregates) do
        aggregates
      else
        Map.put(
          aggregates,
          :aggregates,
          Map.new(in_aggregates, fn {_load, name, dynamic} -> {name, dynamic} end)
        )
      end

    query =
      if query.select do
        query
      else
        from(row in query, select: %{})
      end

    Ecto.Query.select_merge(query, ^aggregates)
  end
end
