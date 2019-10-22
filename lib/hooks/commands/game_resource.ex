defmodule Overdiscord.Hooks.Commands.GameResource do
  require Logger

  alias __MODULE__.Game
  alias Overdiscord.Storage

  def parser_def() do
    %{
      strict: [
        verbose: :count
      ],
      aliases: [
        v: :verbose
      ],
      args: 0,
      # callback: {__MODULE__, :handle_cmd, []},
      sub_parsers: %{
        "start" => %{
          args: 0,
          strict: [
            player: :string
          ],
          aliases: [
            p: :player
          ],
          callback: {__MODULE__, :handle_cmd_start, []}
        },
        "status" => %{
          args: 0,
          strict: [
            # all: :boolean,
          ],
          callback: {__MODULE__, :handle_cmd_status, []}
        },
        "reset" => %{
          args: 0..1,
          strict: [
            confirm: :boolean
          ],
          callback: {__MODULE__, :handle_cmd_reset, []}
        },
        "search" => %{
          args: 0..99,
          strict: [],
          callback: {__MODULE__, :handle_cmd_search, []}
        },
        "info" => %{
          args: 1,
          strict: [],
          callback: {__MODULE__, :handle_cmd_info, []},
        },
        "build" => %{
          args: 0..1,
          strict: [],
          callback: {__MODULE__, :handle_cmd_build, []},
          sub_parsers: %{
            "info" => %{
              args: 1,
              strict: [],
              callback: {__MODULE__, :handle_cmd_build_info, []}
            }
          }
        }
      }
    }
  end

  def handle_cmd(cmd_path, args, params, unhandled_params) do
    IO.inspect({cmd_path, args, params, unhandled_params}, label: :handle_cmd)
  end

  def handle_cmd_start(%{auth: auth, params: params} = parsed) do
    IO.inspect(parsed, label: :handle_cmd_start)
    id = params[:player] || auth.id

    cond do
      id != auth.id && !auth.permissions.(Game.key(id)) ->
        "You do not have permission to create a game for player `#{id}`"

      Game.exists?(id) ->
        "A game for `#{id}` already exists"

      true ->
        _game = Game.create(id)
        "Created new game for player `#{id}`"
    end
  end

  def handle_cmd_info(%{auth: auth, args: [item]} = parsed) do
    game = Game.get!(auth)
    case Game.get_construction(game, item, true) do
      nil -> "Nothing found for the name `#{item}`"
      construction ->
        costs =
          (construction[:cost] || [])
          |> Enum.map(fn {name, amt} -> "#{name}:#{amt}" end)
          |> Enum.join(" ")
        desc = if(construction[:description] != nil, do: (costs == "" && "" || "\n> ") <> construction[:description])
        "> `#{item}`: #{costs}#{desc}"
    end
  end

  def handle_cmd_status(%{auth: auth} = parsed) do
    # IO.inspect(parsed, label: :handle_cmd_status)

    case Game.get(auth) do
      nil ->
        "Player `#{auth.id}` doesn't have an active game, run `start` to start a game"

      game ->
        res = Game.get_resources(game)
        Game.save(game) # Save the processed tick update

        [
          "Player `#{auth.id}` game: ",
          res
          |> Enum.map(fn {res, data} -> "#{res}:#{data}" end)
          |> Enum.sort()
          |> Enum.intersperse(" "),
          (res == [] && "No resources, try `search`ing") || []
        ]
        |> to_string()
    end
  end

  def handle_cmd_reset(%{auth: auth, params: params, args: args} = parsed) do
    # IO.inspect(parsed, label: :handle_cmd_reset)
    id = List.first(args) || auth.id

    cond do
      id != auth.id && !auth.permissions.(Game.key(id)) ->
        "Do not have access to reset the game for player `#{id}`"

      not Game.exists?(id) ->
        "Player `#{id}` doesn't have an active game."

      !params[:confirm] ->
        "Pass in `--confirm` to confirm full game deletion for player `#{id}`"

      true ->
        Game.delete(id)
        "Deleted entire game profile of player `#{id}`"
    end
  end

  def handle_cmd_search(%{auth: auth, args: args}) do
    possibles = [nil, "stone", "dirt", "sticks", "grass"]
    game = Game.get!(auth)

    case args do
      [] ->
        Enum.random(possibles)

      items ->
        items
        |> Enum.filter(&Enum.member?(possibles, &1))
        |> List.insert_at(0, nil)
        |> Enum.random()
    end
    |> case do
      nil ->
        "Found nothing"

      res ->
        baskets = Game.get_resource(game, "basket").amt
        mult = 1 + baskets
        units = Enum.random(1..4) * mult

        case Game.add_resource(game, res, units) do
          {:ok, game, resource, leftover, _} ->
            Game.save(game)

            "Found #{units} unit(s) of #{res}, now have #{resource} and #{leftover} was left behind"

          {:ok, game, resource} ->
            Game.save(game)
            "Found #{units} unit(s) of #{res}, now have #{resource}"

          {:error, reason} ->
            "Found #{units} unit(s) of #{res}, but #{reason}"
        end
    end
  end

  def handle_cmd_build(parsed) do
    # IO.inspect(parsed, label: :handle_cmd_buid)
    game = Game.get!(parsed)

    case parsed.args do
      [] ->
        constructs =
          game
          |> Game.get_constructions()
          |> Enum.map(&elem(&1, 0))
          |> Enum.join(" ")

        "Buildables: #{constructs}"

      [item] ->
        case Game.get_construction(game, item) do
          nil ->
            "Not a valid buildable: #{item}"

          construct ->
            case Game.construct(game, {item, construct}) do
              {:ok, game} ->
                Game.save(game)
                "Constructed: #{item}"

              {:error, reason} ->
                "Failed constructing `#{item}`: #{reason}"
            end
        end
    end
  end

  def handle_cmd_build_info(%{auth: auth, args: [item]}) do
    game = Game.get!(auth)

    case Game.get_construction(game, item) do
      nil ->
        "Not a valid buildable: #{item}"

      construct ->
        cost =
          (construct[:cost] || [])
          |> Enum.map(&"#{elem(&1, 0)}=#{elem(&1, 1)}")
          |> Enum.join(" ")

        requires =
          construct.requires
          |> Enum.map(& &1)

        "#{item}: Cost: #{cost}  Requires: #{requires}"
    end
  end

  defmodule Game do
    defmodule Resource do
      defstruct amt: 0, partial: 0.0, max: 0

      def new(res) do
        max =
          case res do
            basic when basic in ["stone", "dirt", "sticks", "grass", "hut"] -> 10
            _ -> 0
          end

        %__MODULE__{max: max}
      end
    end

    defimpl String.Chars, for: Resource do
      def to_string(%{amt: amt, partial: partial, max: max}) do
        partial = if(partial === 0.0, do: "", else: tl(Float.to_charlist(partial)))
        "#{amt}#{partial}/#{max}"
      end
    end

    defstruct id: nil, last_updated_at: NaiveDateTime.utc_now(), resources: %{}

    def id(%{id: id}), do: id(id)
    def id(%{auth: auth}), do: id(auth)
    def id(id) when is_binary(id), do: id

    def key(id) do
      {:game, :resource, :player, id(id)}
    end

    def get(auth, _opts \\ []) do
      case Storage.get(:games, :kv, key(auth), nil) do
        nil -> nil
        %__MODULE__{} = game -> tick(game)
      end
    end

    def get!(auth, opts \\ []) do
      get(auth, opts) || throw("Player is not in an active game")
    end

    def get_or_create(auth, opts \\ []) do
      case get(auth, opts) do
        nil -> create(auth, opts)
        %__MODULE__{} = game -> game
      end
    end

    def create(auth, _opts \\ []) do
      game = %__MODULE__{id: id(auth)}
      Storage.put(:games, :kv, key(game), game)
      game
    end

    def save(game, _opts \\ []) do
      Storage.put(:games, :kv, key(game), game)
    end

    def exists?(auth, opts \\ []) do
      case get(auth, opts) do
        nil -> false
        %__MODULE__{} -> true
      end
    end

    def delete(auth, _opts \\ []) do
      Storage.delete(:games, :kv, key(auth))
    end

    defp get_time_offset_mod(last, now, mod) do
      delta = now - last
      get_time_offset_mod(last, now, delta, mod)
    end
    defp get_time_offset_mod(last, now, delta, mod) do
      amt = div(delta, mod)
      leftover = rem(delta, mod)
      offset = rem(last, mod)
      extra = div(offset + leftover, mod) # TODO: Is this math correct?  Can it be simplified?
      amt + extra
    end

    def tickables() do
      [
        %{},
      ]
    end

    def tick(game) do
      last = game.last_updated_at
      now = Timex.to_unix(NaiveDateTime.utc_now())
      delta = now - last

      if delta > 0 do
        # TODO:  Convert this to the tickables format
        game = case get_resource(game, "dog") do
                 %{max: 0} -> game
                 %{amt: max, max: max} -> game
                 %{amt: amt, max: max} when amt < max ->
                   case min(get_time_offset_mod(last, now, delta, 60), max - amt) do
                     0 -> game
                     times ->
                       add_resource(game, "dog", times)
                   end
               end
        %{game | last_updated_at: now}
      else
        game
      end
    end

    def get_resources(game) do
      game.resources
      |> Enum.filter(fn {_res, data} ->
        # data.amt > 0 or data.partial > 0.0
        data.max > 0
      end)
    end

    def get_resource(game, res) do
      case game.resources[res] do
        nil -> Resource.new(res)
        resource -> resource
      end
    end

    def update_resource(game, res, resource) do
      %{game | resources: Map.put(game.resources, res, resource)}
    end

    def max_resource(game, res, max) do
      resource = get_resource(game, res)
      max = resource.max + max

      cond do
        max < 0 ->
          Logger.error("Game `#{res}` max reduced below 0 via `#{max}`: #{inspect(game)}")
          {:ok, "Error, report to @OvermindDL1"}

        max === 0 ->
          resource = Resource.new(0)
          {:ok, %{game | resources: Map.delete(game.resources, res)}, resource}

        true ->
          amt = min(resource.amt, max)
          partial = if(amt === max, do: 0.0, else: resource.partial)
          resource = %{resource | max: max, amt: amt, partial: partial}
          {:ok, update_resource(game, res, resource), resource}
      end
    end

    def add_resource(game, res, amt, partial \\ 0.0)
        when amt >= 0 and partial >= 0.0 and partial < 1.0 do
      resource = get_resource(game, res)
      amt = resource.amt + amt
      partial = resource.partial + partial
      {amt, partial} = if(partial >= 1.0, do: {amt + 1, partial - 1.0}, else: {amt, partial})

      cond do
        resource.max === 0 ->
          {:error, res <> " has no storage"}

        resource.amt === resource.max ->
          {:error, res <> " is too full"}

        amt > resource.max ->
          resource = %{resource | amt: resource.max, partial: 0.0}
          amt = amt - resource.max
          {:ok, update_resource(game, res, resource), resource, amt, partial}

        amt === resource.max and partial > 0.0 ->
          resource = %{resource | partial: 0.0}
          {:ok, update_resource(game, res, resource), resource, 0, partial}

        true ->
          resource = %{resource | amt: amt, partial: partial}
          {:ok, update_resource(game, res, resource), resource}
      end
    end

    def use_resource(game, res, amt, partial \\ 0.0)
        when amt >= 0 and partial >= 0.0 and partial < 1.0 do
      resource = get_resource(game, res)
      amt = resource.amt - amt
      partial = resource.partial - partial
      {amt, partial} = if(partial < 0.0, do: {amt - 1, partial + 1.0}, else: {amt, partial})

      cond do
        amt < 0 ->
          {:error, "not enough " <> res}

        true ->
          resource = %{resource | amt: amt, partial: partial}
          {:ok, update_resource(game, res, resource), resource}
      end
    end

    def constructions() do
      %{
        "dirt" => %{description: "A rather poor and non-sturdy building material"},
        "grass" => %{description: "A light though not strong building material"},
        "sticks" => %{description: "A decent building material scaffold"},
        "stone" => %{description: "A strong though heavy building material"},
        "hut" => %{
          description: "Increases storage of dirt, grass, sticks, and stone by 10 each",
          cost: %{"dirt" => 10, "grass" => 10, "sticks" => 10, "stone" => 10},
          requires: [],
          effects: [
            {:add_resource, 1},
            {:max_resource, "dirt", 10},
            {:max_resource, "grass", 10},
            {:max_resource, "sticks", 10},
            {:max_resource, "stone", 10},
          ],
        },
        "basket" => %{
          description: "Increases possible yield when `search`ing for each basket",
          cost: %{"grass" => 15, "sticks" => 15},
          requires: [
            {:>, {:resource, "hut"}, 0},
            {:<, {:resource, "basket"}, 2},
          ],
          effects: [
            {:if, {:==, :max_resource, 0}, {:max_resource, 2}},
            {:add_resource, 1},
            {:if, {:==, {:max_resource, "dogbed"}, 0}, {:max_resource, "dogbed", 10}},
          ],
        },
        "dogbed" => %{
          description: "Makes a dog bed, which will attract a dog",
          cost: %{"dirt" => 40, "grass" => 30, "sticks" => 10, "stone" => 40},
          requires: [
            {:>, {:max_resource, "dogbed"}, {:resource, "dogbed"}},
          ],
          effects: [
            {:resource, 1},
            {:max_resource, "dog", 1},
          ],
        }
      }
    end

    defp construction_is_allowed(game, {name, %{requires: requires} = data}) do
      Enum.all?(requires, &construction_is_allowed(game, {name, data}, &1))
    end
    defp construction_is_allowed(_game, _nc) do
      false
    end

    defp construction_is_allowed(game, name_construct, requirement)
    defp construction_is_allowed(game, _nc, :never), do: false
    defp construction_is_allowed(game, nc, {op, left, right}) when op in [:<, :>, :<=, :>=, :!=, :==] do
      left = construction_is_allowed_expr(game, nc, left)
      right = construction_is_allowed_expr(game, nc, right)
      case op do
        :< -> left < right
        :> -> left > right
        :<= -> left <= right
        :>= -> left >= right
        :!= -> left != right
        :== -> left == right
      end
    end

    defp construction_is_allowed_expr(game, name_construct, expr)
    defp construction_is_allowed_expr(_game, _nc, int) when is_integer(int), do: int
    defp construction_is_allowed_expr(game, {name, _construction}, :resource) do
      get_resource(game, name).amt
    end
    defp construction_is_allowed_expr(game, {name, _construction}, :max_resource) do
      get_resource(game, name).max
    end
    defp construction_is_allowed_expr(game, _nc, {:resource, res}) do
      get_resource(game, res).amt
    end
    defp construction_is_allowed_expr(game, _nc, {:max_resource, res}) do
      get_resource(game, res).max
    end

    def get_construction(game, name, force_get_if_have \\ false) do
      case constructions()[name] do
        nil ->
          nil

        construction ->
          cond do
            construction_is_allowed(game, {name, construction}) -> construction
            force_get_if_have && get_resource(game, name).max > 0 -> construction
            :else -> nil
          end
      end
    end

    def get_constructions(game) do
      constructions()
      |> Enum.filter(&construction_is_allowed(game, &1))
    end

    def construct(game, {name, construction}) do
      if not construction_is_allowed(game, {name, construction}) do
        {:error, "missing requirement"}
      else
        Enum.reduce_while(construction[:cost] || [], game, fn {res, amt}, game ->
          case use_resource(game, res, amt) do
            {:error, reason} -> {:halt, reason}
            {:ok, game, _resource} -> {:cont, game}
          end
        end)
        |> case do
          %__MODULE__{} = game ->
            construct_effect(game, {name, construction}, List.wrap(construction[:effects] || [:todo]))

          reason when is_binary(reason) ->
            {:error, reason}
        end
      end
    end

    defp construct_effect(game, name_construction, effect)
    defp construct_effect(game, nc, []), do: {:ok, game}
    defp construct_effect(game, nc, [head | tail]) do
      case construct_effect(game, {name, _construct} = nc, head) do
        {:ok, game} -> {:ok, game}
        {:ok, game, _} -> {:ok, game}
        {:ok, game, _, 0} -> {:ok, game}
        {:ok, game, _, leftover} -> {:error, "#{name} does not have enough space to put in resources, missing `#{leftover}` space"}
        {:error, reason} when is_binary(reason) -> {:error, reason}
      end
      |> case do
           {:error, reason} -> {:error, reason}
           {:ok, game} -> construct_effect(game, nc, tail)
         end
    end
    defp construct_effect(game, {name, _con}, {:add_resource, amt}), do: add_resource(game, name, amt)
    defp construct_effect(game, {name, _con}, {:max_resource, max}), do: max_resource(game, name, max)
    defp construct_effect(game, _, {:add_resource, res, amt}), do: add_resource(game, res, amt)
    defp construct_effect(game, _, {:max_resource, res, max}), do: max_resource(game, res, max)
    defp construct_effect(game, nc, ift) when elem(ift, 0) == :if do
      {pred, th, el} = case ift do
                         {:if, pred, th} -> {pred, List.wrap(th), []}
                         {:if, pred, th, el} -> {pred, List.wrap(th), List.wrap(el)}
                       end
      if construction_is_allowed(game, nc, pred) do
        construct_effect(game, nc, th)
      else
        construct_effect(game, nc, el)
      end
    end
  end
end
