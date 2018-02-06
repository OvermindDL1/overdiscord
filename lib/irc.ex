defmodule Overdiscord.IRC.Bridge do
  # TODO:  Janitor for db: time-series

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

  def poll_xkcd() do
    :gen_server.cast(:irc_bridge, :poll_xkcd)
  end

  def poll_delay_msgs() do
    :gen_server.cast(:irc_bridge, :poll_delay_msgs)
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
    end)
    Process.sleep(200)
    message_extra(:send_msg, msg, nick, "#gt-dev", state)
    {:noreply, state}
  end

  def handle_cast(:poll_xkcd, state) do
    import Meeseeks.CSS
    rss_url = "https://xkcd.com/rss.xml"
    %{body: body, status_code: status_code} = response = HTTPoison.get!(rss_url)
    case status_code do
      200 ->
        doc = Meeseeks.parse(body, :xml)
        with(
          xkcd_link when xkcd_link != nil <- Meeseeks.text(Meeseeks.one(doc, css("channel item link"))),
          xkcd_title when xkcd_title != nil <- Meeseeks.text(Meeseeks.one(doc, css("channel item title")))
        ) do
          case db_get(state, :kv, :xkcd_link) do
            ^xkcd_link -> nil
            _old_link ->
              db_put(state, :kv, :xkcd_link, xkcd_link)
              db_put(state, :kv, :xkcd_title, xkcd_title)
              if true != check_greg_xkcd(state, xkcd_link, xkcd_title) do
                #send_msg_both("#{xkcd_link} #{xkcd_title}", "#gt-dev", state.client)
              end
          end
        end
      _ -> IO.inspect(response, label: :INVALID_RESPONSE_XKCD)
    end
    {:noreply, state}
  end

  def handle_cast(:poll_delay_msgs, state) do
    now = System.system_time(:second)

    db_get(state, :set, :delay_msgs)
    |> Enum.map(fn
      {_time, _host, chan, chan, _msg} -> nil
      {time, _host, chan, nick, msg} = rec when time <= now ->
        IO.inspect(rec, label: :ProcessingDelay)
        send_msg_both("#{nick}{Delay}: #{msg}", chan, state)
        db_put(state, :set_remove, :delay_msgs, rec)
      _ -> nil
    end)

    {:noreply, state}
  end

  def handle_cast(:list_users, state) do
    users = ExIrc.Client.channel_users(state.client, "#gt-dev")
    users = Enum.join(users, " ")
    Alchemy.Client.send_message("320192373437104130", "Users: #{users}")
    {:noreply, state}
  end


  def handle_info(:poll_delay_msgs, state) do
    handle_cast(:poll_delay_msgs, state)
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
        send_msg_both("Welcome to the \"GregoriusTechneticies Dev Chat\"!  Enjoy your stay!", chan, state.client)
      _ -> :ok
    end
    db_put(state, :kv, {:joined, nick}, NaiveDateTime.utc_now())
    db_put(state, :kv, {:joined, user}, NaiveDateTime.utc_now())
    if String.starts_with?(nick, "GregoriusTechneticies") do
      check_greg_xkcd(state)
    end
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


  def code_change(old_vsn, old_state, extra_data) do
    IO.inspect({old_vsn, old_state, extra_data}, label: :Code_Change)
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

  def send_msg_both(msgs, chan, client, prefix \\ "> ")
  def send_msg_both(msgs, chan, %{client: client}, prefix) do
    send_msg_both(msgs, chan, client, prefix)
  end
  def send_msg_both(msgs, chan, client, prefix) do
    msgs
    |> List.wrap()
    |> Enum.map(fn msg ->
      msg
      |> String.split("\\n")
      |> Enum.map(fn msg ->
        msg
        |> split_at_irc_max_length()
        |> List.flatten()
        |> Enum.map(fn msg ->
          ExIrc.Client.msg(client, :privmsg, chan, prefix <> msg)
          Process.sleep(200)
        end)
      end)
    end)

    if chan == "#gt-dev" do
      amsg = convert_message_to_discord(prefix <> String.replace(Enum.join(List.wrap(msgs)), "\\n", "\n#{prefix}"))
      Alchemy.Client.send_message(alchemy_channel(), amsg)
    end
    nil
  end


  def message_cmd(call, args, auth, chan, state)
  #def message_cmd("factorio", "demo", _auth, chan, state) do
  #  msg = "Try the Factorio Demo at https://factorio.com/download-demo and you'll love it!"
  #  send_msg_both(msg, chan, state.client)
  #end
  #def message_cmd("factorio", _args, _auth, chan, state) do
  #  msg = "Factorio is awesome!  See the demonstration video at https://factorio.com or better yet grab the demo at https://factorio.com/download-demo and give it a try!"
  #  send_msg_both(msg, chan, state.client)
  #end
  def message_cmd(cmd, args, auth, chan, state) do
    cache = %{ # This is not allocated on every invocation, it is interned
      "changelog" => fn(_cmd, args, _auth, chan, state) ->
        case args do
          "link" -> "https://gregtech.overminddl1.com/com/gregoriust/gregtech/gregtech_1.7.10/changelog.txt"
          _ ->
            case Overdiscord.Commands.GT6.get_changelog_version(args) do
              {:error, msgs} ->
                Enum.map(msgs, &send_msg_both(&1, chan, state.client))
                nil
              %{changesets: []} ->
                send_msg_both("Changelog has no changesets in it, check:  https://gregtech.overminddl1.com/com/gregoriust/gregtech/gregtech_1.7.10/changelog.txt", chan, state.client)
                nil
              {:ok, changelog} ->
                msgs = Overdiscord.Commands.GT6.format_changelog_as_text(changelog)
                Enum.map(msgs, fn msg ->
                  Enum.map(String.split(to_string(msg), ["\r\n", "\n"]), fn msg ->
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
      "xkcd" => fn(_cmd, args, _auth, _chan, _state) ->
        case Integer.parse(String.trim(args)) do
          {id, ""} -> "https://xkcd.com/#{id}"
          _ ->
            with(
              xkcd_link when xkcd_link != nil <- db_get(state, :kv, :xkcd_link),
              xkcd_title when xkcd_title != nil <- db_get(state, :kv, :xkcd_title),
              do: "#{xkcd_link} #{xkcd_title}"
            )
        end
      end,
      "google" => fn(_cmd, args, _auth, _chan, _state) ->
        "https://lmgtfy.com/?q=#{URI.encode(args)}"
      end,
      "wiki" => fn(_cmd, args, _auth, chan, state) ->
        url = IO.inspect("https://en.wikipedia.org/wiki/#{URI.encode(args)}")
        message_cmd_url_with_summary(url, chan, state.client)
        nil
      end,
      "ftbwiki" => fn(_cmd, args, _auth, chan, state) ->
        url = IO.inspect("https://ftb.gamepedia.com/#{URI.encode(args)}")
        message_cmd_url_with_summary(url, chan, state.client)
        nil
      end,
      "eval-lua" => fn(_cmd, args, _auth, chan, state) ->
        lua_eval_msg(state, chan, args)
      end,
      "calc" => fn(_cmd, args, _auth, chan, state) ->
        lua_eval_msg(state, chan, "return (#{args})")
      end,
      "delay" => fn(cmd, args, auth, chan, state) ->
        case String.split(args, " ", parts: 2) do
          [] -> "Usage: #{cmd} <timespec|\"next\"|\"list\"> <msg...>"
          ["next"] ->
            nic = auth.nick
            db_get(state, :set, :delay_msgs)
            |> Enum.filter(fn
              {_time, _host, mchan, nick, _msg} when nick == nic and mchan == chan -> true
              _ -> false
            end)
            |> Enum.sort_by(&elem(&1, 0))
            |> case do
                 [{time, _host, _chan, nick, msg} | _rest] ->
                   now = System.system_time(:second)
                   dtime =
                     case db_get(state, :kv, {:setting, {:nick, nick}, :timezone}) do
                       nil ->
                         {:ok, dtime} = DateTime.from_unix(time)
                         dtime
                       timezone ->
                         dtime = Timex.from_unix(time)
                         dtime = Timex.to_datetime(dtime, timezone) # TODO:  Add error checking
                         Timex.format!(dtime, "{ISO:Extended}")
                     end
                   "Next pending delay message from #{nick} set to appear at #{to_string(dtime)} (#{time-now}s): #{msg}"
                 _ -> "No pending messages"
               end
          ["list"] ->
            nic = auth.nick
            now = System.system_time(:second)
            db_get(state, :set, :delay_msgs)
            |> Enum.filter(fn
              {_time, _host, _chan, nick, _msg} when nick == nic -> true
              _ -> false
            end)
            |> Enum.sort_by(&elem(&1, 0))
            |> Enum.map(&"#{to_string(elem(&1, 0)-now)}s")
            |> case do
                 [] -> "No pending messages"
                 lst -> "Pending delays remaining: #{Enum.join(lst, " ")}"
               end
          [timespec] ->
            case parse_relativetime_to_seconds(timespec) do
              {:ok, seconds} -> "Parsed timespec is for #{seconds} seconds"
              {:error, reason} -> "Invalid timespec: #{reason}"
            end
          [timespec, msg] ->
            case parse_relativetime_to_seconds(timespec) do
              {:error, reason} -> "Invalid timespec: #{reason}"
              {:ok, seconds} ->
                IO.inspect(ExIrc.Client.channel_users(state.client, "#gt-dev"))
                case IO.inspect auth do
                  %{host: "id-16796."<>_, user: "uid16796"} -> 12 # OvermindDL1
                  %{host: "ltea-"<>_, user: "~Gregorius"} -> 12 # Greg
                  %{host: "id-276919"<>_, user: "uid276919"} -> 1 # SuperCoder79
                  _ -> 0
                end
                |> case do
                     0 -> "You are not allowed to use this command"
                     limit ->
                       now = System.system_time(:second)
                       delays = db_get(state, :set, :delay_msgs)
                       if limit <= Enum.count(delays, &(elem(&1, 1)==auth.host)) do
                         "You have too many pending delayed messages, wait until some have elapsed: #{Enum.count(delays, &(elem(&1, 1)==auth.host))}"
                       else
                         now = System.system_time(:second)
                         db_put(state, :set_add, :delay_msgs, {now+seconds, auth.host, chan, auth.nick, msg})
                         Process.send_after(self(), :poll_delay_msgs, seconds*1000)
                         "Delayed message added for #{seconds} seconds"
                       end
                   end
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
      "solve" => fn(cmd, arg, _auth, chan, state) ->
        case String.split(String.trim(arg), " ", parts: 2) do
          [""] -> [
            "Format: #{cmd} <cmd> <expression...>",
            "Valid commands: abs log sin cos tan arcsin arccos arctan simplify factor zeroes solve derive integrate",
            ]
          [_cmmd] -> [
            "Require an expression"
          ]
          [cmmd, expr] -> mdlt(cmmd, expr, chan, state)
        end
      end,
      #"abs" => &mdlt(&1, &2, &4, &5, [ignore: &3]),
      #"log" => &mdlt(&1, &2, &4, &5, [ignore: &3]),
      #"sin" => &mdlt(&1, &2, &4, &5, [ignore: &3]),
      #"cos" => &mdlt(&1, &2, &4, &5, [ignore: &3]),
      #"tan" => &mdlt(&1, &2, &4, &5, [ignore: &3]),
      #"arcsin" => &mdlt(&1, &2, &4, &5, [ignore: &3]),
      #"arccos" => &mdlt(&1, &2, &4, &5, [ignore: &3]),
      #"arctan" => &mdlt(&1, &2, &4, &5, [ignore: &3]),
      #"simplify" => &mdlt(&1, &2, &4, &5, [ignore: &3]),
      #"factor" => &mdlt(&1, &2, &4, &5, [ignore: &3]),
      #"zeroes" => &mdlt(&1, &2, &4, &5, [ignore: &3]),
      #"solve" => &mdlt(&1, &2, &4, &5, [ignore: &3]),
      #"derive" => &mdlt(&1, &2, &4, &5, [ignore: &3]),
      #"integrate" => &mdlt(&1, &2, &4, &5, [ignore: &3]),
      "set" => fn(cmd, arg, auth, chan, state) ->
        case String.split(String.trim(arg), " ", trim: true, parts: 3) do
          [""] -> "Usage: #{cmd} <scope> <setting> {value}"
          ["me" | args] ->
            case args do
              ["timezone"] ->
                v = db_get(state, :kv, {:setting, {:nick, auth.nick}, :timezone})
                [
                  "Current value: #{v || "<unset>"}",
                  "To clear the setting use \"clear\", else use an official timezone designation name such as `America/Chicago` or `-4`.  Use an official name to 'maybe' support daylight savings",
                ]
              ["timezone", "clear"] ->
                db_delete(state, :kv, {:setting, {:nick, auth.nick}, :timezone})
                "Cleared `timezone`"
              ["timezone", timezone] ->
                case Timex.now(timezone) do
                  {:error, _reason} -> "Invalid timezone designation"
                  %{time_zone: timezone} ->
                    db_put(state, :kv, {:setting, {:nick, auth.nick}, :timezone}, timezone)
                    "Successfully set timezone to: #{timezone}"
                end
              _ -> "unknown setting name in the user scope of:  #{List.first(args)}"
            end
          _ -> "Unknown scope"
        end
      end,
      "lastseen" => fn(_cmd, arg, _auth, chan, state) ->
        arg = String.trim(arg)
        case db_get(state, :kv, {:lastseen, arg}) do
          nil -> send_msg_both("`#{arg}` has not been seen speaking before", chan, state.client)
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
            send_msg_both("`#{arg}` last said something #{diff} at: #{date} GMT", chan, state.client)
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
            [] -> send_msg_both("Format: #{cmd} <phrase-cmd> {phrase}\nIf the phraase is missing or blank then it deletes the command", chan, state.client)
            [cmd] ->
              db_put(state, :set_remove, :phrases, cmd)
              db_delete(state, :kv, {:phrase, cmd})
              send_msg_both("#{cmd} removed if it existed", chan, state.client)
            [cmd, phrase] ->
              case db_get(state, :kv, {:phrase, cmd}) do
                nil ->
                  db_put(state, :set_add, :phrases, cmd)
                  db_put(state, :kv, {:phrase, cmd}, phrase)
                  send_msg_both("#{cmd} added as a phrase", chan, state.client)
                [_|_] = old when length(old)>=8 ->
                  send_msg_both("Existing phrase `#{cmd}` already has too many lines", chan, state.client)
                old ->
                  db_put(state, :kv, {:phrase, cmd}, List.wrap(old) ++ [phrase])
                  send_msg_both("Extended existing phrase `#{cmd}` with new line", chan, state.client)
              end
          end
        else
          send_msg_both("You don't have access", chan, state.client)
        end
        nil
      end,
    }

    case Map.get(cache, cmd) do
      nil ->
        case cmd do
          "help" ->
            if args == "" do
              msg = cache
                |> Map.keys()
                |> Enum.sort()
                |> Enum.join(" ")
              phrases = db_get(state, :set, :phrases) || ["<None found>"]
              phrases = Enum.sort(phrases)
              send_msg_both("Valid commands: #{msg}", chan, state.client)
              send_msg_both("Valid phrases: #{Enum.join(phrases, " ")}", chan, state.client)
            else
              nil
            end
          _ ->
            # Check for phrases
            case db_get(state, :kv, {:phrase, cmd}) do
              nil -> nil
              phrase -> send_msg_both(phrase, chan, state.client)
            end
        end
      msg when is_binary(msg) -> send_msg_both(msg, chan, state.client)
      [_|_] = msgs -> Enum.map(msgs, &send_msg_both(&1, chan, state.client))
      fun when is_function(fun, 5) ->
        case fun.(cmd, args, auth, chan, state) do
          nil -> nil
          str when is_binary(str) -> send_msg_both(str, chan, state.client)
          [] -> nil
          [_|_] = msgs when length(msgs) > 4 ->
            Enum.map(msgs, fn msg ->
              send_msg_both(msg, chan, state.client)
              Process.sleep(200)
            end)
          [_|_] = msgs -> Enum.map(msgs, &send_msg_both(&1, chan, state.client))
        end
    end
  rescue e ->
    IO.inspect(e, label: :COMMAND_EXCEPTION)
    send_msg_both("Exception in command execution, report this to OvermindDL1", chan, state.client)
  catch e ->
    IO.inspect(e, label: :COMMAND_CRASH)
    send_msg_both("Crash in command execution, report this to OvermindDL1", chan, state.client)
  end

  def message_cmd_url_with_summary(url, chan, client) do
    ExIrc.Client.msg(client, :privmsg, chan, url)
    case IO.inspect(Overdiscord.SiteParser.get_summary_cached(url), label: :UrlSummary) do
      nil -> "No information found at URL"
      summary -> ExIrc.Client.msg(client, :privmsg, chan, "> " <> summary)
    end
  end


  def message_extra(:msg, "?" <> cmd, auth, chan, state) do
    [call | args] = String.split(cmd, " ", [parts: 2])
    args = String.trim(to_string(args))
    message_cmd(call, args, auth, chan, state)
  end
  def message_extra(:msg, "ß" <> cmd, auth, chan, state) do
    [call | args] = String.split(cmd, " ", [parts: 2])
    args = String.trim(to_string(args))
    message_cmd(call, args, auth, chan, state)
  end

  def message_extra(:msg, "=2+2", _auth, chan, state) do
    send_msg_both("Fish", chan, state.client)
  end
  def message_extra(:msg, "=" <> expression, _auth, chan, state) do
    lua_eval_msg(state, chan, "return #{expression}", cb: fn
      {:ok, [result]} -> send_msg_both("#{inspect result}", chan, state.client)
      {:ok, result} -> send_msg_both("#{inspect result}", chan, state.client)
      {:error, _reason} -> send_msg_both("= <failed>", chan, state.client)
    end)
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
                 ExIrc.Client.msg(client, :privmsg, "#gt-dev", "> " <> summary)
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


  def check_greg_xkcd(state) do
    with(
      xkcd_link when xkcd_link != nil <- db_get(state, :kv, :xkcd_link),
      xkcd_title when xkcd_title != nil <- db_get(state, :kv, :xkcd_title),
      do: check_greg_xkcd(state, xkcd_link, xkcd_title)
    )
  end
  def check_greg_xkcd(state, xkcd_link, xkcd_title) do
    last_link = db_get(state, :kv, :xkcd_greg_link)
    if last_link != xkcd_link and ExIrc.Client.channel_has_user?(state.client, "#gt-dev", "GregoriusTechneticies") do
      db_put(state, :kv, :xkcd_greg_link, xkcd_link)
      send_msg_both("#{xkcd_link} #{xkcd_title}", "#gt-dev", state.client)
      true
    else
      nil
    end
  end


  def split_at_irc_max_length(msg) do
    # TODO: Look into this more, fails on edge cases...
    #IO.inspect(msg, label: :Unicode?)
    #Regex.scan(~R".{1,420}\s\W?"iu, msg, capture: :first)# Actually 425, but safety margin
    #[[msg]]
    Regex.scan(~R".{1,419}\S(\s|$)"iu, msg, capture: :first)
  end


  def db_put(state = %{db: db}, type, key, value) do
    db_put(db, type, key, value)
    state
  end
  def db_put(db, :timeseries, key, value) when is_integer(value) do
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
  def db_put(db, :kv, key, value) do
    key = :erlang.term_to_binary({:kv, key})
    value = :erlang.term_to_binary(value)
    Exleveldb.put(db, key, value)
  end
  def db_put(db, :set_add, key, value) do
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
  def db_put(db, :set_remove, key, value) do
    key = :erlang.term_to_binary({:set, key})
    case Exleveldb.get(db, key) do
      :not_found -> db
      {:ok, values} ->
        oldValues = :erlang.binary_to_term(values, [:safe])
        values = Map.delete(oldValues, value)
        Exleveldb.put(db, key, values)
    end
  end
  def db_put(db, type, key, value) do
    IO.inspect("Invalid DB put type of `#{inspect type}` of key `#{inspect key}` with value: #{inspect value}", label: :ERROR_DB_TYPE)
    db
  end

  defp db_timeseries_inc(db, key) do
    db_put(db, :timeseries, key, 1)
  end

  def db_get(%{db: db}, type, key) do
    db_get(db, type, key)
  end
  def db_get(db, :kv, key) do
    key = :erlang.term_to_binary({:kv, key})
    case Exleveldb.get(db, key) do
      :not_found -> nil
      {:ok, value} -> :erlang.binary_to_term(value, [:safe])
    end
  end
  def db_get(db, :set, key) do
    key = :erlang.term_to_binary({:set, key})
    case Exleveldb.get(db, key) do
      :not_found -> []
      {:ok, values} ->
        values = :erlang.binary_to_term(values, [:safe])
        Map.keys(values)

    end
  end
  def db_get(_db, type, key) do
    IO.inspect("Invalid DB get type for `#{inspect type}` of key `#{inspect key}`", label: :ERROR_DB_TYPE)
    nil
  end

  def db_delete(%{db: db}, type, key) do
    db_delete(db, type, key)
  end
  def db_delete(db, :kv, key) do
    key = :erlang.term_to_binary({:kv, key})
    Exleveldb.delete(db, key)
  end
  def db_delete(_db, type, key) do
    IO.inspect("Invalid DB delete type for `#{inspect type}` of key `#{inspect key}`", label: :ERROR_DB_TYPE)
    nil
  end


  def db_user_messaged(db, auth, _msg) do
    db_timeseries_inc(db, auth.nick)
    db_put(db, :kv, {:lastseen, auth.nick}, NaiveDateTime.utc_now())
  end


  def new_lua_state() do
    lua = :luerl.init()
    lua = :luerl.set_table([:os, :getenv], nil, lua)
    lua = :luerl.set_table([:package], nil, lua)
    lua = :luerl.set_table([:require], nil, lua)
    lua = :luerl.set_table([:loadfile], nil, lua)
    lua = :luerl.set_table([:load], nil, lua)
    lua = :luerl.set_table([:dofile], nil, lua)
    lua
  end

  def lua_eval(_state, expression) do
    # TODO: Get the lua state out of `state`
    lua = new_lua_state()
    case :luerl.eval(expression, lua) do
      {:ok, _result} = ret -> ret
      {:error, _reason} -> {:error, "Parse Error"}
    end
  rescue r ->
    IO.inspect(r, label: :LuaException)
    {:error, r}
  catch e ->
    IO.inspect(e, label: :LuaError)
    {:error, e}
  end

  def lua_eval_msg(state, chan, expression, opts \\ []) do
    cb = opts[:cb]
    pid =
      spawn(fn ->
        case lua_eval(state, expression) do
          {:ok, result} ->
            if cb, do: cb.({:ok, result}), else: send_msg_both("Result: #{inspect result}", chan, state.client)
          {:error, reason} ->
            if cb, do: cb.({:error, reason}), else: send_msg_both("Failed running with reason: #{inspect reason}", chan, state.client)
        end
      end)
    spawn(fn ->
      Process.sleep(opts[:timeout] || 5000)
      if Process.alive?(pid) do
        Process.exit(pid, :brutal_kill)
        send_msg_both("Eval hit maximum running time.", chan, state.client)
      end
    end)
    nil
  end


  def parse_relativetime_to_seconds("") do
    {:ok, 0}
  end
  def parse_relativetime_to_seconds(str) do
    case Integer.parse(str) do
      :error -> {:error, "Invalid number where number was expected: #{str}"}
      {value, rest} ->
        case reltime_mult(rest) do
          {:error, _} = error -> error
          {:ok, mult, rest} ->
            value = value * mult
            case parse_relativetime_to_seconds(rest) do
              {:error, _} = error -> error
              {:ok, more} -> {:ok, more + value}
            end
        end
    end
  end

  defp reltime_mult(str)
  defp reltime_mult("s"<>rest), do: {:ok, 1, rest}
  defp reltime_mult("m"<>rest), do: {:ok, 60, rest}
  defp reltime_mult("h"<>rest), do: {:ok, 60*60, rest}
  defp reltime_mult("d"<>rest), do: {:ok, 60*60*24, rest}
  defp reltime_mult("w"<>rest), do: {:ok, 60*60*24*7, rest}
  defp reltime_mult("M"<>rest), do: {:ok, 60*60*24*30, rest}
  defp reltime_mult("y"<>rest), do: {:ok, 60*60*24*365, rest}
  defp reltime_mult(str), do: {:error, "Invalid multiplier spec: #{str}"}

  defp seconds_to_reltime(seconds) do
  end


  def mdlt(op, expr, chan, state, opts \\ []) do
    pid =
      spawn(fn ->
        case System.cmd("mdlt", [op, expr]) do
          {result, _exit_code_which_is_always_0_grr} ->
            case String.split(result, "\n", parts: 2) do
              [] -> "#{inspect({op, expr})})} Error processing expression"
              [result | _] -> "#{op}(#{expr}) -> #{result}"
              #[err, _rest] -> "#{inspect({op, expr})} Error: #{err}"
            end
          err ->
            IO.inspect({op, expr, err}, label: :MathSolverErr)
            "#{inspect({op, expr})} Error loading Math solver, report this to OvermindDL1"
        end
        |> IO.inspect(label: :MDLTResult)
        |> send_msg_both(chan, state.client)
      end)
    spawn(fn ->
      Process.sleep(opts[:timeout] || 5000)
      if Process.alive?(pid) do
        Process.exit(pid, :brutal_kill)
        send_msg_both("Math calculation hit maximum running time.", chan, state.client)
      end
    end)
    nil
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
