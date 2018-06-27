defmodule Overdiscord.EventPipe do
  @moduledoc ~S"""
  """

  alias Overdiscord.Storage

  @hooks_db :eventpipe
  @history 50

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

  def get_all_hooks(hooks_db \\ @hooks_db) do
    Storage.get_all(hooks_db, fn {{:list, key}, value} ->
      {key, value}
    end)
  end

  def get_hooks(hooks_db \\ @hooks_db, hook_type) do
    Storage.get(hooks_db, :list_sorted, hook_type)
  end

  def get_history(hooks_db \\ @hooks_db) do
    Storage.get(hooks_db, :list_truncated, :history)
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

    hooks_db = Storage.get_db(@hooks_db)
    matcher_data = %{auth: auth, event_data: event_data}
    Storage.put(hooks_db, :list_truncated, :history, {matcher_data, @history * 2, @history})
    arg = [auth, event_data]

    Storage.get(hooks_db, :list_sorted, :hooks)
    |> Enum.each(fn {_priority, matcher, extra_matches, module, function, args} ->
      case matcher_data do
        ^matcher ->
          extra_matches
          |> Enum.all?(fn
            {:permission, permission} ->
              auth.permissions.(permission)

            {:msg, :equals, equals} ->
              event_data[:msg] == equals

            {:msg, :contains, contains} ->
              event_data[:msg] && String.contains?(event_data[:msg], contains)

            {:msg, :starts_with, starts} ->
              event_data[:msg] && String.starts_with?(event_data[:msg], starts)

            {:msg, :regex, _original, regex} ->
              event_data[:msg] && event_data[:msg] =~ regex
          end)
          |> if do
            try do
              apply(module, function, arg ++ args) || false
            rescue
              exc ->
                IO.inspect({matcher, module, function, args, exc}, label: "HookException")
                IO.puts(Exception.message(exc))
                :error
            catch
              error ->
                IO.inspect({matcher, module, function, args, error}, label: "HookError")
                :error
            end
          else
            nil
          end

        _ ->
          nil
      end
    end)

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
