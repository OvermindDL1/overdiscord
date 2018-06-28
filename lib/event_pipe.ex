defmodule Overdiscord.EventPipe do
  @moduledoc ~S"""
  """

  alias Overdiscord.Storage

  @hooks_db :eventpipe
  @hooks_key :hooks
  @hooks_backup_key :hooks_backup
  @history 50

  def add_hook(
        hooks_db \\ @hooks_db,
        priority,
        %{} = matcher,
        extra_matches,
        module,
        function,
        args
      )
      when is_atom(module) and is_atom(function) and is_list(args) and is_list(extra_matches) do
    Storage.put(
      hooks_db,
      :list_sorted_add,
      @hooks_key,
      {priority, matcher, extra_matches, module, function, args}
    )
  end

  def delete_hooks(hooks_db \\ @hooks_db, cb) do
    hooks_db = Storage.get_db(hooks_db)
    old_hooks = Storage.get(hooks_db, :list, @hooks_key)

    Storage.put(
      hooks_db,
      :list_truncated,
      @hooks_backup_key,
      {{NaiveDateTime.utc_now(), old_hooks}, 20, 10}
    )

    Storage.put(hooks_db, :list_remove_many, @hooks_key, cb)
    # Not a transaction, but eh until postgresql or so...
    length(old_hooks) - length(Storage.get(hooks_db, :list, @hooks_key))
  end

  # def add_hook(hooks_db \\ @hooks_db, hook_type, priority, module, function, args) do
  #  Storage.put(hooks_db, :list_sorted_add, hook_type, {priority, module, function, args})
  # end

  # def remove_hook(hooks_db \\ @hooks_db, hook_type, priority, module, function, args) do
  #  Storage.put(hooks_db, :list_sorted_remove, hook_type, {priority, module, function, args})
  # end

  # def remove_hook(hooks_db \\ @hooks_db, hook_type, priority) do
  #  get_hooks(hook_type)
  #  |> Enum.map(fn
  #    {^priority, _module, _function, _args} = value ->
  #      Storage.put(hooks_db, :list_sorted_remove, hook_type, value)
  #      value
  #
  #    _ ->
  #      []
  #  end)
  # end

  def get_hooks(hooks_db \\ @hooks_db) do
    Storage.get(hooks_db, :list_sorted, @hooks_key)
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
    # IO.inspect({possible_auth, auth, event_data}, label: :EventInjection)

    hooks_db = Storage.get_db(@hooks_db)
    matcher_data = %{auth: auth, event_data: event_data}
    Storage.put(hooks_db, :list_truncated, :history, {matcher_data, @history * 2, @history})
    arg = [auth, event_data]

    Storage.get(hooks_db, :list_sorted, @hooks_key)
    |> Enum.each(fn {_priority, matcher, extra_matches, module, function, args} ->
      if deep_match(matcher, matcher_data) do
        extra_matches
        |> Enum.all?(fn
          {:permissions, permissions} ->
            Enum.all?(List.wrap(permissions), &auth.permissions.(&1))

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
      else
        nil
      end
    end)
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

  def deep_match(smaller, larger)

  def deep_match(same, same) do
    true
  end

  def deep_match(equals, equall) when equals == equall do
    true
  end

  def deep_match(%{} = smaller, %{} = larger) do
    Enum.all?(smaller, &deep_match(elem(&1, 1), Map.get(larger, elem(&1, 0), nil)))
  end

  def deep_match([], []) do
    true
  end

  def deep_match([s | smaller], [l | larger]) do
    deep_match(s, l) and deep_match(smaller, larger)
  end

  def deep_match({}, {}) do
    true
  end

  def deep_match(smaller, larger) when tuple_size(smaller) === tuple_size(larger) do
    Enum.all?(0..(tuple_size(smaller) - 1), &deep_match(elem(smaller, &1), elem(larger, &1)))
  end

  def deep_match(_smaller, _larger) do
    false
  end
end
