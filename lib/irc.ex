defmodule Overdiscord.IRC.Bridge do
  defmodule State do
    defstruct [
      host: "irc.esper.net",
      port: 6667,
      pass: System.get_env("OVERBOT_PASS"),
      nick: "overbot",
      user: System.get_env("OVERBOT_USER"),
      name: "overbot",
      ready: false,
      client: nil,
    ]
  end

  def send_msg("", _), do: nil
  def send_msg(_, ""), do: nil
  def send_msg(nick, msg) do
    IO.inspect({"Casting", nick, msg})
    :gen_server.cast(:irc_bridge, {:send_msg, nick, msg})
  end

  def list_users() do
    IO.inspect("Listing users")
    :gen_server.cast(:irc_bridge, :list_users)
  end

  def start_link(client, state \\ %State{}) do
    IO.inspect("Launching IRC Bridge")
    :gen_server.start_link({:local, :irc_bridge}, __MODULE__, %{state | client: client}, [])
  end


  def init(state) do
    IO.inspect("Starting IRC Bridge... #{inspect self()}")
    ExIrc.Client.add_handler(state.client, self())

    ExIrc.Client.connect!(state.client, state.host, state.port)
    {:ok, state}
  end

  def handle_cast({:send_msg, nick, msg}, state) do
    ExIrc.Client.msg(state.client, :privmsg, "#gt-dev", "#{nick}: #{msg}")
    {:noreply, state}
  end

  def handle_cast(:list_users, state) do
    users= ExIrc.Client.channel_users(state.client, "#gt-dev")
    users = Enum.join(users, " ")
    Alchemy.Client.send_message("320192373437104130", "Users: #{users}")
    {:noreply, state}
  end


  def handle_info({:connected, _server, _port}, state) do
    IO.inspect("connecting bridge...")
    ExIrc.Client.logon(state.client, state.pass, state.nick, state.user, state.name)
    {:noreply, state}
  end

  def handle_info(:logged_in, state) do
    ExIrc.Client.join(state.client, "#gt-dev")
    {:noreply, state}
  end

  def handle_info({:joined, "#gt-dev"}, state) do
    state = %{state | ready: true}
    {:noreply, state}
  end

  def handle_info({:received, msg, %{nick: nick}, "#gt-dev"}, state) do
    case msg do
      "!"<>_ -> :ok
      msg ->
        IO.inspect("Sending message from IRC to Discord: **#{nick}**: #{msg}")
        Alchemy.Client.send_message("320192373437104130", "**#{nick}:** #{msg}")
    end
    {:noreply, state}
  end

  def handle_info({:me, action, %{nick: nick, user: _user}, "#gt-dev"}, state) do
    IO.inspect("Sending emote From IRC to Discord: **#{nick}** #{action}")
    Alchemy.Client.send_message("320192373437104130", "_**#{nick}** #{action}_")
    {:noreply, state}
  end

  def handle_info({:topic_changed, _room, _topic}, state) do
    {:noreply, state}
  end

  def handle_info({:names_list, _channel, _names}, state) do
    {:noreply, state}
  end

  def handle_info({:unrecognized, _type, _msg}, state) do
    {:noreply, state}
  end

  def handle_info(:disconnected, state) do
    ExIrc.Client.connect!(state.client, state.host, state.port)
    {:noreply, state}
  end


  def handle_info(msg, state) do
    IO.inspect("Unknown IRC message: #{inspect msg}")
    {:noreply, state}
  end




  def terminate(reason, state) do
    IO.inspect("Terminating IRC Bridge for reason: #{reason}")
    # ExIrc.Client.quit(state.client, "Disconnecting for controlled shutdown")
    ExIrc.Client.stop!(state.client)
  end
end
