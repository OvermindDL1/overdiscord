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
    #IO.inspect({"Casting", nick, msg})
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
    msg
    |> String.split("\n")
    |> Enum.each(fn line ->
      ExIrc.Client.msg(state.client, :privmsg, "#gt-dev", "#{nick}: #{line}")
      Process.sleep(100)
    end)
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
    #IO.inspect({state.client, state.pass, state.nick, state.user, state.name})
    Process.sleep(20)
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

  def handle_info({:received, msg, %{nick: nick, user: user}, "#gt-dev"}, state) do
    case msg do
      "!"<>_ -> :ok
      msg ->
        if(user === "~Gregorius", do: handle_greg(msg, state.client))
        msg = convert_message(msg)
        IO.inspect("Sending message from IRC to Discord: **#{nick}**: #{msg}")
        Alchemy.Client.send_message("320192373437104130", "**#{nick}:** #{msg}")
        message_extra(msg, state.client)
    end
    {:noreply, state}
  end

  def handle_info({:me, action, %{nick: nick, user: user}, "#gt-dev"}, state) do
    if(user === "~Gregorius", do: handle_greg(action, state.client))
    action = convert_message(action)
    IO.inspect("Sending emote From IRC to Discord: **#{nick}** #{action}")
    Alchemy.Client.send_message("320192373437104130", "_**#{nick}** #{action}_")
    message_extra(action, state.client)
    {:noreply, state}
  end

  def handle_info({:topic_changed, _room, _topic}, state) do
    {:noreply, state}
  end

  def handle_info({:names_list, _channel, _names}, state) do
    {:noreply, state}
  end

  def handle_info({:unrecognized, type, msg}, state) do
    IO.inspect("Unrecognized Message with type #{inspect type} and msg of: #{inspect msg}")
    {:noreply, state}
  end

  def handle_info({:joined, chan, %{host: host, nick: nick, user: user}}, state) do
    IO.inspect("#{chan}: User `#{user}` with nick `#{nick}` joined from `#{host}`")
    {:noreply, state}
  end

  def handle_info({:quit, msg, %{host: host, nick: nick, user: user}}, state) do
    IO.inspect("User `#{user}` with nick `#{nick}` at host `#{host}` quit with message: #{msg}")
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


  defp convert_message(msg) do
    msg
    |> String.replace(~R/\bbear989\b|\bbear989sr\b|\bbear\b/i, "<@225728625238999050>")
  end

  def message_extra(msg, client) do
    Regex.scan(~r"https?://[^)\]\s]+", msg, [captures: :first])
    |> Enum.map(fn
      [url] ->
        try do
          case OpenGraph.parse(url) do
          {:ok, %{description: desc, title: title, image: _image, url: _canurl} = og} ->
              IO.inspect(og, label: :OpenGraph)
              title = String.trim(to_string(List.first(String.split(title, "\n"))))
              desc = String.trim(to_string(List.first(String.split(desc, "\n"))))
              case {title, desc} do
                {"", _} -> []
                {"Imgur: " <> _, _} -> []
                {_, "Imgur: " <> _} ->
                  ExIrc.Client.msg(client, :privmsg, "#gt-dev", "Imgur: #{title}")
                _ ->
                  data =
                    if title == desc do
                      "<Link Title> #{title}"
                    else
                      "<Link Details> #{title} : #{desc}"
                    end
                  ExIrc.Client.msg(client, :privmsg, "#gt-dev", data)
              end
            err -> IO.inspect(err, label: :OpenGraphError)
          end
        rescue _ -> []
        catch _ -> []
        end
      _ -> []
     end)
end



  defp handle_greg(msg, client) do
    msg = String.downcase(msg)
    cond do
      IO.inspect(String.jaro_distance("good night/bye everyone o/", msg), label: :Distance) > 0.93 ->
        ExIrc.Client.msg(client, :privmsg, "#gt-dev", Enum.random(farewells()))
      true -> :ok
    end
  end



  defp farewells, do: [
    "Fare thee well!",
    "Enjoy!",
    "Bloop!",
    "Be well",
    "Good bye",
    "See you later",
    "Have fun!",
  ]
end
