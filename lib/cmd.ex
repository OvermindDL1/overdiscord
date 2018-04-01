import ProtocolEx

defprotocol_ex Overdiscord.Cmd do
  # @moduledoc ~S"""
  # This is the basic Protocol to dispatch among commands
  # """

  def task_handle_cmd(type, possible_auth \\ :console, cmd) do
    # Run in parent task
    auth = Overdiscord.Auth.to_auth(possible_auth)
    Task.async(__MODULE__, :handle_cmd, [type, auth, cmd])
  rescue
    exc ->
      IO.inspect(exc, label: "CmdException")
      IO.puts(Exception.message(exc))
      :error
  catch
    error ->
      IO.inspect(error, label: "CmdError")
      :error
  end

  def handle_cmd(type, possible_auth \\ :console, cmd) do
    auth = Overdiscord.Auth.to_auth(possible_auth)
    process(type, [], auth, cmd)
  rescue
    exc ->
      IO.inspect(exc, label: "CmdException")
      IO.puts(Exception.message(exc))
      :error
  catch
    error ->
      IO.inspect(error, label: "CmdError")
      :error
  end

  def process(type, stack, auth, cmd)
end
