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

  def handle_info({:received, msg, %{nick: nick, user: user} = auth, "#gt-dev" = chan}, state) do
    case msg do
      "!"<>_ -> :ok
      msg ->
        if(user === "~Gregorius", do: handle_greg(msg, state.client))
        msg = convert_message(msg)
        IO.inspect("Sending message from IRC to Discord: **#{nick}**: #{msg}")
        Alchemy.Client.send_message("320192373437104130", "**#{nick}:** #{msg}")
        message_extra(:msg, msg, auth, chan, state)
    end
    {:noreply, state}
  end

  def handle_info({:me, action, %{nick: nick, user: user} = auth, "#gt-dev" = chan}, state) do
    if(user === "~Gregorius", do: handle_greg(action, state.client))
    action = convert_message(action)
    IO.inspect("Sending emote From IRC to Discord: **#{nick}** #{action}")
    Alchemy.Client.send_message("320192373437104130", "_**#{nick}** #{action}_")
    message_extra(:me, action, auth, chan, state)
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
    IO.puts("Terminating IRC Bridge for reason: #{inspect reason}")
    # ExIrc.Client.quit(state.client, "Disconnecting for controlled shutdown")
    ExIrc.Client.stop!(state.client)
  end


  defp convert_message(msg) do
    msg
    |> String.replace(~R/\bbear989\b|\bbear989sr\b|\bbear\b/i, "<@225728625238999050>")
  end


  def message_cmd(call, args, auth, chan, state)
  def message_cmd("wiki", args, _auth, chan, state) do
    url = IO.inspect("https://en.wikipedia.org/wiki/#{URI.encode(args)}")
    message_cmd_url_with_summary(url, chan, state.client)
  end
  def message_cmd("ftbwiki", args, _auth, chan, state) do
    url = IO.inspect("https://ftb.gamepedia.com/#{URI.encode(args)}")
    message_cmd_url_with_summary(url, chan, state.client)
  end
  def message_cmd("logs", "", _auth, chan, state) do
    logmsg = ""
    ExIrc.Client.msg(state.client, :privmsg, chan, logmsg)
  end
  def message_cmd(_, _, _, _, _) do
    nil
  end

  def message_cmd_url_with_summary(url, chan, client) do
    ExIrc.Client.msg(client, :privmsg, chan, url)
    case IO.inspect(Overdiscord.SiteParser.get_summary_cached(url), label: :UrlSummary) do
      nil -> "No information found at URL"
      summary -> ExIrc.Client.msg(client, :privmsg, chan, summary)
    end
  end


  def message_extra(:msg, "?" <> cmd, auth, chan, state) do
    [call | args] = String.split(cmd, " ", [parts: 2])
    args = String.trim(to_string(args))
    message_cmd(call, args, auth, chan, state)
  end

  def message_extra(_type, msg, _auth, chan, %{client: client} = state) do
    # URL summary
    Regex.scan(~r"https?://[^)\]\s]+", msg, [captures: :first])
    |> Enum.map(fn
       [url] ->
         case IO.inspect(Overdiscord.SiteParser.get_summary_cached(url), label: :Summary) do
           nil -> nil
           summary ->
             if summary =~ ~r/Minecraft Mod by GregoriusT - overhauling your Minecraft experience completely/ do
               nil
             else
               ExIrc.Client.msg(client, :privmsg, "#gt-dev", summary)
             end
         end
      _ -> []
                                                               end)

    # Reddit subreddit links
    Regex.scan(~r"(^|[^/])(?<sr>r/\w*)($|[^/])"i, msg, [captures: :all])
    |> Enum.map(fn
      [_, _, sr, _] -> "https://www.reddit.com/#{sr}/"
      _ -> false
    end)
    |> Enum.filter(&(&1))
    |> Enum.join(" ")
    |> (fn
      "" -> nil
      srs -> ExIrc.Client.msg(client, :privmsg, chan, srs)
    end).()
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
