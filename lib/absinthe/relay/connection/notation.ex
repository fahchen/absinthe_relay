defmodule Absinthe.Relay.Connection.Notation do
  @moduledoc """
  Macros used to define Connection-related schema entities

  See `Absinthe.Relay.Connection` for more information.
  """

  alias Absinthe.Blueprint.Schema

  defmodule Naming do
    @moduledoc false

    defstruct base_identifier: nil,
              node_type_identifier: nil,
              connection_type_identifier: nil,
              edge_type_identifier: nil,
              attrs: []

    def define(node_type_identifier) do
      define(node_type_identifier, node_type_identifier)
    end

    def define(nil, nil) do
      nil
    end

    def define(node_type_identifier, nil) do
      define(node_type_identifier, node_type_identifier)
    end

    def define(node_type_identifier, base_identifier) do
      %__MODULE__{
        node_type_identifier: node_type_identifier,
        base_identifier: base_identifier,
        connection_type_identifier: ident(base_identifier, :connection),
        edge_type_identifier: ident(base_identifier, :edge),
        attrs: [node_type: node_type_identifier, connection: base_identifier]
      }
    end

    defp ident(base, category) do
      :"#{base}_#{category}"
    end
  end

  defp naming_from_attrs!(attrs) do
    naming = Naming.define(attrs[:node_type], attrs[:connection])

    naming ||
      raise(
        "Must provide a `:node_type' option (an optional `:connection` option is also supported)"
      )
  end

  @doc """
  Define a connection type for a given node type.

  ## Examples

  A basic connection for a node type, `:pet`. This well generate simple
  `:pet_connection` and `:pet_edge` types for you:

  ```
  connection node_type: :pet
  ```

  You can provide a custom name for the connection type (just don't include the
  word "connection"). You must still provide the `:node_type`. You can create as
  many different connections to a node type as you want.

  This example will create a connection type, `:favorite_pets_connection`, and
  an edge type, `:favorite_pets_edge`:

  ```
  connection :favorite_pets, node_type: :pet
  ```

  You can customize the connection object just like any other `object`:

  ```
  connection :favorite_pets, node_type: :pet do
    field :total_age, :float do
      resolve fn
        _, %{source: conn} ->
          sum = conn.edges
          |> Enum.map(fn edge -> edge.node.age)
          |> Enum.sum
          {:ok, sum}
      end
    end
    edge do
      # ...
    end
  end
  ```

  Just remember that if you use the block form of `connection`, you must call
  the `edge` macro within the block to make sure the edge type is generated.
  See the `edge` macro below for more information.
  """
  defmacro connection({:field, _, [identifier, attrs]}, do: block) when is_list(attrs) do
    # do_connection_field(__CALLER__, identifier, naming_from_attrs!(attrs), field_attrs, block)
    do_connection_field(identifier, attrs, block)
  end

  defmacro connection(attrs, do: block) do
    naming = naming_from_attrs!(attrs)
    do_connection_definition(naming, attrs, block)
  end

  defmacro connection(identifier, attrs) do
    naming = naming_from_attrs!(attrs |> Keyword.put(:connection, identifier))
    do_connection_definition(naming, attrs, [])
  end

  defmacro connection(attrs) do
    naming = naming_from_attrs!(attrs)
    do_connection_definition(naming, attrs, [])
  end

  defmacro connection(identifier, attrs, do: block) do
    naming = naming_from_attrs!(attrs |> Keyword.put(:connection, identifier))
    do_connection_definition(naming, attrs, block)
  end

  defp do_connection_field(identifier, attrs, block) do
    naming = naming_from_attrs!(attrs)

    paginate = Keyword.get(attrs, :paginate, :both)

    field_attrs =
      attrs
      |> Keyword.drop([:node_type, :connection, :paginate])
      |> Keyword.put(:type, naming.connection_type_identifier)

    quote do
      field unquote(identifier), unquote(field_attrs) do
        private(:absinthe_relay, {:paginate, unquote(paginate)}, {:fill, unquote(__MODULE__)})
        unquote(block)
      end
    end
  end

  defp do_connection_definition(naming, attrs, block) do
    identifier = naming.connection_type_identifier
    attrs = Keyword.drop(attrs, [:node_type, :connection])

    block = name_edge(block, naming.attrs)

    quote do
      object unquote(identifier), unquote(attrs) do
        private(
          :absinthe_relay,
          {:connection, unquote(naming.attrs)},
          {:fill, unquote(__MODULE__)}
        )

        field(:page_info, type: non_null(:page_info))
        field(:edges, type: list_of(unquote(naming.edge_type_identifier)))
        unquote(block)
      end
    end
  end

  defp name_edge([], _), do: []

  defp name_edge({:edge, meta, [[do: block]]}, conn_attrs) do
    {:edge, meta, [conn_attrs, [do: block]]}
  end

  defp name_edge({:__block__, meta, content}, conn_attrs) do
    content =
      Enum.map(content, fn
        {:edge, meta, [[do: block]]} ->
          {:edge, meta, [conn_attrs, [do: block]]}

        {:edge, meta, [attrs, [do: block]]} ->
          {:edge, meta, [conn_attrs ++ attrs, [do: block]]}

        node ->
          node
      end)

    {:__block__, meta, content}
  end

  @doc """
  Customize the edge type.

  ## Examples

  ```
  connection node_type: :pet do
    # ...
    edge do
      field :node_name_backwards, :string do
        resolve fn
          _, %{source: edge} ->
            {:ok, edge.node.name |> String.reverse}
        end
      end
    end
  end
  ```
  """
  defmacro edge(attrs, do: block) do
    naming = naming_from_attrs!(attrs)
    attrs = Keyword.drop(attrs, [:node_type, :connection])

    quote do
      Absinthe.Schema.Notation.stash()

      object unquote(naming.edge_type_identifier), unquote(attrs) do
        private(:absinthe_relay, {:edge, unquote(naming.attrs)}, {:fill, unquote(__MODULE__)})
        unquote(block)
      end

      Absinthe.Schema.Notation.pop()
    end
  end

  def additional_types({:connection, attrs}, _) do
    naming = naming_from_attrs!(attrs)
    identifier = naming.edge_type_identifier

    %Schema.ObjectTypeDefinition{
      name: identifier |> Atom.to_string() |> Macro.camelize(),
      identifier: identifier,
      module: __MODULE__,
      __private__: [absinthe_relay: [{{:edge, attrs}, {:fill, __MODULE__}}]],
      __reference__: Absinthe.Schema.Notation.build_reference(__ENV__)
    }
  end

  def additional_types(_, _), do: []

  def fillout({:paginate, type}, node) do
    Map.update!(node, :arguments, fn arguments ->
      type
      |> paginate_args()
      |> Enum.map(fn {id, type} -> build_arg(id, type) end)
      |> put_uniq(arguments)
    end)
  end

  #   @desc "The item at the end of the edge"
  # field(:node, unquote(naming.node_type_identifier))
  # @desc "A cursor for use in pagination"
  # field(:cursor, non_null(:string))
  def fillout({:edge, attrs}, node) do
    naming = naming_from_attrs!(attrs)

    Map.update!(node, :fields, fn fields ->
      naming.node_type_identifier
      |> edge_fields
      |> put_uniq(fields)
    end)
  end

  def fillout(_, node) do
    node
  end

  defp put_uniq(new, prior) do
    existing = MapSet.new(prior, & &1.identifier)

    new
    |> Enum.filter(&(!(&1.identifier in existing)))
    |> Enum.concat(prior)
  end

  defp edge_fields(node_type) do
    [
      %Schema.FieldDefinition{
        name: "node",
        identifier: :node,
        type: node_type,
        module: __MODULE__,
        __reference__: Absinthe.Schema.Notation.build_reference(__ENV__)
      },
      %Schema.FieldDefinition{
        name: "cursor",
        identifier: :cursor,
        type: :string,
        module: __MODULE__,
        __reference__: Absinthe.Schema.Notation.build_reference(__ENV__)
      }
    ]
  end

  defp paginate_args(:forward) do
    [after: :string, first: :integer]
  end

  defp paginate_args(:backward) do
    [before: :string, last: :integer]
  end

  defp paginate_args(:both) do
    paginate_args(:forward) ++ paginate_args(:backward)
  end

  defp build_arg(id, type) do
    %Schema.InputValueDefinition{
      name: id |> Atom.to_string(),
      identifier: id,
      type: type,
      module: __MODULE__,
      __reference__: Absinthe.Schema.Notation.build_reference(__ENV__)
    }
  end
end
