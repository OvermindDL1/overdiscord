defmodule Overdiscord.IRC.Bridge do
  # TODO:  XKCD mapping

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
    |> Enum.flat_map(&split_at_irc_max_length/1)
    |> Enum.each(fn line ->
      Enum.map(split_at_irc_max_length("#{nick}: #{line}"), fn irc_msg ->
        ExIrc.Client.msg(state.client, :privmsg, "#gt-dev", irc_msg)
        Process.sleep(200)
      end)
      message_extra(:send_msg, msg, nick, "#gt-dev", state)
      Process.sleep(200)
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
      "!"<> _ -> :ok
      omsg ->
        if(user === "~Gregorius", do: handle_greg(msg, state.client))
        msg = convert_message_to_discord(msg)
        IO.inspect("Sending message from IRC to Discord: **#{nick}**: #{msg}")
        Alchemy.Client.send_message("320192373437104130", "**#{nick}:** #{msg}")
        message_extra(:msg, omsg, auth, chan, state)
    end
    {:noreply, state}
  end

  def handle_info({:received, msg, %{nick: _nick, user: _user} = auth, chan}, state) do
    case msg do
      "!" <> _ -> :ok
      msg -> message_extra(:msg, msg, auth, chan, state)
    end
    {:noreply, state}
  end

  def handle_info({:received, msg, %{nick: nick, user: _user} = auth}, state) do
    case msg do
      "!" <> _ -> :ok
      msg -> message_extra(:msg, msg, auth, nick, state)
    end
    {:noreply, state}
  end

  def handle_info({:me, action, %{nick: nick, user: user} = auth, "#gt-dev" = chan}, state) do
    if(user === "~Gregorius", do: handle_greg(action, state.client))
    action = convert_message_to_discord(action)
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


  defp convert_message_to_discord(msg) do
    msg =
      Regex.replace(~R/([^<]|^)\B@([a-zA-Z0-9]+)\b/, msg, fn(full, pre, username) ->
        down_username = String.downcase(username)
        case Alchemy.Cache.search(:members, fn
          %{user: %{username: ^username}} -> true
          %{user: %{username: discord_username}} ->
            down_username == String.downcase(discord_username)
          _ -> false
        end) do
          [%{user: %{id: id}}] -> [pre, ?<, ?@, id, ?>]
          s ->
            IO.inspect(s, label: :MemberNotFound)
            full
        end
      end)

    msg
    |> String.replace(~R/\bbear989\b|\bbear989sr\b|\bbear\b/i, "<@225728625238999050>")
    |> String.replace(~R/\bqwertygiy\b|\bqwerty\b|\bqwertz\b/i, "<@80832726017511424>")
    |> String.replace(~R/\bandyafw\b|\bandy\b/i, "<@179586256752214016>")
    |> String.replace(~R/\bcrazyj1984\b|\bcrazyj\b/i, "<@225742972145238018>")
  end


  def alchemy_channel(), do: "320192373437104130"

  def send_msg_both(msg, chan, client) do
    ExIrc.Client.msg(client, :privmsg, chan, msg)
    Alchemy.Client.send_message(alchemy_channel(), msg)
    nil
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
    msg = "Please supply any and all logs"
    send_msg_both(msg, chan, state.client)
  end
  def message_cmd("factorio", "demo", _auth, chan, state) do
    msg = "Try the Factorio Demo at https://factorio.com/download-demo and you'll love it!"
    send_msg_both(msg, chan, state.client)
  end
  def message_cmd("factorio", _args, _auth, chan, state) do
    msg = "Factorio is awesome!  See the demonstration video at https://factorio.com or better yet grab the demo at https://factorio.com/download-demo and give it a try!"
    send_msg_both(msg, chan, state.client)
  end
  def message_cmd(cmd, args, auth, chan, state) do
    cache = %{ # This is not allocated on every invocation, it is interned
      "changelog" => fn(_cmd, args, _auth, chan, state) ->
        case args do
          "link" -> "https://gregtech.overminddl1.com/com/gregoriust/gregtech/gregtech_1.7.10/changelog.txt"
          _ ->
            case Overdiscord.Commands.GT6.get_changelog_version(args) do
              {:error, msgs} ->
                Enum.map(msgs, &send_msg_both("> " <> &1, chan, state.client))
                nil
              %{changesets: []} ->
                send_msg_both("Changelog has no changesets in it, check:  https://gregtech.overminddl1.com/com/gregoriust/gregtech/gregtech_1.7.10/changelog.txt", chan, state.client)
                nil
              {:ok, changelog} ->
                msgs = Overdiscord.Commands.GT6.format_changelog_as_text(changelog)
                Enum.map(msgs, fn msg ->
                  Enum.map(String.split(msg, ["\r\n", "\n"]), fn msg ->
                    Enum.map(split_at_irc_max_length(msg), fn msg ->
                      ExIrc.Client.msg(state.client, :privmsg, chan, msg)
                      Process.sleep(200)
                    end)
                  end)
                end)
                embed = Overdiscord.Commands.GT6.format_changelog_as_embed(changelog)
                Alchemy.Client.send_message(alchemy_channel(), "", [{:embed, embed}])
                nil
            end
        end
      end,
      "mcve" => "How to create a Minimal, Complete, and Verifiable example:  https://stackoverflow.com/help/mcve",
      "sscce" => "Please provide a Short, Self Contained, Correct Example:  http://sscce.org/",
      "xy" => "Please describe your actual problem instead of your attempted solution:  http://xyproblem.info/",
      "bds" => [
        "Baby duck syndrome is the tendency for computer users to 'imprint' on the first system they learn, then judge other systems by their similarity to that first system.  The result is that users generally prefer systems similar to those they learned on and dislike unfamiliar systems.  It can make it hard for you to make the most rational decision about which software to use or when the learning curve of a given thing is",
        "worth the climb.  In general, it makes the familiar seem more efficient and the unfamiliar less so.  In the short run, this is probably true -- if you're late for a deadline, the best thing to do is not to switch to a new operating system in the hopes that your productivity will increase.",
        "In the long run, it's worth trying a few things knowing that they won't all work out, but hoping to find tools that match your style best. -- https://blog.codinghorror.com/the-software-imprinting-dilemma/",
      ],
      "patreon" => "https://www.patreon.com/gregoriust",
      "website" => "https://gregtech.overminddl1.com/",
      "downloads" => "https://gregtech.overminddl1.com/1.7.10/",
      "secret" => "https://gregtech.overminddl1.com/secretdownloads/",
      "bear" => "https://gaming.youtube.com/c/aBear989/live",
    }

    case Map.get(cache, cmd) do
      nil ->
        case cmd do
          "help" ->
            if args == "" do
              msg = cache
                |> Map.keys()
                |> Enum.join(" ")
              send_msg_both("Valid commands: #{msg}", chan, state.client)
            else
              nil
            end
          _ -> nil
        end
      msg when is_binary(msg) -> send_msg_both("> " <> msg, chan, state.client)
      [_|_] = msgs -> Enum.map(msgs, &send_msg_both("> " <> &1, chan, state.client))
      fun when is_function(fun, 5) ->
        case fun.(cmd, args, auth, chan, state) do
          nil -> nil
          str when is_binary(str) -> send_msg_both("> " <> str, chan, state.client)
          [] -> nil
          # [_|_] = lst -> nil
        end
     end
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

  def message_extra(_type, msg, _auth, chan, %{client: client} = _state) do
    # URL summary
    Regex.scan(~r"https?://[^)\]\s]+"i, msg, [captures: :first])
    |> Enum.map(fn
      [url] ->
         if url =~ ~r/xkcd.com/i do
           []
         else
           case IO.inspect(Overdiscord.SiteParser.get_summary_cached(url), label: :Summary) do
             nil -> nil
             summary ->
               if summary =~ ~r/Minecraft Mod by GregoriusT - overhauling your Minecraft experience completely/ do
                 nil
               else
                 ExIrc.Client.msg(client, :privmsg, "#gt-dev", summary)
               end
           end
         end
      _ -> []
                                                               end)

    # Reddit subreddit links
    Regex.scan(~r"(^|[^/]\b)(?<sr>r/[a-zA-Z0-9_-]{4,})($|[^/])"i, msg, [captures: :all])
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
    last_msg_part = String.slice(msg, -26, 26)
    cond do
      IO.inspect(String.jaro_distance("good night/bye everyone o/", last_msg_part), label: :Distance) > 0.87 or
      msg =~ ~r"bye everyone"i  ->
        ExIrc.Client.msg(client, :privmsg, "#gt-dev", Enum.random(farewells()))
      true -> :ok
    end
  end


  def split_at_irc_max_length(msg) do
    Regex.scan(~R"\b.{1,420}\b\W?"i, msg, capture: :first)# Actually 425, but safety margin
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
