defmodule Overdiscord.Storage do
  @moduledoc ~S"""
  """

  @app_name :overdiscord

  use GenServer

  @safe []

  ## Interface

  def get_db(name) when is_atom(name) or is_binary(name) do
    case Application.get_env(@app_name, :active_storages, %{})[name] do
      nil ->
        GenServer.call(__MODULE__, {:get_db, name})

      # Early-out concurrency
      result ->
        result
    end
  end

  def close_db(name) do
    case Application.get_env(@app_name, :active_storages, %{})[name] do
      nil -> :ok
      {:leveldb, db} -> Exleveldb.close(db)
    end
  end

  # TODO:  Move the `put's` into a genserver

  def put(name, type, key, value) when is_atom(name) or is_binary(name) do
    put(get_db(name), type, key, value)
  end

  def put(state = %{db: db}, type, key, value) do
    put(db, type, key, value)
    state
  end

  def put({:leveldb, db}, :timeseries, key, value) when is_integer(value) do
    now = NaiveDateTime.utc_now()
    key = :erlang.term_to_binary({:ts, key, now.year, now.month, now.day, now.hour})

    oldValue =
      case Exleveldb.get(db, key) do
        :not_found -> 0
        {:ok, s} -> String.to_integer(s)
      end

    value = to_string(oldValue + value)
    Exleveldb.put(db, key, value)
    {:leveldb, db}
  end

  def put({:leveldb, db}, :kv, key, value) do
    key = :erlang.term_to_binary({:kv, key})
    value = :erlang.term_to_binary(value)
    Exleveldb.put(db, key, value)
    {:leveldb, db}
  end

  def put({:leveldb, db}, :list_add, key, value) do
    key = :erlang.term_to_binary({:list, key})

    oldValues =
      case Exleveldb.get(db, key) do
        :not_found -> []
        {:ok, values} -> :erlang.binary_to_term(values, @safe)
      end

    values = [value | oldValues]
    values = :erlang.term_to_binary(values)
    Exleveldb.put(db, key, values)
    {:leveldb, db}
  end

  def put({:leveldb, db}, :list_truncated, key, {value, max, keep}) do
    key = :erlang.term_to_binary({:list, key})

    oldValues =
      case Exleveldb.get(db, key) do
        :not_found -> []
        {:ok, values} -> :erlang.binary_to_term(values, @safe)
      end

    count = Enum.count(oldValues)

    values =
      if count + 1 > max do
        oldValues
        |> Enum.reverse([value])
        |> Enum.drop(max - keep + 1)
        |> Enum.reverse()
      else
        [value | oldValues]
      end

    values = :erlang.term_to_binary(values)
    Exleveldb.put(db, key, values)
    {:leveldb, db}
  end

  def put({:leveldb, db}, :list_remove, key, value) do
    key = :erlang.term_to_binary({:list, key})

    oldValues =
      case Exleveldb.get(db, key) do
        :not_found -> []
        {:ok, values} -> :erlang.binary_to_term(values, @safe)
      end

    values = Enum.filter(oldValues, &(&1 != value))
    values = :erlang.term_to_binary(values)
    Exleveldb.put(db, key, values)
    {:leveldb, db}
  end

  def put({:leveldb, db}, :list_remove_many, key, values) do
    key = :erlang.term_to_binary({:list, key})

    oldValues =
      case Exleveldb.get(db, key) do
        :not_found -> []
        {:ok, values} -> :erlang.binary_to_term(values, @safe)
      end

    values =
      cond do
        is_list(values) -> Enum.reject(oldValues, &Enum.member?(values, &1))
        is_function(values, 1) -> Enum.reject(oldValues, values)
      end

    values = :erlang.term_to_binary(values)
    Exleveldb.put(db, key, values)
    {:leveldb, db}
  end

  def put({:leveldb, db}, :list_sorted_add, key, value) do
    key = :erlang.term_to_binary({:list, key})

    oldValues =
      case Exleveldb.get(db, key) do
        :not_found -> []
        {:ok, values} -> :erlang.binary_to_term(values, @safe)
      end

    values = Enum.sort([value | oldValues])
    values = :erlang.term_to_binary(values)
    Exleveldb.put(db, key, values)
    {:leveldb, db}
  end

  def put({:leveldb, db}, :list_sorted_remove, key, value) do
    key = :erlang.term_to_binary({:list, key})

    oldValues =
      case Exleveldb.get(db, key) do
        :not_found -> []
        {:ok, values} -> :erlang.binary_to_term(values, @safe)
      end

    values = Enum.filter(oldValues, &(&1 != value))
    values = :erlang.term_to_binary(values)
    Exleveldb.put(db, key, values)
    {:leveldb, db}
  end

  def put({:leveldb, db}, :set_add, key, value) do
    key = :erlang.term_to_binary({:set, key})

    oldValues =
      case Exleveldb.get(db, key) do
        :not_found -> %{}
        {:ok, values} -> :erlang.binary_to_term(values, @safe)
      end

    values = Map.put(oldValues, value, 1)
    values = :erlang.term_to_binary(values)
    Exleveldb.put(db, key, values)
    {:leveldb, db}
  end

  def put({:leveldb, db}, :set_remove, key, value) do
    key = :erlang.term_to_binary({:set, key})

    case Exleveldb.get(db, key) do
      :not_found ->
        {:leveldb, db}

      {:ok, values} ->
        oldValues = :erlang.binary_to_term(values, @safe)
        values = Map.delete(oldValues, value)
        values = :erlang.term_to_binary(values)
        Exleveldb.put(db, key, values)
        {:leveldb, db}
    end
  end

  def put(db, type, key, value) do
    IO.inspect(
      "Invalid DB put type of `#{inspect(type)}` of key `#{inspect(key)}` with value: #{
        inspect(value)
      }",
      label: :ERROR_DB_TYPE
    )

    db
  end

  def timeseries_inc(db, key) do
    put(db, :timeseries, key, 1)
    db
  end

  def get(db, type, key) when type in [:set, :list, :list_sorted, :list_truncated],
    do: get(db, type, key, [])

  def get(db, type, key), do: get(db, type, key, nil)

  def get(name, type, key, default) when is_atom(name) or is_binary(name) do
    get(get_db(name), type, key, default)
  end

  def get(%{db: db}, type, key, default) do
    get(db, type, key, default)
  end

  def get({:leveldb, db}, :kv, key, default) do
    key = :erlang.term_to_binary({:kv, key})

    case Exleveldb.get(db, key) do
      :not_found -> default
      {:ok, value} -> :erlang.binary_to_term(value, @safe)
    end
  end

  def get({:leveldb, db}, type, key, default)
      when type in [:list, :list_sorted, :list_truncated] do
    key = :erlang.term_to_binary({:list, key})

    case Exleveldb.get(db, key) do
      :not_found -> default
      {:ok, value} -> :erlang.binary_to_term(value, @safe)
    end
  end

  def get({:leveldb, db}, :set, key, default) do
    key = :erlang.term_to_binary({:set, key})

    case Exleveldb.get(db, key) do
      :not_found ->
        default

      {:ok, values} ->
        values = :erlang.binary_to_term(values, @safe)
        Map.keys(values)
    end
  end

  def get(_db, type, key, _default) do
    IO.inspect(
      "Invalid DB get type for `#{inspect(type)}` of key `#{inspect(key)}`",
      label: :ERROR_DB_TYPE
    )

    nil
  end

  def get_all(name), do: get_all(name, & &1)

  def get_all(name, fun) when is_atom(name) or is_binary(name) do
    get_all(get_db(name), fun)
  end

  def get_all({:leveldb, db}, fun) do
    Exleveldb.map(db, fn {key, value} ->
      key = :erlang.binary_to_term(key)
      value = :erlang.binary_to_term(value)
      fun.({key, value})
    end)
  end

  def delete(name, type, key) when is_atom(name) or is_binary(name) do
    delete(get_db(name), type, key)
  end

  def delete(%{db: db}, type, key) do
    delete(db, type, key)
  end

  def delete({:leveldb, db}, :kv, key) do
    key = :erlang.term_to_binary({:kv, key})
    Exleveldb.delete(db, key)
  end

  def delete(_db, type, key) do
    IO.inspect(
      "Invalid DB delete type for `#{inspect(type)}` of key `#{inspect(key)}`",
      label: :ERROR_DB_TYPE
    )

    nil
  end

  ## Internal

  def start_link() do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    {:ok, state}
  end

  def handle_call({:get_db, name}, _from, state) do
    active_storages = Application.get_env(@app_name, :active_storages, %{})
    filename = if(name == nil or name == "", do: "_db", else: "_db/db_#{name}")

    case active_storages[name] do
      nil ->
        IO.inspect(name, label: "Creating DB")

        case Exleveldb.open(filename) do
          {:ok, db} ->
            :ok =
              Application.put_env(
                @app_name,
                :active_storages,
                Map.put_new(active_storages, name, {:leveldb, db})
              )

            {:reply, {:leveldb, db}, state}

          {:error, reason} ->
            IO.inspect(reason, label: :DB_OPEN_ERROR)

            case Exleveldb.repair(filename) do
              :ok -> :ok
              {:error, reason} -> IO.inspect(reason, label: :DB_REPAIR_ERROR)
            end

            {:ok, db} = Exleveldb.open(filename)

            :ok =
              Application.put_env(
                @app_name,
                :active_storages,
                Map.put_new(active_storages, name, {:leveldb, db})
              )

            {:reply, {:leveldb, db}, state}
        end

      {:leveldb, db} = res when is_reference(db) ->
        {:reply, res, state}
    end
  rescue
    exc ->
      IO.inspect(exc, label: "StorageGetException")
      {:reply, nil, state}
  catch
    error ->
      IO.inspect(error, label: "StorageGetError")
      {:reply, nil, state}
  end

  def handle_call(_msg, _from, state) do
    {:reply, :unhandled, state}
  end

  def handle_cast(_msg, state) do
    {:noreply, state}
  end
end
