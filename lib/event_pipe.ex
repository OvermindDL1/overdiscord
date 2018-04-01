defmodule Overdiscord.EventPipe do
  @moduledoc ~S"""
  """

  alias Overdiscord.Storage

  @hooks_db :eventpipe

  def add_hook(hooks_db \\ @hooks_db, hook_type, priority, module, function, args) do
    Storage.put(hooks_db, :list_sorted_add, hook_type, {priority, module, function, args})
  end

  def remove_hook(hooks_db \\ @hooks_db, hook_type, priority, module, function, args) do
    Storage.put(hooks_db, :list_sorted_remove, hook_type, {priority, module, function, args})
  end

  def remove_hook(hooks_db \\ @hooks_db, hook_type, priority) do
    get_hooks(hook_type)
    |> Enum.map(fn
      {^priority, _module, _function, _args} = value ->
        Storage.put(hooks_db, :list_sorted_remove, hook_type, value)
        value

      _ ->
        []
    end)
  end

  def get_hooks(hooks_db \\ @hooks_db, hook_type) do
    Storage.get(hooks_db, :list_sorted, hook_type)
  end

  def inject(event_data), do: inject(:console, event_data)

  def inject(possible_auth, event_data) when is_binary(event_data) do
    inject(possible_auth, %{msg: event_data})
  end

  def inject(possible_auth, event_data) when is_list(event_data) do
    inject(possible_auth, Enum.into(event_data, %{}))
  end

  def inject(possible_auth, event_data) when is_map(event_data) do
    auth = Overdiscord.Auth.to_auth(possible_auth)

    IO.inspect({possible_auth, auth, event_data}, label: EventInject)

    hooks_db = Storage.get_db(@hooks_db)
    arg = [auth, event_data]
    process_hooks(hooks_db, :all, arg)
    process_hooks(hooks_db, {:server, auth.server}, arg)
    process_hooks(hooks_db, {:server_location, auth.server, auth.location}, arg)
    process_hooks(hooks_db, {:username, auth.username}, arg)
    process_hooks(hooks_db, {:nickname, auth.nickname}, arg)

    process_hooks(
      hooks_db,
      {:server_location_user, auth.server, auth.location, auth.username},
      arg
    )

    process_hooks(
      hooks_db,
      {:server_location_nick, auth.server, auth.location, auth.nickname},
      arg
    )

    process_hooks(
      hooks_db,
      {:server_location_user_nick, auth.server, auth.location, auth.username, auth.nickname},
      arg
    )

    case event_data do
      %{msg: _msg} ->
        process_hooks(hooks_db, :msg, arg)
    end
  rescue
    exc ->
      IO.inspect(exc, label: "EventPipeException")
      IO.puts(Exception.message(exc))
      :error
  catch
    error ->
      IO.inspect(error, label: "EventPipeError")
      :error
  end

  def process_hooks(hooks_db, hook_name, arg) do
    Storage.get(hooks_db, :list_sorted, hook_name)
    #    |> IO.inspect(label: "Processing hooks #{inspect hook_name}")
    |> Enum.reduce(false, fn
      {_priority, module, func, args}, false ->
        args = arg ++ List.wrap(args)

        try do
          apply(module, func, args) || false
        rescue
          exc ->
            IO.inspect({hook_name, module, func, args, exc}, label: "HookException")
            IO.puts(Exception.message(exc))
            :error
        catch
          error ->
            IO.inspect({hook_name, module, func, args, error}, label: "HookError")
            :error
        end

      _, canceled ->
        canceled
    end)
  end
end
