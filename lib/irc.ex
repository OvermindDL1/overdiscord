defmodule Overdiscord.IRC.Bridge do
  # TODO:  Janitor for db: time-series
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
      db: nil,
      meta: %{
        logouts: %{},
      },
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

  def get_db() do
    :gen_server.call(:irc_bridge, :get_db)
  end

  def start_link(state \\ %State{}) do
    IO.inspect("Launching IRC Bridge")
    :gen_server.start_link({:local, :irc_bridge}, __MODULE__, state, [])
  end


  def init(state) do
    {:ok, client} = ExIrc.start_link!()
    db =
      case Exleveldb.open("_db") do
        {:ok, db} -> db
        {:error, reason} ->
          IO.inspect(reason, label: :DB_OPEN_ERROR)
          case Exleveldb.repair("_db") do
            :ok -> :ok
            {:error, reason} -> IO.inspect(reason, label: :DB_REPAIR_ERROR)
          end
          {:ok, db} = Exleveldb.open("_db")
          db
      end
    state = %{state | client: client, db: db}
    IO.inspect("Starting IRC Bridge... #{inspect self()}")
    ExIrc.Client.add_handler(state.client, self())

    ExIrc.Client.connect!(state.client, state.host, state.port)
    {:ok, state}
  end

  def handle_call(:get_db, _from, state) do
    {:reply, state.db, state}
  end

  def handle_cast({:send_msg, nick, msg}, state) do
    db_user_messaged(state, %{nick: nick, user: nick, host: "#{nick}@Discord"}, msg)
    msg
    |> String.split("\n")
    #|> Enum.flat_map(&split_at_irc_max_length/1)
    |> Enum.each(fn line ->
      Enum.map(split_at_irc_max_length("#{nick}: #{line}"), fn irc_msg ->
        # ExIrc.Client.nick(state.client, "#{nick}{Discord}")
        ExIrc.Client.msg(state.client, :privmsg, "#gt-dev", irc_msg)
        # ExIrc.Client.nick(state.client, state.nick)
        Process.sleep(200)
      end)
      message_extra(:send_msg, msg, nick, "#gt-dev", state)
      Process.sleep(200)
    end)
    {:noreply, state}
  end

  def handle_cast(:list_users, state) do
    users = ExIrc.Client.channel_users(state.client, "#gt-dev")
    users = Enum.join(users, " ")
    Alchemy.Client.send_message("320192373437104130", "Users: #{users}")
    {:noreply, state}
  end


  def handle_info({:connected, _server, _port}, state) do
    IO.inspect("connecting bridge...")
    #IO.inspect({state.client, state.pass, state.nick, state.user, state.name})
    Process.sleep(200)
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
    db_user_messaged(state, auth, msg)
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
    db_user_messaged(state, auth, action)
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
    case db_get(state, :kv, {:joined, nick}) do
      nil ->
        send_msg_both("Welcome to the \"GregoriusTechneticies Dev Chat\"!  Enjoy your stay, #{nick}!", chan, state.client)
      _ -> :ok
    end
    db_put(state, :kv, {:joined, nick}, NaiveDateTime.utc_now())
    db_put(state, :kv, {:joined, user}, NaiveDateTime.utc_now())
    #last = {_, s, _} = state.meta.logouts[host] || 0
    #last = :erlang.setelement(2, last, s+(60*5))
    #if chan == "#gt-dev-test" and :erlang.now() > last do
    #  ExIrc.Client.msg(state.client, :privmsg, chan, "Welcome #{nick}!")
    #end
    {:noreply, state}
  end

  def handle_info({:parted, chan, %{host: host, nick: nick, user: user}}, state) do
    IO.inspect("#{chan}: User `#{user}` with nick `#{nick} parted from `#{host}`")
    db_put(state, :kv, {:parted, user}, NaiveDateTime.utc_now())
    {:noreply, state}
  end

  def handle_info({:quit, msg, %{host: host, nick: nick, user: user}}, state) do
    IO.inspect("User `#{user}` with nick `#{nick}` at host `#{host}` quit with message: #{msg}")
    #state = put_in(state.meta.logouts[host], :erlang.now())
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
        try do
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
        rescue r ->
          IO.inspect(r, label: :ERROR_ALCHEMY_EXCEPTION)
          full
        catch e ->
          IO.inspect(e, label: :ERROR_ALCHEMY)
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
      "screenshot" => fn(_cmd, _args, _auth, _chan, _state) ->
        %{body: url, status_code: url_code} = HTTPoison.get!("https://gregtech.overminddl1.com/com/gregoriust/gregtech/screenshots/LATEST.url")
        case url_code do
          200 ->
            %{body: description, status_code: description_code} = HTTPoison.get!("https://gregtech.overminddl1.com/imagecaption.adoc")
            case description_code do
              200 -> ["https://gregtech.overminddl1.com#{url}", description]
              _ -> url
            end
          _ -> "Unable to retrieve image URL, report this error to OvermindDL1"
        end
      end,
      "list" => fn(_cmd, _args, _auth, chan, state) ->
        try do
          names =
            Alchemy.Cache.search(:members, &(&1.user.bot == false))
            |> Enum.map(&(&1.user.username))
            |> Enum.join("` `")
          ExIrc.Client.msg(state.client, :privmsg, chan, "Discord Names: `#{names}`")
          nil
        rescue r ->
            IO.inspect(r, label: :DiscordNameCacheError)
          ExIrc.Client.msg(state.client, :privmsg, chan, "Discord name server query is not responding, try later")
          nil
        end
      end,
      "lastseen" => fn(_cmd, arg, _auth, chan, state) ->
        arg = String.trim(arg)
        case db_get(state, :kv, {:lastseen, arg}) do
          nil -> send_msg_both("> `#{arg}` has not been seen speaking before", chan, state.client)
          date ->
            now = NaiveDateTime.utc_now()
            diff_sec = NaiveDateTime.diff(now, date)
            diff =
              cond do
              diff_sec < 60 -> "#{diff_sec} seconds ago"
              diff_sec < (60*60) -> "#{div(diff_sec, 60)} minutes ago"
              diff_sec < (60*60*24) -> "#{div(diff_sec, 60*60)} hours ago"
              true -> "#{div(diff_sec, 60*60*24)} days ago"
              end
            send_msg_both("> `#{arg}` last said something #{diff} at: #{date} GMT", chan, state.client)
        end
      end,
      "setphrase" => fn(cmd, args, auth, chan, state) ->
        case auth do
          %{host: "id-16796."<>_, user: "uid16796"} -> true
          %{host: "ltea-047-064-006-094.pools.arcor-ip.net"} -> true
          _ -> false
        end
        |> if do
          case String.split(args, " ", parts: 2) |> Enum.map(&String.trim/1) |> Enum.filter(&(&1!="")) do
            [] -> send_msg_both("> Format: #{cmd} <phrase-cmd> {phrase}\nIf the phraase is missing or blank then it deletes the command", chan, state.client)
            [cmd] ->
              db_put(state, :set_remove, :phrases, cmd)
              db_delete(state, :kv, {:phrase, cmd})
              send_msg_both("> #{cmd} removed if it existed", chan, state.client)
            [cmd, phrase] ->
              db_put(state, :set_add, :phrases, cmd)
              db_put(state, :kv, {:phrase, cmd}, phrase)
              send_msg_both("> #{cmd} added as a phrase", chan, state.client)
          end
        else
          send_msg_both("> You don't have access", chan, state.client)
        end
        nil
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
      "discordstatus" => "https://discord.statuspage.io/",
      "semver" => "https://semver.org/",
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
          _ ->
            # Check for phrases
            case db_get(state, :kv, {:phrase, cmd}) do
              nil -> nil
              phrase -> send_msg_both("> #{phrase}", chan, state.client)
            end
        end
      msg when is_binary(msg) -> send_msg_both("> " <> msg, chan, state.client)
      [_|_] = msgs -> Enum.map(msgs, &send_msg_both("> " <> &1, chan, state.client))
      fun when is_function(fun, 5) ->
        case fun.(cmd, args, auth, chan, state) do
          nil -> nil
          str when is_binary(str) -> send_msg_both("> " <> str, chan, state.client)
          [] -> nil
          [_|_] = msgs when length(msgs) > 4 ->
            Enum.map(msgs, fn msg ->
              send_msg_both("> #{msg}", chan, state.client)
              Process.sleep(200)
            end)
          [_|_] = msgs -> Enum.map(msgs, &send_msg_both("> #{&1}", chan, state.client))
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
    # TODO: Look into this more, fails on edge cases...
    #IO.inspect(msg, label: :Unicode?)
    #Regex.scan(~R".{1,420}\s\W?"iu, msg, capture: :first)# Actually 425, but safety margin
    #[[msg]]
    Regex.scan(~R".{1,419}\S(\s|$)"iu, msg, capture: :first)
  end


  defp db_put(state = %{db: db}, type, key, value) do
    db_put(db, type, key, value)
    state
  end
  defp db_put(db, :timeseries, key, value) when is_integer(value) do
    now = NaiveDateTime.utc_now()
    key = :erlang.term_to_binary({:ts, key, now.year, now.month, now.day, now.hour})
    oldValue =
      case Exleveldb.get(db, key) do
        :not_found -> 0
        {:ok, s} -> String.to_integer(s)
      end
    value = to_string(oldValue + value)
    Exleveldb.put(db, key, value)
    db
  end
  defp db_put(db, :kv, key, value) do
    key = :erlang.term_to_binary({:kv, key})
    value = :erlang.term_to_binary(value)
    Exleveldb.put(db, key, value)
  end
  defp db_put(db, :set_add, key, value) do
    key = :erlang.term_to_binary({:set, key})
    oldValues =
      case Exleveldb.get(db, key) do
        :not_found -> %{}
        {:ok, values} -> :erlang.binary_to_term(values, [:safe])
      end
    values = Map.put(oldValues, value, 1)
    Exleveldb.put(db, key, values)
    db
  end
  defp db_put(db, :set_remove, key, value) do
    key = :erlang.term_to_binary({:set, key})
    case Exleveldb.get(db, key) do
      :not_found -> db
      {:ok, values} ->
        oldValues = :erlang.binary_to_term(values, [:safe])
        values = Map.delete(oldValues, value)
        Exleveldb.put(db, key, values)
    end
  end
  defp db_put(db, type, key, value) do
    IO.inspect("Invalid DB put type of `#{inspect type}` of key `#{inspect key}` with value: #{inspect value}", label: :ERROR_DB_TYPE)
    db
  end

  defp db_timeseries_inc(db, key) do
    db_put(db, :timeseries, key, 1)
  end

  defp db_get(%{db: db}, type, key) do
    db_get(db, type, key)
  end
  defp db_get(db, :kv, key) do
    key = :erlang.term_to_binary({:kv, key})
    case Exleveldb.get(db, key) do
      :not_found -> nil
      {:ok, value} -> :erlang.binary_to_term(value, [:safe])
    end
  end
  defp db_get(db, :set, key) do
    key = :erlang.term_to_binary({:set, key})
    case Exleveldb.get(db, key) do
      :not_found -> []
      {:ok, values} ->
        values = :erlang.binary_to_term(values, [:safe])
        Map.keys(values)

    end
  end
  defp db_get(_db, type, key) do
    IO.inspect("Invalid DB get type for `#{inspect type}` of key `#{inspect key}`", label: :ERROR_DB_TYPE)
    nil
  end

  defp db_delete(%{db: db}, type, key) do
    db_delete(db, type, key)
  end
  defp db_delete(db, :kv, key) do
    key = :erlang.term_to_binary({:kv, key})
    Exleveldb.delete(db, key)
  end
  defp db_delete(_db, type, key) do
    IO.inspect("Invalid DB delete type for `#{inspect type}` of key `#{inspect key}`", label: :ERROR_DB_TYPE)
    nil
  end


  defp db_user_messaged(db, auth, _msg) do
    db_timeseries_inc(db, auth.nick)
    db_put(db, :kv, {:lastseen, auth.nick}, NaiveDateTime.utc_now())
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
