defmodule Overdiscord.Hooks.Commands.Todo do
  require Logger

  alias Overdiscord.Storage

  @db :cmd_todo

  @max_todos 10

  def parser_def() do
    %{
      strict: [
        id: :string
      ],
      aliases: [],
      args: 0,
      help: %{
        nil => "TODO System"
      },
      callback: {__MODULE__, :handle_cmd_todo, []},
      sub_parsers: %{
        "add" => %{
          help: %{
            nil: "Add a new item to the todo list",
            group:
              "Set todo group.  Groups are sorted alphabetically, then todo's sorted alphabetically within that."
          },
          args: 1..1000,
          strict: [
            group: :string
          ],
          aliases: [
            g: :group
          ],
          callback: {__MODULE__, :handle_cmd_todo_add, []}
        },
        "del" => %{
          help: %{nil: "Delete a list of indexes or groups"},
          args: 1..(@max_todos + 1),
          strict: [],
          callback: {__MODULE__, :handle_cmd_todo_del, []}
        }
      }
    }
  end

  def handle_cmd_todo(%{auth: auth, params: params}) do
    case todo_key_of(auth, params) do
      {:ok, key} ->
        [
          "**TODO List:**"
          | key
            |> get_indexed_todos()
            |> Enum.map(&stringify_indexed_todo/1)
        ]
        |> Enum.join("\n")
        |> case do
          "**TODO List:**" -> "No todos"
          result -> result
        end

      {:error, :permission} ->
        "Invalid permission to access id"
    end
  end

  def handle_cmd_todo_add(%{auth: auth, args: todo, params: params}) do
    group = params[:group] || ""

    todo = %{
      group: group,
      todo: Enum.join(todo, " ")
    }

    case todo_key_of(auth, params) do
      {:ok, key} ->
        todos = sort_todos([todo | Storage.get(@db, :kv, key, [])])

        if length(todos) > @max_todos do
          "Too many todos, remove one to add another, max of #{@max_todos}"
        else
          Storage.put(@db, :kv, key, todos)
          "Added todo to todo list with #{length(todos)} todos"
        end

      {:error, :permission} ->
        "Invalid permission to access id"
    end
  end

  def handle_cmd_todo_del(%{auth: auth, args: args, params: params}) do
    case todo_key_of(auth, params) do
      {:ok, key} ->
        {ids, groups} =
          args
          |> Enum.map(fn arg ->
            case Integer.parse(arg) do
              {id, ""} -> id
              _ -> arg
            end
          end)
          |> Enum.split_with(&is_integer/1)

        ids = Enum.sort(ids)
        groups = Enum.sort(groups)

        orig_todos = get_indexed_todos(key)

        todos =
          orig_todos
          |> Enum.flat_map_reduce(ids, fn
            {_todo, idx} = todo_idx, [id | ids] ->
              cond do
                idx == id -> {[], ids}
                :else -> {[todo_idx], [id | ids]}
              end

            {_todo, _idx} = todo_idx, [] ->
              {[todo_idx], []}
          end)
          |> elem(0)
          |> Enum.flat_map_reduce(groups, fn
            {todo, _idx} = todo_idx, [group | groups] = all_groups ->
              cond do
                todo.group == group ->
                  {[], all_groups}

                todo.group < group ->
                  {[todo_idx], all_groups}

                :else ->
                  groups = Enum.drop_while(groups, &(&1.group > group))

                  case groups do
                    [] ->
                      {[todo_idx], []}

                    [group | _groups] = all_groups ->
                      if todo.group == group do
                        {[], all_groups}
                      else
                        {[todo_idx], all_groups}
                      end
                  end
              end

            {_todo, _idx} = todo_idx, [] ->
              {[todo_idx], []}
          end)
          |> elem(0)

        Storage.put(@db, :kv, key, Enum.map(todos, &elem(&1, 0)))

        del_todos = orig_todos -- todos

        [
          "Deleted Todos (#{length(todos)} remaining):\n"
          | Enum.map(del_todos, &stringify_indexed_todo/1)
        ]
        |> Enum.join("\n")

      {:error, :permission} ->
        "Invalid permission to access id"
    end
  end

  # Accessors and helpers

  def get_indexed_todos(key) do
    key
    |> get_todos()
    |> Enum.with_index()
  end

  def get_todos(key) do
    Storage.get(@db, :kv, key, [])
    |> sort_todos()
  end

  def todo_key_of(auth, params) do
    case params[:id] do
      nil ->
        {:ok, auth.id}

      id ->
        if auth.permissions.({:cmds, :todo, :other_id, id}) do
          {:ok, id}
        else
          {:error, :permission}
        end
    end
  end

  def sort_todos(todos) do
    todos
    |> Enum.sort_by(&{&1.group, &1.todo})
  end

  def stringify_todo(todo) do
    group =
      case todo.group do
        "" -> ""
        group when is_binary(group) -> "**(#{group})** "
        _ -> ""
      end

    group <> todo.todo
  end

  def stringify_indexed_todo({todo, idx}) do
    group =
      case todo.group do
        "" -> ""
        group when is_binary(group) -> " (#{group})"
        _ -> ""
      end

    "**#{idx}#{group}:** #{todo.todo}"
  end
end
