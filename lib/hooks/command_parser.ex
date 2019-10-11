defmodule Overdiscord.Hooks.CommandParser do
  @moduledoc ~S"""
  """

  require Logger

  alias Overdiscord.Hooks.Commands

  @allowed_types %{ElixirParse.default_allowed_types() | naked_string: true}

  @parse_commands %{
    "g" => Commands.GameResource.parser_def()
  }

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
        IO.inspect({:auth, :respond, :invalid_input, invalid})

      {:ok, cmd, unparsed_args} ->
        IO.inspect({cmd, unparsed_args})
        call_command(auth, cmd, unparsed_args, prefix: prefix)
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
    case @parse_commands[cmd] do
      nil -> nil
      parser ->
        split_args =
          Regex.scan(~R/(?:"((?:\\.*|[^"])+)"|([^\s]+))/, unparsed_args, capture: :all_but_first)
          |> List.flatten()
          |> Enum.filter(&(&1 != ""))
          |> Enum.map(&String.replace(&1, ~R/\\./, fn "\\" <> s -> s end))

        handle_option_parser_cmd(parser, split_args, get_callback(parser[:callback]), auth, cmd, unparsed_args, opts)
        |> IO.inspect(label: :Parsed)
        |> case do
             {:ok, parsed} -> Logger.info(inspect parsed)
             {:error, reason} -> Overdiscord.EventPipe.inject(auth, %{msg: reason, reply?: true})
           end
    end
  end

  defp get_callback(cb, fallback \\ {__MODULE__, :unhandled_callback, []})
  defp get_callback(nil, fallback), do: fallback
  defp get_callback(module, fallback) when is_atom(module) do
    if :erlang.function_exported(module, :handle_cmd, 3) do
      {module, :handle_cmd, []}
    else
      Logger.warn("Callback module `#{module}` has no `handle_cmd/3` function")
      fallback
    end
  end
  defp get_callback({module, fun, extra_args} = mfa, fallback) when is_atom(module) and is_atom(fun) and is_list(extra_args) do
    if :erlang.function_exported(module, fun, 3 + length(extra_args)) do
      mfa
    else
      Logger.warn("Callback `#{module}.#{fun}/#{3 + length(extra_args)}` does not exist, extra args: #{inspect extra_args}")
      fallback
    end
  end

  defp escape_inline_code(string) do
    count =
      string
      |> String.graphemes()
      |> Enum.count(&(&1 == "`"))
    delim = String.duplicate("`", count + 1)
    delim <> string <> delim
  end

  defp handle_option_parser_cmd(parser, args, cb, auth, cmd, unparsed_args, opts) do
    parser
    |> Map.take([:strict, :aliases])
    |> Enum.into([])
    |> handle_option_parser_cmd([], [], [cmd], parser, args, cb, auth, cmd, unparsed_args, opts)
  end

  defp handle_option_parser_cmd(_parser_args, parsed_params, parsed_args, parsed_cmds, _parser, ["--" | args], cb, _auth, _cmd, _unparsed_args, _opts) do
    {:ok, %{params: parsed_params, args: Enum.reverse(parsed_args, args), cmds: Enum.reverse(parsed_cmds, callback: cb)}}
  end
  defp handle_option_parser_cmd(parser_args, parsed_params, parsed_args, parsed_cmds, parser, args, cb, auth, cmd, unparsed_args, opts) do
    case OptionParser.next(args, parser_args) do
      {:ok, key, value, args} -> handle_option_parser_cmd(parser_args, [{key, value} | parsed_params], parsed_args, parsed_cmds, parser, args, cb, auth, cmd, unparsed_args, opts)
      {:invalid, key, value, _rest} -> {:error, "#{escape_inline_code key} was passed an invalid value of #{escape_inline_code value} for this command"}
      {:undefined, key, _value, _rest} -> {:error, "#{escape_inline_code key} is not a valid switch for this command"}
      {:error, []} -> {:ok, %{params: parsed_params, args: Enum.reverse(parsed_args), cmds: Enum.reverse(parsed_cmds), callback: cb}}
      {:error, [subcmd | args] = rest} ->
        case parser[:sub_parsers][subcmd] do
          nil -> {:ok, %{params: parsed_params, args: Enum.reverse(parsed_args, rest), cmds: Enum.reverse(parsed_cmds), callback: cb}}
          parser ->
            parser
            |> Map.take([:strict, :aliases])
            |> Enum.into([])
            |> handle_option_parser_cmd(parsed_params, parsed_args, [subcmd | parsed_cmds], parser, args, get_callback(parser[:callback], cb), auth, cmd, unparsed_args, opts)
        end
    end
  end
end
