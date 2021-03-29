defmodule Overdiscord.Hooks.CommandParser do
  @moduledoc ~S"""
  """

  require Logger

  alias Overdiscord.Hooks.Commands

  @allowed_types %{ElixirParse.default_allowed_types() | naked_string: true}

  def parse_commands() do
    %{
      "h" => %{
        strict: [],
        aliases: [],
        args: 0..99,
        callback: {__MODULE__, :handle_help, []},
        help: %{
          nil:
            "Shows all commands or if a command path is passed in then shows the help for that command"
        }
      },
      "g" => Commands.GameResource.parser_def(),
      "gt6" => Commands.GT6.parser_def(),
      "system" => Commands.System.parser_def(),
      "todo" => Commands.Todo.parser_def(),
      "web" => Commands.Web.parser_def()
    }
  end

  def log(msg, type \\ :warn)

  def log(msg, type) when is_binary(msg) do
    Logger.log(type, msg)
    msg
  end

  def log(msg, type) do
    log(inspect(msg), type)
  end

  @doc ~S"""
  """
  def handle_command(auth, event_data, prefix \\ "?")

  def handle_command(_auth, %{reply?: true}, _) do
    # Ignore reply messages
    nil
  end

  def handle_command(auth, %{msg: msg} = _event_data, prefix) do
    prefix_size = byte_size(prefix)
    <<_skip::binary-size(prefix_size), msg::binary>> = msg

    case ElixirParse.parse(msg, allowed_types: @allowed_types) do
      {:error, invalid} ->
        IO.inspect({:auth, :respond, :invalid_input, invalid}, label: :HandleCommandError)

      {:ok, cmd, unparsed_args} ->
        IO.inspect({cmd, unparsed_args}, label: :HandleCommandOk)
        call_command(auth, cmd, unparsed_args, prefix: prefix)
    end
  end

  def lookup_command(cmd) do
    cmds = parse_commands()

    case cmds[cmd] do
      nil ->
        cmds
        |> Enum.flat_map(fn
          {new_cmd, %{hoist: hoists} = parser} ->
            case hoists[cmd] do
              nil ->
                []

              false ->
                []

              expansion when is_binary(expansion) ->
                [{new_cmd, expansion}]

              true ->
                [{new_cmd, cmd}]
            end

          _ ->
            []
        end)
        |> case do
          [] ->
            nil

          [{new_cmd, prefix_unparsed_args}] ->
            {cmds[new_cmd], prefix_unparsed_args}

          many when is_list(many) ->
            {{:ambiguous, many}, ""}
        end

      parser ->
        {parser, ""}
    end
  end

  defp call_command(auth, cmd, unparsed_args, opts)

  defp call_command(auth, "echo", unparsed_args, _opts) do
    if auth.permissions.({:cmd, "echo"}) do
      Overdiscord.EventPipe.inject(auth, %{msg: unparsed_args, reply?: true})
    else
      Overdiscord.EventPipe.inject(auth, %{msg: "does not have access to `echo`", reply?: true})
    end
  end

  defp call_command(auth, cmd, unparsed_args, opts) do
    # TODO: Add permission check on all commands for any access at all once default permissions are built
    {parser, prefix_args} = lookup_command(cmd)

    case parser do
      nil ->
        nil

      {:ambiguous, amb} ->
        "Ambiguous command, choices: #{inspect(amb)}"

      parser ->
        unparsed_args = String.trim("#{prefix_args} #{unparsed_args}")

        split_args =
          Regex.scan(~R/(?:"((?:\\.*|[^"])+)"|([^\s]+))/, unparsed_args, capture: :all_but_first)
          |> List.flatten()
          |> Enum.filter(&(&1 != ""))
          |> Enum.map(&String.replace(&1, ~R/\\./, fn "\\" <> s -> s end))

        handle_option_parser_cmd(
          parser,
          split_args,
          get_callback(parser[:callback]),
          auth,
          cmd,
          unparsed_args,
          opts
        )
        # |> IO.inspect(label: :Parsed)
        |> case do
          {:error, reason} ->
            Overdiscord.EventPipe.inject(auth, %{msg: reason, reply?: true})

          {:ok, %{callback: {mod, fun, extra}} = parsed} ->
            parsed = Map.put_new(parsed, :base_parser, parser)
            # Logger.info(inspect parsed)
            case apply(mod, fun, [parsed] ++ extra) do
              nil ->
                :ok

              :ok ->
                :ok

              string when is_binary(string) ->
                Overdiscord.EventPipe.inject(auth, %{msg: string, reply?: true})

              map when is_map(map) ->
                Overdiscord.EventPipe.inject(auth, map)
            end
        end
    end
  end

  def unhandled_callback(%{base_parser: parser, cmds: cmds} = _parsed) do
    "Incomplete command, see help:\n" <> get_help_from_parser(cmds, parser)
  end

  def unhandled_callback(%{cmds: cmds, parser: %{callback: cb}}, :invalid_callback) do
    "@OvermindDL1 Command `#{inspect(cmds)}` has an invalid callback of: `#{inspect(cb)}`"
    |> log(:error)
  end

  def unhandled_callback(
        %{cmds: [_self | cmds] = all_cmds, base_parser: parser},
        :invalid_callback
      ) do
    case Enum.reduce(cmds, {parser, nil}, fn cmd, {parser, cb} ->
           {parser[:sub_parsers][cmd], parser[:callback] || cb}
         end) do
      {nil, _cb} ->
        "@OvermindDL1 Parsed Commands `#{inspect(all_cmds)}` don't actually exist in parser!"
        |> log(:error)

      {_parser, cb} ->
        "@OvermindDL1 Command `#{inspect(all_cmds)}` has base invalid callback of: `#{inspect(cb)}`"
        |> log(:error)
    end
  end

  def handle_help(%{args: []}) do
    commands =
      parse_commands()
      |> Enum.map(fn {key, parser} ->
        help =
          case parser[:help][nil] do
            nil -> ""
            txt -> ": " <> txt
          end

        {req, opt} = get_args_required_from_parser(parser)
        req = if(req > 0 or opt > 0, do: "/#{req}", else: "")
        opt = if(opt > 0, do: "-#{opt}", else: "")
        "`#{key}#{req}#{opt}`#{help}"
      end)
      |> Enum.sort()

    "Listing all commands:\n\t" <> Enum.join(commands, "\n\t")
  end

  def handle_help(%{args: [cmd | _] = args}) do
    case parse_commands()[cmd] do
      nil ->
        "Command `#{cmd}` does not exist"

      parser ->
        get_help_from_parser(args, parser)
    end
  end

  defp get_help_from_parser(cmds, parser)

  defp get_help_from_parser(cmds, %{strict: strict} = parser) do
    aliases = parser[:aliases] || []
    sub_parsers = parser[:sub_parsers] || %{}
    aliases = Enum.group_by(aliases, &elem(&1, 1), &elem(&1, 0))

    help =
      case parser[:help][nil] do
        nil -> ""
        txt -> ": " <> txt
      end

    params =
      strict
      |> Enum.map(fn {key, type} ->
        aliases =
          case aliases[key] do
            nil -> ""
            aliases -> " (`-" <> Enum.join(aliases, "` `-") <> "`)"
          end

        help =
          case parser[:help][key] do
            nil -> ""
            txt -> ": " <> txt
          end

        type =
          case type do
            :count -> " <counted>"
            :boolean -> "`=<[true]/false>`"
            unhandled -> "=<#{unhandled}>"
          end

        "`--" <> to_string(key) <> "`" <> type <> aliases <> help
      end)
      |> Enum.sort()

    {req, opt} = get_args_required_from_parser(parser)
    req = if(req > 0 or opt > 0, do: "/#{req}", else: "")
    opt = if(opt > 0, do: "-#{opt}", else: "")
    params = if(params == [], do: "", else: "\n\t\t" <> Enum.join(params, "\n\t\t"))

    case cmds do
      [self] ->
        subs =
          sub_parsers
          |> Enum.map(fn {cmd, parser} ->
            help =
              case parser[:help][nil] do
                nil -> ""
                txt -> ": " <> txt
              end

            {req, opt} = get_args_required_from_parser(parser)
            req = if(req > 0 or opt > 0, do: "/#{req}", else: "")
            opt = if(opt > 0, do: "-#{opt}", else: "")
            "`" <> cmd <> req <> opt <> "`" <> help
          end)
          |> Enum.sort()

        subs = if(subs == [], do: "", else: "\n\t\t" <> Enum.join(subs, "\n\t\t"))
        "\t`#{self}#{req}#{opt}`#{help}#{params}#{subs}"

      [self | [next | _] = rest] ->
        case sub_parsers[next] do
          nil ->
            "\t`#{next}` is not a valid sub command of `#{self}`"

          parser ->
            rest = get_help_from_parser(rest, parser)
            "\t`#{self}#{req}#{opt}`#{help}#{params}\n#{rest}"
        end
    end
  end

  defp get_callback(cb, fallback \\ {__MODULE__, :unhandled_callback, []})
  defp get_callback(nil, fallback), do: fallback

  defp get_callback(module, _fallback) when is_atom(module) do
    if :erlang.function_exported(module, :handle_cmd, 1) do
      {module, :handle_cmd, []}
    else
      Logger.warn("Callback module `#{module}` has no `handle_cmd/1` function")
      {__MODULE__, :unhandled_callback, [:invalid_callback]}
    end
  end

  defp get_callback({module, fun, extra_args} = mfa, _fallback)
       when is_atom(module) and is_atom(fun) and is_list(extra_args) do
    if :erlang.function_exported(module, fun, 1 + length(extra_args)) do
      mfa
    else
      Logger.error(
        "Callback `#{module}.#{fun}/#{1 + length(extra_args)}` does not exist, extra args: #{
          inspect(extra_args)
        }"
      )

      {__MODULE__, :unhandled_callback, [:invalid_callback]}
    end
  end

  defp escape_inline_code(string) when is_binary(string) do
    count =
      string
      |> String.graphemes()
      |> Enum.count(&(&1 == "`"))

    delim = String.duplicate("`", count + 1)
    delim <> string <> delim
  end

  defp escape_inline_code(nil) do
    ""
  end

  defp get_args_required_from_parser(%{args: i}) when is_integer(i) and i >= 0, do: {i, 0}

  defp get_args_required_from_parser(%{args: req..opt})
       when is_integer(req) and is_integer(opt) and
              req >= 0 and opt >= 0,
       do: {req, opt - req}

  defp get_args_required_from_parser(%{}), do: {0, 0}

  defp handle_option_parser_cmd(parser, args, cb, auth, cmd, unparsed_args, opts) do
    parser
    |> Map.take([:strict, :aliases])
    |> Enum.into([])
    |> handle_option_parser_cmd(
      get_args_required_from_parser(parser),
      [],
      [],
      [cmd],
      parser,
      args,
      cb,
      auth,
      cmd,
      unparsed_args,
      opts
    )
  end

  defp handle_option_parser_cmd(
         _parser_args,
         {req, opt},
         parsed_params,
         parsed_args,
         parsed_cmds,
         parser,
         ["--" | args],
         cb,
         auth,
         _cmd,
         unparsed_args,
         _opts
       ) do
    # IO.inspect({req, opt, args, parsed_params, parsed_args, parsed_cmds}, label: :ParsingDashes)
    args_length = length(args)

    cond do
      args_length < req ->
        {:error, "Missing required arguments"}

      args_length > req + opt ->
        {:error, "Too many arguments"}

      :else ->
        {:ok,
         %{
           params: parsed_params,
           args: Enum.reverse(parsed_args, args),
           cmds: Enum.reverse(parsed_cmds),
           callback: cb,
           auth: auth,
           unparsed_args: unparsed_args,
           parser: parser
         }}
    end

    # |> IO.inspect(label: :ParsingDashesReturn)
  end

  defp handle_option_parser_cmd(
         parser_args,
         {req, opt},
         parsed_params,
         parsed_args,
         parsed_cmds,
         parser,
         args,
         cb,
         auth,
         cmd,
         unparsed_args,
         opts
       ) do
    # IO.inspect({req, opt, args, parsed_params, parsed_args, parsed_cmds}, label: :Parsing)
    case OptionParser.next(args, parser_args) do
      {:ok, key, value, args} ->
        handle_option_parser_cmd(
          parser_args,
          {req, opt},
          [{key, value} | parsed_params],
          parsed_args,
          parsed_cmds,
          parser,
          args,
          cb,
          auth,
          cmd,
          unparsed_args,
          opts
        )

      {:invalid, key, value, _rest} ->
        {:error,
         "#{escape_inline_code(key)} was passed an invalid value of #{escape_inline_code(value)} for this command"}

      {:undefined, key, _value, _rest} ->
        {:error, "#{escape_inline_code(key)} is not a valid switch for this command"}

      {:error, []} ->
        if req == 0 do
          {:ok,
           %{
             params: parsed_params,
             args: Enum.reverse(parsed_args),
             cmds: Enum.reverse(parsed_cmds),
             callback: cb,
             auth: auth,
             unparsed_args: unparsed_args,
             parser: parser
           }}
        else
          {:error, "Missing required arguments"}
        end

      {:error, [subcmd | args]} ->
        if req == 0 do
          # sub command
          case parser[:sub_parsers][subcmd] do
            nil ->
              # self is a command
              case parser[:sub_parsers][nil] do
                nil ->
                  if opt == 0 do
                    {:error, "Too many arguments"}
                  else
                    handle_option_parser_cmd(
                      parser_args,
                      {req, opt - 1},
                      parsed_params,
                      [subcmd | parsed_args],
                      parsed_cmds,
                      parser,
                      args,
                      cb,
                      auth,
                      cmd,
                      unparsed_args,
                      opts
                    )

                    # {:ok, %{params: parsed_params, args: Enum.reverse(parsed_args, rest), cmds: Enum.reverse(parsed_cmds), callback: cb, auth: auth, unparsed_args: unparsed_args, parser: parser}}
                  end

                parser ->
                  parser
                  |> Map.take([:strict, :aliases])
                  |> Enum.into([])
                  |> handle_option_parser_cmd(
                    get_args_required_from_parser(parser),
                    parsed_params,
                    parsed_args,
                    parsed_cmds,
                    parser,
                    args,
                    get_callback(parser[:callback], cb),
                    auth,
                    cmd,
                    unparsed_args,
                    opts
                  )
              end

            parser ->
              parser
              |> Map.take([:strict, :aliases])
              |> Enum.into([])
              |> handle_option_parser_cmd(
                get_args_required_from_parser(parser),
                parsed_params,
                parsed_args,
                [subcmd | parsed_cmds],
                parser,
                args,
                get_callback(parser[:callback], cb),
                auth,
                cmd,
                unparsed_args,
                opts
              )
          end
        else
          handle_option_parser_cmd(
            parser_args,
            {req - 1, opt},
            parsed_params,
            [subcmd | parsed_args],
            parsed_cmds,
            parser,
            args,
            cb,
            auth,
            cmd,
            unparsed_args,
            opts
          )
        end
    end

    # |> IO.inspect(label: :ParsingReturn)
  end
end
