defmodule Overdiscord.Web.EventPipeController do
  use Overdiscord.Web, :controller

  alias Overdiscord.EventPipe

  plug(:plug_authenticated, role: :admin)

  def index(conn, _params) do
    hooks = EventPipe.get_hooks()
    render(conn, :index, hooks: hooks)
  end

  def history(conn, _params) do
    events = EventPipe.get_history()
    render(conn, :history, events: events)
  end

  def new_hook(
        conn,
        %{"priority" => priority, "module" => module, "function" => function, "args" => args} =
          params
      ) do
    matcher_auth =
      with(
        matcher_auth = %{},
        {:ok, matcher_auth} <- put_if_valid(matcher_auth, params, :server),
        {:ok, matcher_auth} <- put_if_valid(matcher_auth, params, :location),
        {:ok, matcher_auth} <- put_if_valid(matcher_auth, params, :username, nil),
        {:ok, matcher_auth} <- put_if_valid(matcher_auth, params, :nickname, nil),
        # {:ok, matcher_auth} <-
        #  put_if_valid(matcher_auth, params, :permission, %{list: true, atom: true}),
        do: {:ok, matcher_auth}
      )

    extra_matches =
      Enum.reduce(params, [], fn
        _, {:error, _} = err ->
          err

        {"permission", perms}, acc ->
          case ElixirParse.parse(perms, allowed_types: %{list: true, atom: true}) do
            {:error, ""} -> acc
            {:error, rest} -> {:error, "permissions parse error at: #{rest}"}
            {:ok, result, ""} -> [{:permissions, result} | acc]
          end

        {"event_msg", event_msg}, acc ->
          case event_msg do
            nil ->
              acc

            "" ->
              acc

            "=" <> msg ->
              [{:msg, :equals, msg} | acc]

            "^" <> msg ->
              [{:msg, :starts_with, msg} | acc]

            "~" <> msg ->
              case Regex.compile(msg) do
                {:error, reason} ->
                  {:error, "event-msg parse failure: #{inspect(reason)}"}

                {:ok, regex} ->
                  [{:msg, :regex, msg, regex} | acc]
              end

            msg ->
              [{:msg, :contains, msg} | acc]
          end

        _unhandled, acc ->
          acc
      end)

    priority = ElixirParse.parse(priority)
    module = ElixirParse.parse(module, allowed_types: %{atom: true})
    function = ElixirParse.parse(function, allowed_types: %{atom: true})
    args = ElixirParse.parse(args)

    with(
      {:ok, matcher_auth} <- matcher_auth,
      extra_matches when is_list(extra_matches) <- extra_matches,
      {:ok, priority, ""} <- priority,
      {:ok, module, ""} <- module,
      {:ok, function, ""} <- function,
      {:ok, args, ""} <- args,
      args = List.wrap(args),
      true <-
        try do
          if module.__info__(:functions)[function] === length(args) + 2 do
            true
          else
            {:error, "#{module}.#{function} at arity #{length(args) + 2} does exist"}
          end
        rescue
          UndefinedFunctionError ->
            {:error, "#{module}.#{function} at arity #{length(args) + 2} does exist"}
        end,
      matcher = if(map_size(matcher_auth), do: %{auth: matcher_auth}, else: %{})
    ) do
      EventPipe.add_hook(priority, matcher, extra_matches, module, function, args)

      conn
      |> put_flash(:info, "Added hook")
      |> redirect(to: Routes.event_pipe_path(conn, :index))
    else
      {:error, reason} ->
        IO.inspect({:ERROR, reason}, label: :HookCreate)

        conn
        |> put_flash(:error, reason)
        |> render(:index, hooks: EventPipe.get_hooks())
    end
  end

  def delete_hook(conn, %{"priority" => priority} = _params) do
    {:ok, priority, ""} =
      ElixirParse.parse(priority, allowed_types: %{integer: true, float: true})

    case EventPipe.delete_hooks(&(elem(&1, 0) == priority)) do
      0 -> put_flash(conn, :warn, "No matching hooks found to delete.")
      c -> put_flash(conn, :info, "#{c} hooks deleted")
    end
    |> redirect(to: Routes.event_pipe_path(conn, :index))
  end

  defp put_if_valid(map, params, key, valid \\ ElixirParse.default_allowed_types()) do
    value = params[to_string(key)]

    if value && value != "" do
      if valid do
        case ElixirParse.parse(value, allowed_types: valid) do
          {:ok, parsed, ""} -> {:ok, Map.put_new(map, key, parsed)}
          {:ok, _parsed, rest} -> {:error, "#{key} has invalid input at: #{rest}"}
          {:error, rest} -> {:error, "#{key} has invalid input starting at: #{rest}"}
        end
      else
        {:ok, Map.put_new(map, key, value)}
      end
    else
      {:ok, map}
    end
  end
end
