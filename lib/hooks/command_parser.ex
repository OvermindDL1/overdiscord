defmodule Overdiscord.Hooks.CommandParser do
  @moduledoc ~S"""
  """

  @allowed_types %{ElixirParse.default_allowed_types() | naked_string: true}

  @doc ~S"""
  """
  def handle_command(auth, event_data, prefix \\ "?")

  def handle_command(_auth, %{reply?: true}, _) do
    # Ignore reply messages
    nil
  end

  def handle_command(auth, %{msg: msg} = event_data, prefix) do
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

  defp call_command(auth, "echo", unparsed_args, opts) do
    if auth.permissions.({:cmd, "echo"}) do
      Overdiscord.EventPipe.inject(auth, %{msg: unparsed_args, reply?: true})
    else
      Overdiscord.EventPipe.inject(auth, %{msg: "does not have access to `echo`", reply?: true})
    end
  end
end
