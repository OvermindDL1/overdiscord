defmodule Overdiscord.IRC.Bridge do
  # TODO:  `?update` Download Link, Screenshot, Changelog order all at once

  defmodule State do
    defstruct host: "irc.esper.net",
              port: 6667,
              pass: {:SYSTEM, "OVERBOT_PASS"},
              nick: "overbot",
              user: {:SYSTEM, "OVERBOT_USER"},
              name: "overbot",
              ready: false,
              client: nil,
              db: nil,
              meta: %{
                logouts: %{},
                whos: %{},
                caps: %{}
              }
  end

  defp get_config_value({:SYSTEM, key}) do
    case System.get_env(key) do
      nil -> throw(IO.inspect("MISSING #{key}"))
      value -> value
    end
  end

  defp get_config_value(value), do: value

  def send_event(auth, event_data, to)

  def send_event(auth, event_data, to) do
    :gen_server.cast(:irc_bridge, {:send_event, auth, event_data, to})
  end

  def send_msg("", _), do: nil
  def send_msg(_, ""), do: nil

  def send_msg(nick, msg) do
    # IO.inspect({"Casting", nick, msg})
    :gen_server.cast(:irc_bridge, {:send_msg, nick, msg})
  end

  def on_presence_update(nick, game) do
    :gen_server.cast(:irc_bridge, {:on_presence_update, nick, game})
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
    {:ok, client} = ExIRC.start_link!()

    db =
      case Exleveldb.open("_db") do
        {:ok, db} ->
          db

        {:error, reason} ->
          IO.inspect(reason, label: :DB_OPEN_ERROR)
          Process.sleep(1000)

          case Exleveldb.repair("_db") do
            :ok -> :ok
            {:error, reason} -> IO.inspect(reason, label: :DB_REPAIR_ERROR)
          end

          {:ok, db} = Exleveldb.open("_db")
          db
      end

    state = %{state | client: client, db: db}
    IO.inspect("Starting IRC Bridge... #{inspect(self())}")
    ExIRC.Client.add_handler(state.client, self())

    ExIRC.Client.connect!(state.client, state.host, state.port)
    {:ok, state}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:get_db, _from, state) do
    {:reply, state.db, state}
  end

  def handle_call(:get_client, _from, state) do
    {:reply, state.client, state}
  end

  def handle_cast({:send_event, auth, event_data, to}, state) do
    case event_data do
      %{simple_msg: msg} ->
        handle_cast({:send_msg, auth.nickname, {:simple, msg}, to}, state)

      %{msg: msg} ->
        handle_cast({:send_msg, auth.nickname, msg, to}, state)

      %{irc_cmd: cmd} ->
        IO.inspect(%{event_data: event_data, auth: auth, to: to}, label: :IRCEventDataCmd)
        message_extra(:msg, cmd, auth.nickname, "#gt-dev", state)
        {:noreply, state}

      _ ->
        IO.inspect(%{event_data: event_data, auth: auth, to: to}, label: :IRCUnhandledEventData)
        {:noreply, state}
    end
  end

  def handle_cast({:send_msg, nick, msg}, state) do
    handle_cast({:send_msg, nick, msg, "#gt-dev"}, state)
  end

  def handle_cast({:send_msg, nick, msg, chan}, state) do
    {is_simple_msg, msg} =
      case msg do
        msg when is_binary(msg) -> {false, msg}
        {:simple, msg} -> {true, msg}
      end

    nick_color = get_name_color(state, nick)
    db_user_messaged(state, %{nick: nick, user: nick, host: "#{nick}@Discord"}, msg)
    # |> Enum.flat_map(&split_at_irc_max_length/1)
    escaped_nick = irc_unping(nick)

    msg
    |> String.split("\n")
    |> Enum.each(fn line ->
      Enum.map(split_at_irc_max_length("#{nick_color}#{escaped_nick}\x0F: #{line}"), fn irc_msg ->
        # ExIRC.Client.nick(state.client, "#{nick}{Discord}")
        ExIRC.Client.msg(state.client, :privmsg, chan, irc_msg)
        # ExIRC.Client.nick(state.client, state.nick)
        dispatch_msg("@#{nick}: #{line}")
        Process.sleep(200)
      end)
    end)

    Process.sleep(200)

    if not is_simple_msg do
      message_extra(:send_msg, msg, nick, "#gt-dev", state)
    end

    {:noreply, state}
  end

  def handle_cast({:on_presence_update, "<off>Bear989" = nick, stream}, state) do
    IO.inspect({nick, stream}, label: "BearPresence")

    case {db_get(state, :kv, {:presence, nick}), stream} do
      # No change in cache
      {^stream, _} ->
        :ok

      {"[Bears Den]" <> _, "[Bears Den] <> _"} ->
        [
          "Bear changed stream to: #{stream}",
          "See the stream at:  https://www.youtube.com/c/aBear989/live"
        ]
        |> send_msg_both("#gt-dev", state.client, discord: :simple)

        db_put(state, :kv, {:presence, nick}, stream)

      {"[Bears Den]" <> _, _} ->
        send_msg_both("Bear stopped streaming", "#gt-dev", state.client, discord: :simple)
        db_put(state, :kv, {:presence, nick}, stream)

      {_, "[Bears Den]" <> _} ->
        [
          "Bear has started streaming: #{stream}",
          "See the stream at:  https://www.youtube.com/c/aBear989/live"
        ]
        |> send_msg_both("#gt-dev", state.client, discord: :simple)

        db_put(state, :kv, {:presence, nick}, stream)

      {_, _} ->
        # Playing something else...
        nil
    end

    {:noreply, state}
  end

  def handle_cast({:on_presence_update, nick, game}, state) do
    IO.inspect({nick, game}, label: "Presence Update")

    case db_get(state, :kv, {:lastseen, nick}) do
      %NaiveDateTime{} when nick == "Bear989" ->
        case db_get(state, :kv, {:presence, nick}) do
          ^game ->
            :ok

          _oldpresence ->
            case Overdiscord.SiteParser.get_summary("https://wwwn:w.youtube.com/c/aBear989/live") do
              nil ->
                IO.inspect("No response from youtube!", label: :YoutubeError)

              summary ->
                case db_get(state, :kv, {:presence_yt, nick}) do
                  ^summary ->
                    if game == nil and not db_get(state, :kv, {:presence_yt_clear, nick}) do
                      # ExIRC.Client.msg(
                      #  state.client,
                      #  :privmsg,
                      #  "#gt-dev",
                      #  "> #{nick} is no longer playing or streaming"
                      # )

                      db_put(state, :kv, {:presence_yt_clear, nick}, true)
                    end

                  old_summary ->
                    if game != nil do
                      # ExIRC.Client.msg(
                      #  state.client,
                      #  :privmsg,
                      #  "#gt-dev",
                      #  "> #{nick} is now playing/streaming: #{game} (was last: #{oldpresence})"
                      # )

                      # ExIRC.Client.msg(
                      #  state.client,
                      #  :privmsg,
                      #  "#gt-dev",
                      #  "> If Bear989 is streaming then see it at: https://gaming.youtube.com/c/aBear989/live"
                      # )

                      [simple_summary | _] = String.split(summary, " - YouTube Gaming :")
                      IO.inspect(simple_summary, label: "BearUpdate")
                      # send_msg_both(simple_summary, "#gt-dev", state, discord: false)
                      send_msg_both(
                        "Bear989 is now playing/streaming at https://gaming.youtube.com/c/aBear989/live #{
                          simple_summary
                        }",
                        "#gt-dev",
                        state,
                        discord: false
                      )

                      [old_summary | _] = String.split(old_summary, " - YouTube Gaming :")
                      IO.inspect(old_summary, label: "BearOldUpdate")
                      # send_msg_both("Old: " <> old_summary, "#gt-dev", state, discord: false)

                      db_put(state, :kv, {:presence_yt_clear, nick}, false)
                    end
                end

                db_put(state, :kv, {:presence_yt, nick}, summary)
            end
        end

      _nil ->
        nil
    end

    db_put(state, :kv, {:presence, nick}, game)

    {:noreply, state}
  end

  def handle_cast(:poll_xkcd, state) do
    import Meeseeks.CSS
    rss_url = "https://xkcd.com/rss.xml"
    %{body: body, status_code: status_code} = response = HTTPoison.get!(rss_url)

    case status_code do
      200 ->
        doc = Meeseeks.parse(body, :xml)

        with xkcd_link when xkcd_link != nil <-
               Meeseeks.text(Meeseeks.one(doc, css("channel item link"))),
             xkcd_title when xkcd_title != nil <-
               Meeseeks.text(Meeseeks.one(doc, css("channel item title"))) do
          case {db_get(state, :kv, :xkcd_link), db_get(state, :kv, :xkcd_title)} do
            {^xkcd_link, ^xkcd_title} ->
              IO.inspect({:old_xkcd_link, xkcd_link, xkcd_title})
              check_greg_xkcd(state, xkcd_link, xkcd_title)
              nil

            {old_link, old_title} ->
              IO.inspect({:new_xkcd_link, xkcd_link, xkcd_title, old_link, old_title})
              db_put(state, :kv, :xkcd_link, xkcd_link)
              db_put(state, :kv, :xkcd_title, xkcd_title)

              if true != check_greg_xkcd(state, xkcd_link, xkcd_title) do
                # send_msg_both("#{xkcd_link} #{xkcd_title}", "#gt-dev", state.client)
              end
          end
        end

      _ ->
        IO.inspect(response, label: :INVALID_RESPONSE_XKCD)
    end

    {:noreply, state}
  end

  def handle_cast(:poll_delay_msgs, state) do
    cap?(state, "away-notify") && ExIRC.Client.who(state.client, "#gt-dev")
    now = System.system_time(:second)
    nowdt = Timex.now()
    # users = ExIRC.Client.channel_users(state.client, "#gt-dev")

    db_get(state, :set, :delay_msgs)
    |> Enum.map(fn
      # {_time, _host, chan, chan, _msg} -> nil
      {%dts{} = datetime, _host, chan, nick, msg} = rec when dts in [DateTime, NaiveDateTime] ->
        if Timex.compare(datetime, nowdt) <= 0 do
          if away?(state, "#gt-dev", nick: nick) == false or
               (db_get(state, :kv, {:joined, nick}) || 0) >
                 (db_get(state, :kv, {:parted, nick}) || 1) do
            IO.inspect(rec, label: :ProcessingDelayDT)
            send_msg_both("#{nick}{Delay}: #{msg}", chan, state)
            db_put(state, :set_remove, :delay_msgs, rec)
          end
        end

      {time, _host, chan, nick, msg} = rec when time <= now ->
        if away?(state, "#gt-dev", nick: nick) == false do
          IO.inspect(rec, label: :ProcessingDelay)
          send_msg_both("#{nick}{Delay}: #{msg}", chan, state)
          db_put(state, :set_remove, :delay_msgs, rec)
        end

      s ->
        # IO.inspect(s, label: "Poll delay rest")
        s
    end)

    {:noreply, state}
  end

  def handle_cast(:list_users, state) do
    users = ExIRC.Client.channel_users(state.client, "#gt-dev")
    users = Enum.join(users, " ")
    Alchemy.Client.send_message("320192373437104130", "Users: #{users}")
    {:noreply, state}
  end

  def handle_info(:poll_delay_msgs, state) do
    handle_cast(:poll_delay_msgs, state)
  end

  def handle_info({:connected, _server, _port}, state) do
    IO.inspect("connecting bridge...", label: "State")
    # TODO:  Blegh!  Check if ExIRC has a better way here, because what on earth...
    # Process.sleep(5000)
    IO.inspect("Connect should be complete", label: "State")

    spawn(fn ->
      IO.inspect(get_config_value(state.user), label: :BLARGH)
      Process.sleep(2000)

      ExIRC.Client.logon(
        state.client,
        get_config_value(state.pass),
        state.nick,
        get_config_value(state.user),
        state.name
      )
    end)

    {:noreply, state}
  end

  def handle_info({:unrecognized, "CAP", %{args: [_self_nick, "LS", caps]}}, state) do
    c =
      caps
      |> String.split(" ")
      |> IO.inspect(label: :IRCCapabilities)
      |> Enum.reduce(%{}, fn
        cap, c when cap in ["away-notify"] ->
          IO.inspect(cap, label: :IRCRequestedCap)
          ExIRC.Client.cmd(state.client, "CAP REQ #{cap}")
          Map.put(c, cap, :requested)

        cap, c ->
          IO.inspect(cap, label: :IRCUnhandledCapability)
          Map.put(c, cap, false)
      end)

    state = %{state | meta: Map.put(state.meta, :caps, c)}

    {:noreply, state}
  end

  def handle_info({:unrecognized, "CAP", %{args: [_self_nick, "ACK", cap]}}, state) do
    state =
      case state.meta[:caps] do
        %{^cap => :requested} ->
          IO.inspect(cap, label: :IRCCapabilityRequestSuccessful)
          %{state | meta: put_in(state.meta, [:caps, cap], true)}

        %{^cap => state} ->
          IO.inspect({cap, state}, label: :IRCCapabilityUnrequestedSuccessful)
          %{state | meta: put_in(state.meta, [:caps, cap], true)}

        nil ->
          IO.inspect(cap, label: :IRCCapabilityUnknownSuccessful)
          state
      end

    {:noreply, state}
  end

  def handle_info(:logged_in, state) do
    ExIRC.Client.cmd(state.client, "CAP LS")
    ExIRC.Client.join(state.client, "#gt-dev")
    {:noreply, state}
  end

  def handle_info({:joined, "#gt-dev" = chan}, state) do
    state = %{state | ready: true}
    send_msg_both("#{state.nick} has re-joined", chan, state.client, irc: false)
    ExIRC.Client.who(state.client, "#gt-dev")
    {:noreply, state}
  end

  def handle_info({:received, msg, %{nick: nick, user: user} = auth, "#gt-dev" = chan}, state) do
    db_user_messaged(state, auth, msg)

    case msg do
      "!" <> _ ->
        :ok

      omsg ->
        spawn(fn -> Overdiscord.EventPipe.inject({chan, auth, state}, %{msg: msg}) end)
        dispatch_msg("#{nick}: #{msg}")
        if(user === "~Gregorius", do: handle_greg(msg, state.client))
        msg = convert_message_to_discord(msg)
        IO.inspect("Sending message from IRC to Discord: **#{nick}**: #{msg}", label: "State")
        # Alchemy.Client.send_message("320192373437104130", "**#{nick}:** #{msg}")
        message_extra(:msg, omsg, auth, chan, state)
    end

    {:noreply, state}
  end

  def handle_info({:received, msg, %{nick: _nick, user: _user} = auth, chan}, state) do
    case msg do
      "!" <> _ ->
        :ok

      msg ->
        spawn(fn -> Overdiscord.EventPipe.inject({chan, auth, state}, %{msg: msg}) end)
        message_extra(:msg, msg, auth, chan, state)
    end

    {:noreply, state}
  end

  def handle_info({:received, msg, %{nick: nick, user: _user} = auth}, state) do
    case msg do
      "!" <> _ ->
        :ok

      msg ->
        spawn(fn -> Overdiscord.EventPipe.inject({nick, auth, state}, %{msg: msg}) end)
        message_extra(:msg, msg, auth, nick, state)
    end

    {:noreply, state}
  end

  def handle_info({:me, action, %{nick: nick, user: user} = auth, "#gt-dev" = chan}, state) do
    db_user_messaged(state, auth, action)
    if(user === "~Gregorius", do: handle_greg(action, state.client))

    spawn(fn ->
      Overdiscord.EventPipe.inject({chan, auth, state}, %{
        action: action,
        msg: "#{nick} #{action}"
      })
    end)

    action = convert_message_to_discord(action)
    IO.inspect("Sending emote From IRC to Discord: **#{nick}** #{action}", label: "State")
    # Alchemy.Client.send_message("320192373437104130", "_**#{nick}** #{action}_")
    dispatch_msg("#{nick} #{action}")
    message_extra(:me, action, auth, chan, state)
    {:noreply, state}
  end

  def handle_info({:topic_changed, _room, topic}, state) do
    IO.inspect(topic, label: :IRCTopic)
    {:noreply, state}
  end

  def handle_info({:names_list, _channel, names}, state) do
    IO.inspect(names, label: :IRCNames)
    {:noreply, state}
  end

  def handle_info({:who, channel, whos}, state) do
    # IO.inspect(whos, label: :IRCWhos)
    oldm =
      state.meta[:whos][channel]
      |> case do
        nil -> %{}
        v -> v
      end

    whosm = Map.new(whos, &{&1.nick, &1})
    now = NaiveDateTime.utc_now()

    # Joined
    whos
    |> List.wrap()
    |> Enum.each(fn %{away?: a, nick: nick, user: user} = who ->
      # IO.inspect({channel, who}, label: :IRCWho)

      case oldm[nick] do
        # Joined, handled in actual join
        nil ->
          # db_put(state, :kv, {:joined, nick}, now
          # db_put(state, :kv, {:joined, user}, now
          :ok

        # No longer away?
        %{away?: true} when a == false ->
          db_put(state, :kv, {:joined, nick}, now)
          db_put(state, :kv, {:joined, user}, now)
          IO.inspect(nick, label: :IsNoLongerAway)

          if(show_away?(who),
            do:
              send_msg_both("_`#{nick}` is no longer away_", channel, state.client,
                irc: false,
                discord: :simple
              )
          )

          if String.starts_with?(nick, "GregoriusTechneticies") do
            check_greg_xkcd(state)
          end

        # Rest is handled by the Parted section
        _ ->
          :ok
      end
    end)

    # Parted
    oldm
    |> Map.values()
    |> Enum.each(fn %{away?: b, nick: nick, user: user} = who ->
      case whosm[nick] do
        # Parted, handled in actual part
        nil ->
          :ok

        # Is now away
        %{away?: true} when b == false ->
          db_put(state, :kv, {:parted, nick}, now)
          db_put(state, :kv, {:parted, user}, now)
          IO.inspect(nick, label: :IsNowAway)

          if(show_away?(who),
            do:
              send_msg_both("_`#{nick}` is now away_", channel, state.client,
                irc: false,
                discord: :simple
              )
          )

        # Rest is handled by the Joined section
        _ ->
          :ok
      end
    end)

    state = %{state | meta: put_in(state.meta, [:whos, channel], whosm)}
    check_greg_xkcd(state)
    {:noreply, state}
  end

  # ExIRC parser is a bit borked it seems...  An empty AWAY is actually "AWAY\r\n"...
  def handle_info({:unrecognized, "AWAY" <> _, %{args: args, nick: nick}}, state) do
    # away? = if(args == [], do: false, else: true)
    #
    # whos =
    #  state.meta[:whos]
    #  |> Enum.map(fn
    #    {channel, %{^nick => who} = whos} ->
    #      IO.inspect({channel, who}, label: :AwayFoundWho)
    #      {channel, Map.put(whos, nick, %{who | away?: away?})}
    #
    #    {_channel, _whos} = kv ->
    #      kv
    #  end)
    #  |> Map.new()

    state.meta[:whos]
    |> Enum.each(fn
      {channel, %{^nick => _who}} ->
        IO.inspect({channel, nick, args}, label: :AwayUpdate)
        ExIRC.Client.who(state.client, "#gt-dev")

      _ ->
        :ok
    end)

    {:noreply, state}
  end

  def handle_info({:unrecognized, type, msg}, state) when type not in ["KICK"] do
    IO.inspect(
      "Unrecognized Message with type #{inspect(type)} and msg of: #{inspect(msg)}",
      label: "Fallthrough"
    )

    {:noreply, state}
  end

  def handle_info({:joined, "#gt-dev" = chan, %{host: host, nick: nick, user: user}}, state) do
    IO.inspect(
      "#{chan}: User `#{user}` with nick `#{nick}` joined from `#{host}`",
      label: "State"
    )

    ExIRC.Client.who(state.client, "#gt-dev")

    if not Enum.member?(["~peter", "~retep998"], user) do
      send_msg_both(
        "_`#{user}` as `#{nick}` has joined the room_",
        chan,
        state.client,
        irc: false,
        discord: :simple
      )
    end

    case db_get(state, :kv, {:joined, nick}) do
      nil ->
        send_msg_both(
          "Welcome to the \"GregoriusTechneticies Dev Chat\"!  Enjoy your stay!",
          chan,
          state.client
        )

      _ ->
        :ok
    end

    db_put(state, :kv, {:joined, nick}, NaiveDateTime.utc_now())
    db_put(state, :kv, {:joined, user}, NaiveDateTime.utc_now())

    if String.starts_with?(nick, "GregoriusTechneticies") do
      check_greg_xkcd(state)
    end

    # last = {_, s, _} = state.meta.logouts[host] || 0
    # last = :erlang.setelement(2, last, s+(60*5))
    # if chan == "#gt-dev-test" and :erlang.now() > last do
    #  ExIRC.Client.msg(state.client, :privmsg, chan, "Welcome #{nick}!")
    # end
    {:noreply, state}
  end

  def handle_info({:parted, "#gt-dev" = chan, %{host: host, nick: nick, user: user}}, state) do
    IO.inspect("#{chan}: User `#{user}` with nick `#{nick} parted from `#{host}`", label: "State")

    ExIRC.Client.who(state.client, "#gt-dev")

    send_msg_both(
      "_`#{user}` as `#{nick}` parted from the room_",
      chan,
      state.client,
      irc: false,
      discord: :simple
    )

    db_put(state, :kv, {:parted, user}, NaiveDateTime.utc_now())
    {:noreply, state}
  end

  def handle_info({:quit, msg, %{host: host, nick: nick, user: user}}, state) do
    IO.inspect(
      "User `#{user}` with nick `#{nick}` at host `#{host}` quit with message: #{msg}",
      label: "State"
    )

    if not Enum.member?(["~peter", "~retep998"], user) do
      send_msg_both(
        "_`#{user}` as `#{nick}` quit from the server: #{msg}_",
        "#gt-dev",
        state.client,
        irc: false,
        discord: :simple
      )
    end

    # state = put_in(state.meta.logouts[host], :erlang.now())
    {:noreply, state}
  end

  def handle_info(
        {:unrecognized, "KICK",
         %{
           args: [chan, nick, msg],
           cmd: "KICK",
           host: _kicker_host,
           nick: kicker,
           user: _kicker_user
         }},
        state
      ) do
    IO.inspect("User `#{kicker}` kicked `#{nick}` with message: #{msg}")

    send_msg_both("`#{kicker}` kicked `#{nick}` with message: #{msg}", chan, state.client,
      irc: false,
      discord: :simple
    )

    {:noreply, state}
  end

  def handle_info(:disconnected, state) do
    ExIRC.Client.connect!(state.client, state.host, state.port)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, :normal}, state)
      when is_reference(ref) and is_pid(pid) do
    {:noreply, state}
  end

  def handle_info({ref, :error}, state) when is_reference(ref) do
    {:noreply, state}
  end

  def handle_info(msg, state) do
    IO.inspect("Unknown IRC message: #{inspect(msg)}", label: "Fallthrough")
    {:noreply, state}
  end

  def code_change(old_vsn, old_state, extra_data) do
    IO.inspect({old_vsn, old_state, extra_data}, label: :Code_Change)
  end

  def terminate(reason, state) do
    IO.puts("Terminating IRC Bridge for reason: #{inspect(reason)}")
    # ExIRC.Client.quit(state.client, "Disconnecting for controlled shutdown")
    ExIRC.Client.stop!(state.client)
  end

  def convert_message_to_discord(msg) do
    msg =
      Regex.replace(~R/([^<]|^)\B@!?([a-zA-Z0-9]+)\b/i, msg, fn full, pre, username ->
        down_username = String.downcase(username)

        try do
          if down_username in ["everyone"] do
            "#{pre}@ everyone"
          else
            case Alchemy.Cache.search(:members, fn
                   %{user: %{username: ^username}} ->
                     true

                   %{user: %{username: discord_username}} ->
                     down_username == String.downcase(discord_username)

                   _ ->
                     false
                 end) do
              [%{user: %{id: id}}] ->
                [pre, ?<, ?@, id, ?>]

              s ->
                IO.inspect(s, label: :MemberNotFound)
                full
            end
          end
        rescue
          r ->
            IO.inspect(r, label: :ERROR_ALCHEMY_EXCEPTION)
            full
        catch
          e ->
            IO.inspect(e, label: :ERROR_ALCHEMY)
            full
        end
      end)

    msg
    |> String.replace(~R/@?\bbear989\b|@?\bbear989sr\b|@?\bbear\b/i, "<@225728625238999050>")
    |> String.replace(
      ~R/@?\bqwertygiy\b|@?\bqwerty\b|@?\bqwertys\b|@?\bqwertz\b|@?\bqwertzs\b/i,
      "<@80832726017511424>"
    )
    |> String.replace(~R/@?\bSuperCoder79\b/i, "<@222338097604460545>")
    |> String.replace(~R/@?\bandyafw\b|\bandy\b|\banna\b/i, "<@179586256752214016>")
    |> String.replace(~R/@?\bcrazyj1984\b|\bcrazyj\b/i, "<@225742972145238018>")
    |> String.replace(~R/@?\bSpeiger\b/i, "<@90867844530573312>")
    |> String.replace(~R/@?\bnetmc\b/i, "<@185586090416013312>")
    |> String.replace(~R/@?\be99+\b/i, "<@349598994193711124>")
    |> String.replace(~R/@?\bdbp\b|@?\bdpb\b/i, "<@138742528051642369>")
    |> String.replace(~R/@?\baxlegear\b/i, "<@226165192814362634>")
    |> to_string()
  end

  def alchemy_channel(), do: "320192373437104130"

  def send_msg_both(msgs, chan, client, opts \\ [])

  def send_msg_both(msgs, chan, %{client: client}, opts) do
    send_msg_both(msgs, chan, client, opts)
  end

  def send_msg_both(msgs, chan, client, opts) do
    prefix = opts[:prefix] || "> "

    if opts[:irc] != false do
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
            ExIRC.Client.msg(client, :privmsg, chan, prefix <> msg)
            dispatch_msg(msg)
            Process.sleep(200)
          end)
        end)
      end)
    end

    if opts[:discord] != false and chan == "#gt-dev" do
      amsg =
        if opts[:discord] == :simple do
          msgs
          |> List.wrap()
          |> Enum.join("\n")
          |> String.replace("\n", "\n#{prefix}")
          |> case do
            s -> prefix <> s
          end
        else
          msgs
          |> List.wrap()
          |> Enum.join("\n")
          |> String.replace("\n", "\n#{prefix}")
          |> case do
            s -> prefix <> s
          end
          |> convert_message_to_discord()
        end

      Alchemy.Client.send_message(alchemy_channel(), amsg)
    end

    nil
  end

  def message_cmd(call, args, auth, chan, state)
  # def message_cmd("factorio", "demo", _auth, chan, state) do
  #  msg = "Try the Factorio Demo at https://factorio.com/download-demo and you'll love it!"
  #  send_msg_both(msg, chan, state.client)
  # end
  # def message_cmd("factorio", _args, _auth, chan, state) do
  #  msg = "Factorio is awesome!  See the demonstration video at https://factorio.com or better yet grab the demo at https://factorio.com/download-demo and give it a try!"
  #  send_msg_both(msg, chan, state.client)
  # end
  def message_cmd(cmd, args, auth, chan, state) do
    # This is not allocated on every invocation, it is interned
    cache = %{
      "changelog" => fn _cmd, args, _auth, chan, state ->
        case args do
          "link" ->
            "https://gregtech.overminddl1.com/com/gregoriust/gregtech/gregtech_1.7.10/changelog.txt"

          _ ->
            case Overdiscord.Commands.GT6.get_changelog_version(args) do
              {:error, msgs} ->
                Enum.map(msgs, &send_msg_both(&1, chan, state.client))
                nil

              {:ok, %{changesets: []}} ->
                send_msg_both(
                  "Changelog has no changesets in it, check:  https://gregtech.overminddl1.com/com/gregoriust/gregtech/gregtech_1.7.10/changelog.txt",
                  chan,
                  state.client
                )

                nil

              {:ok, changelog} ->
                msgs = Overdiscord.Commands.GT6.format_changelog_as_text(changelog)

                Enum.map(msgs, fn msg ->
                  Enum.map(String.split(to_string(msg), ["\r\n", "\n"]), fn msg ->
                    Enum.map(split_at_irc_max_length(msg), fn msg ->
                      ExIRC.Client.msg(state.client, :privmsg, chan, msg)
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
      "xkcd" => fn _cmd, args, _auth, _chan, _state ->
        case Integer.parse(String.trim(args)) do
          {id, ""} ->
            "https://xkcd.com/#{id}"

          _ ->
            with(
              xkcd_link when xkcd_link != nil <- db_get(state, :kv, :xkcd_link),
              xkcd_title when xkcd_title != nil <- db_get(state, :kv, :xkcd_title),
              do: "#{xkcd_link} #{xkcd_title}"
            )
        end
      end,
      "google" => fn _cmd, args, _auth, _chan, _state ->
        "https://lmgtfy.com/?q=#{URI.encode(args)}"
      end,
      "wiki" => fn _cmd, args, _auth, chan, state ->
        url = IO.inspect("https://en.wikipedia.org/wiki/#{URI.encode(args)}", label: "Lookup")
        message_cmd_url_with_summary(url, chan, state.client)
        nil
      end,
      "ftbwiki" => fn _cmd, args, _auth, chan, state ->
        url = IO.inspect("https://ftb.gamepedia.com/#{URI.encode(args)}", label: "Lookup")
        message_cmd_url_with_summary(url, chan, state.client)
        nil
      end,
      "eval-lua" => fn _cmd, args, _auth, chan, state ->
        lua_eval_msg(state, chan, args)
      end,
      "calc" => fn _cmd, args, _auth, chan, state ->
        lua_eval_msg(state, chan, "return (#{args})")
      end,
      "status" => fn cmd, args, _auth, _chan, state ->
        case args do
          "" ->
            "Syntax: #{cmd} <username>"

          _ ->
            case Alchemy.Cache.search(:members, &(&1.user.username == args)) do
              [] ->
                "Unable to locate member_id of: #{args}"

              [%{user: %{id: id}}] ->
                case Alchemy.Cache.presence("225742287991341057", id) do
                  {:ok, %Alchemy.Guild.Presence{game: game, status: status}} ->
                    game = if(game == nil, do: "", else: " and is running #{game}")

                    lastseen =
                      case db_get(state, :kv, {:lastseen, args}) do
                        nil ->
                          "has not been seen active here yet"

                        date ->
                          now = System.system_time(:seconds)
                          ago = now - Timex.to_unix(date)
                          "was last seen active here at `#{date}` (#{ago}s ago)"
                      end

                    "#{args} is `#{status}` and #{lastseen}#{game}"

                  _error ->
                    "No status information in the cache for: #{args}"
                end

              [_ | _] = members ->
                IO.inspect(members, label: "Multiple Members?!")
                "Found multiple members?!"
            end
        end
      end,
      "delay" => fn cmd, args, auth, chan, state ->
        case String.split(args, " ", parts: 2, trim: true) do
          [] ->
            [
              "Usage: #{cmd} <reltimespec|\"next\"|\"list\"|\"until\"|\"remove\"> <msg...>",
              "Example: `?delay 1d2h3m4s message test` will result in a delayed posting of the text `message test` by this bot after 1 day, 2 hours, 3 minutes and 4 seconds."
            ]

          ["remove" | removeable] ->
            nic = auth.nick
            # now = System.system_time(:second)

            db_get(state, :set, :delay_msgs)
            |> Enum.filter(fn
              {_time, _host, ^chan, ^nic, _msg} -> true
              _ -> false
            end)
            |> Enum.sort_by(fn
              {%dts{} = datetime, _host, _chan, _nick, _msg}
              when dts in [NaiveDateTime, DateTime] ->
                Timex.to_unix(datetime)

              {unixtime, _host, _chan, _nick, _msg} ->
                unixtime
            end)
            |> case do
              [] ->
                "No pending delays to remove"

              [{_time, _host, _chan, _nick, msg} = rec | _rest] = msgs ->
                case removeable do
                  next when next in [[], ["next"]] ->
                    # time = if(is_integer(time), do: Timex.from_unix(time), else: time)
                    db_put(state, :set_remove, :delay_msgs, rec)
                    "Removed next pending delay that had the message: #{msg}"

                  [search_string] ->
                    case Integer.parse(search_string) do
                      {idx, ""} ->
                        Enum.at(msgs, idx)

                      _ ->
                        Enum.find(
                          msgs,
                          &Enum.any?(List.wrap(elem(&1, 4)), fn m ->
                            String.contains?(m, search_string)
                          end)
                        )
                    end
                    |> case do
                      nil ->
                        "No message found that contains: #{search_string}"

                      {_time, _host, _chan, _nick, msg} = rec ->
                        db_put(state, :set_remove, :delay_msgs, rec)
                        "Removed next pending delay that had the message: #{msg}"
                    end
                end
            end

          ["next" | searchable] ->
            nic = auth.nick
            now = System.system_time(:second)

            searchable =
              case searchable do
                [] ->
                  nil

                [search_string] ->
                  case Integer.parse(search_string) do
                    {idx, ""} -> idx
                    _ -> search_string
                  end
              end

            db_get(state, :set, :delay_msgs)
            |> Enum.filter(fn
              {_time, _host, ^chan, ^nic, msg} ->
                case searchable do
                  nil -> true
                  idx when is_integer(idx) -> true
                  search_string -> String.contains?(msg, search_string)
                end

              _ ->
                false
            end)
            |> Enum.sort_by(fn
              {%dts{} = datetime, _host, _chan, _nick, _msg}
              when dts in [NaiveDateTime, DateTime] ->
                Timex.to_unix(datetime)

              {unixtime, _host, _chan, _nick, _msg} ->
                unixtime
            end)
            |> case do
              lst ->
                if is_integer(searchable) do
                  Enum.at(lst, searchable, lst)
                  |> List.wrap()
                else
                  lst
                end
            end
            |> case do
              [{time, _host, _chan, nick, msg} | _rest] ->
                time =
                  case time do
                    %NaiveDateTime{} ->
                      time

                    %DateTime{} ->
                      time

                    time ->
                      case db_get(state, :kv, {:setting, {:nick, nick}, :timezone}) do
                        nil ->
                          {:ok, dtime} = DateTime.from_unix(time)
                          dtime

                        timezone ->
                          dtime = Timex.from_unix(time)
                          # TODO:  Add error checking
                          Timex.to_datetime(dtime, timezone)
                      end
                  end

                # "{ISO:Extended}")
                formatted =
                  Timex.format!(time, "{YYYY}-{M}-{D} {Mfull} {WDfull} {h24}:{m}:{s}{ss}")

                trange = Timex.to_unix(time) - now

                "Next pending delay message from #{nick} set to appear at #{formatted}, (#{trange}s away): #{
                  msg
                }"

              _ ->
                "No pending messages"
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
            |> Enum.map(fn
              {unixtime, _host, _chan, _nick, _msg} when is_integer(unixtime) ->
                "#{unixtime - now}s"

              {time, _host, _chan, _nick, _msg} ->
                to_string(time)
            end)
            |> case do
              [] -> "No pending messages"
              lst -> "Pending delays remaining: #{Enum.join(lst, " ")}"
            end

          ["until"] ->
            [
              "Usage: #{cmd} until <abstimespec> <msg...>",
              "Time format is standard ISO8601 with optional date part (defaults to the current/next 24-hr period)"
            ]

          ["until", args] ->
            [timespec | msg] = String.split(args, " ", parts: 2, trim: 2)

            {timespec, relative} =
              case String.split(timespec, "P", parts: 2, trim: 2) do
                [timespec] -> {timespec, Timex.Duration.parse("PT0S")}
                [timespec, relative] -> {timespec, Timex.Duration.parse("P" <> relative)}
              end

            timespec =
              if timespec == "" do
                now =
                  case db_get(state, :kv, {:setting, {:nick, auth.nick}, :timezone}) do
                    nil -> Timex.now()
                    timezone -> Timex.now(timezone)
                  end

                Timex.format!(now, "{ISO:Extended}")
                |> String.replace(~R/(\+|-)\d\d:\d\d/, "")
                |> IO.inspect(label: "Timespec Test")
              else
                timespec
              end

            String.contains?(timespec, "T")
            |> if do
              timespec
            else
              today = Date.utc_today()
              year = String.pad_leading(to_string(today.year), 4, "0")
              month = String.pad_leading(to_string(today.month), 2, "0")
              day = String.pad_leading(to_string(today.day), 2, "0")
              "#{year}-#{month}-#{day}T#{timespec}"
            end
            |> Timex.parse("{ISO:Extended}")
            |> case do
              {:error, _reason} = err ->
                err

              {:ok, datetime} ->
                case relative do
                  {:error, _reason} = err -> err
                  {:ok, duration} -> {:ok, Timex.add(datetime, duration)}
                end
            end
            |> case do
              {:error, _reason} = err ->
                err

              {:ok, %DateTime{} = timespec} ->
                {:ok, timespec}

              {:ok, %NaiveDateTime{} = timespec} ->
                case db_get(state, :kv, {:setting, {:nick, auth.nick}, :timezone}) do
                  nil ->
                    {:ok, timespec}

                  timezone ->
                    now = Timex.now(timezone)
                    datetime = Map.merge(now, %{timespec | __struct__: DateTime})
                    # if Timex.compare(datetime, now) < 0 do
                    #   {:ok, Timex.add(datetime, Timex.Duration.from_days(1))}
                    # else
                    #   {:ok, datetime}
                    # end
                    {:ok, datetime}
                end
            end
            |> case do
              {:error, reason} ->
                "Timespec error:  #{reason}"

              {:ok, datetime} ->
                case auth do
                  # Local
                  %{host: "6.ip-144-217-164.net"} ->
                    12

                  # OvermindDL1
                  %{host: "id-16796." <> _} ->
                    12

                  # Greg
                  %{host: "ipservice-" <> _, user: "~Gregorius"} ->
                    12

                  %{host: "ltea-" <> _, use: "~Gregorius"} ->
                    12

                  # SuperCoder79
                  %{host: "id-276919" <> _, user: "uid276919"} ->
                    1

                  _ ->
                    0
                end
                |> case do
                  0 ->
                    if msg == [] do
                      "Parsed timespec is for:  #{datetime}"
                    else
                      "You are not allowed to use this command"
                    end

                  limit ->
                    if msg == [] do
                      "Parsed timespec is for: #{datetime}"
                    else
                      now = System.system_time(:second)
                      delays = db_get(state, :set, :delay_msgs)

                      if limit <= Enum.count(delays, &(elem(&1, 1) == auth.host)) do
                        "You have too many pending delayed messages, wait until some have elapsed: #{
                          Enum.count(delays, &(elem(&1, 1) == auth.host))
                        }"
                      else
                        db_put(
                          state,
                          :set_add,
                          :delay_msgs,
                          {datetime, auth.host, chan, auth.nick, msg}
                        )

                        seconds = Timex.to_unix(datetime)
                        send_in = if(seconds - now < 0, do: 0, else: seconds * 1000)
                        Process.send_after(self(), :poll_delay_msgs, send_in)

                        formatted =
                          Timex.format!(
                            datetime,
                            "{YYYY}-{M}-{D} {Mfull} {WDfull} {h24}:{m}:{s}{ss}"
                          )

                        "Delayed message set to occur at #{formatted}"
                      end
                    end
                end
            end

          [timespec] ->
            case parse_relativetime_to_seconds(timespec) do
              {:ok, seconds} -> "Parsed timespec is for #{seconds} seconds"
              {:error, reason} -> "Invalid timespec: #{reason}"
            end

          [timespec, msg] ->
            case parse_relativetime_to_seconds(timespec) do
              {:error, reason} ->
                "Invalid timespec: #{reason}"

              {:ok, seconds} ->
                case auth do
                  # Local
                  %{host: "6.ip-144-217-164.net"} ->
                    12

                  # OvermindDL1
                  %{host: "id-16796." <> _} ->
                    12

                  # Greg
                  %{host: "ipservice-" <> _, user: "~Gregorius"} ->
                    12

                  %{host: "ltea-" <> _, user: "~Gregorius"} ->
                    12

                  # SuperCoder79
                  %{host: "id-276919" <> _, user: "uid276919"} ->
                    1

                  _ ->
                    0
                end
                |> case do
                  0 ->
                    "You are not allowed to use this command"

                  limit ->
                    now = System.system_time(:second)
                    delays = db_get(state, :set, :delay_msgs)

                    if limit <= Enum.count(delays, &(elem(&1, 1) == auth.host)) do
                      "You have too many pending delayed messages, wait until some have elapsed: #{
                        Enum.count(delays, &(elem(&1, 1) == auth.host))
                      }"
                    else
                      db_put(
                        state,
                        :set_add,
                        :delay_msgs,
                        {now + seconds, auth.host, chan, auth.nick, msg}
                      )

                      Process.send_after(self(), :poll_delay_msgs, seconds * 1000)
                      "Delayed message added for #{seconds} seconds"
                    end
                end
            end
        end
      end,
      "reboot" => fn _cmd, _args, auth, _chan, _state ->
        if not is_admin(auth) do
          "You do not have access to this command"
        else
          spawn(fn ->
            Process.sleep(2000)
            :init.stop()
          end)

          "Rebooting in 2 seconds"
        end
      end,
      "set-name-format" => fn cmd, args, auth, _chan, state ->
        if not is_admin(auth) do
          "You do not have access to this command"
        else
          case String.split(String.trim(args), " ", parts: 2, trim: true) do
            [] ->
              [
                "Usage: #{cmd} <name> [formatting-code]",
                "Valid format codes (hyphen-separated): #{
                  Enum.join(tl(get_valid_format_codes()), "|")
                }",
                "Example: #{cmd} SomeonesName fat-blue",
                "Leave out the formatting code to clear format settings for the given name"
              ]

            [name] ->
              db_delete(state, :kv, {:name_formatting, name})
              "Cleared formatting on #{name}"

            [name, formatting] ->
              case get_format_code(formatting) do
                "" ->
                  "Invalid formatting code"

                formatting ->
                  db_put(state, :kv, {:name_formatting, name}, formatting)
                  "Set formatting for #{formatting}#{name}#{get_format_code("reset")}"
              end
          end
        end
      end,
      "screenshot" => fn _cmd, _args, _auth, _chan, _state ->
        %{body: url, status_code: url_code} =
          HTTPoison.get!(
            "https://gregtech.overminddl1.com/com/gregoriust/gregtech/screenshots/LATEST.url"
          )

        case url_code do
          200 ->
            %{body: description, status_code: description_code} =
              HTTPoison.get!("https://gregtech.overminddl1.com/imagecaption.adoc")

            description =
              case description do
                "." <> desc -> desc
                "\uFEFF." <> desc -> desc
                desc -> "Blargh" <> desc
              end

            case description_code do
              200 -> ["https://gregtech.overminddl1.com#{url}", description]
              _ -> url
            end

          _ ->
            "Unable to retrieve image URL, report this error to OvermindDL1"
        end
      end,
      "escape" => fn _cmd, arg, _auth, _chan, _state ->
        irc_unping(arg)
      end,
      "list" => fn _cmd, _args, _auth, chan, state ->
        try do
          names =
            Alchemy.Cache.search(:members, &(&1.user.bot == false))
            |> Enum.map(& &1.user.username)
            |> Enum.sort()
            |> Enum.map(&irc_unping/1)
            |> Enum.join("` `")

          send_msg_both("Discord Names: `#{names}`", chan, state.client, discord: false)
          nil
        rescue
          r ->
            IO.inspect(r, label: :DiscordNameCacheError)

            ExIRC.Client.msg(
              state.client,
              :privmsg,
              chan,
              "Discord name server query is not responding, try later"
            )

            nil
        end
      end,
      "solve" => fn cmd, arg, _auth, chan, state ->
        case String.split(String.trim(arg), " ", parts: 2) do
          [""] ->
            [
              "Format: #{cmd} <cmd> <expression...>",
              "Valid commands: abs log sin cos tan arcsin arccos arctan simplify factor zeroes solve derive integrate"
            ]

          [_cmmd] ->
            [
              "Require an expression"
            ]

          [cmmd, expr] ->
            mdlt(cmmd, expr, chan, state)
        end
      end,
      # "abs" => &mdlt(&1, &2, &4, &5, [ignore: &3]),
      # "log" => &mdlt(&1, &2, &4, &5, [ignore: &3]),
      # "sin" => &mdlt(&1, &2, &4, &5, [ignore: &3]),
      # "cos" => &mdlt(&1, &2, &4, &5, [ignore: &3]),
      # "tan" => &mdlt(&1, &2, &4, &5, [ignore: &3]),
      # "arcsin" => &mdlt(&1, &2, &4, &5, [ignore: &3]),
      # "arccos" => &mdlt(&1, &2, &4, &5, [ignore: &3]),
      # "arctan" => &mdlt(&1, &2, &4, &5, [ignore: &3]),
      # "simplify" => &mdlt(&1, &2, &4, &5, [ignore: &3]),
      # "factor" => &mdlt(&1, &2, &4, &5, [ignore: &3]),
      # "zeroes" => &mdlt(&1, &2, &4, &5, [ignore: &3]),
      # "solve" => &mdlt(&1, &2, &4, &5, [ignore: &3]),
      # "derive" => &mdlt(&1, &2, &4, &5, [ignore: &3]),
      # "integrate" => &mdlt(&1, &2, &4, &5, [ignore: &3]),
      "set" => fn cmd, arg, auth, _chan, state ->
        case String.split(String.trim(arg), " ", trim: true, parts: 3) do
          [""] ->
            "Usage: #{cmd} <scope> <setting> {value}"

          ["me" | args] ->
            case args do
              ["timezone"] ->
                v = db_get(state, :kv, {:setting, {:nick, auth.nick}, :timezone})

                [
                  "Current value: #{v || "<unset>"}",
                  "To clear the setting use \"clear\", else use an official timezone designation name such as `America/Chicago` or `-4`.  Use an official name to 'maybe' support daylight savings"
                ]

              ["timezone", "clear"] ->
                db_delete(state, :kv, {:setting, {:nick, auth.nick}, :timezone})
                "Cleared `timezone`"

              ["timezone", timezone] ->
                case Timex.now(timezone) do
                  {:error, _reason} ->
                    "Invalid timezone designation"

                  %{time_zone: timezone} ->
                    db_put(state, :kv, {:setting, {:nick, auth.nick}, :timezone}, timezone)
                    "Successfully set timezone to: #{timezone}"
                end

              _ ->
                "unknown setting name in the user scope of:  #{List.first(args)}"
            end

          _ ->
            "Unknown scope"
        end
      end,
      "lastseen" => fn _cmd, arg, _auth, chan, state ->
        arg = String.trim(arg)

        case db_get(state, :kv, {:lastseen, arg}) do
          nil ->
            send_msg_both("`#{arg}` has not been seen speaking before", chan, state.client)

          date ->
            now = NaiveDateTime.utc_now()
            diff_sec = NaiveDateTime.diff(now, date)

            diff =
              cond do
                diff_sec < 60 -> "#{diff_sec} seconds ago"
                diff_sec < 60 * 60 -> "#{div(diff_sec, 60)} minutes ago"
                diff_sec < 60 * 60 * 24 -> "#{div(diff_sec, 60 * 60)} hours ago"
                true -> "#{div(diff_sec, 60 * 60 * 24)} days ago"
              end

            send_msg_both(
              "`#{arg}` last said something #{diff} at: #{date} GMT",
              chan,
              state.client
            )
        end
      end,
      "setphrase" => fn cmd, args, auth, chan, state ->
        case auth do
          %{host: "6.ip-144-217-164.net"} -> true
          %{host: "id-16796." <> _, user: "uid16796"} -> true
          %{host: "ipservice-" <> _, user: "~Gregorius"} -> true
          %{host: "ltea-" <> _, user: "~Gregorius"} -> true
          _ -> false
        end
        |> if do
          case String.split(args, " ", parts: 2)
               |> Enum.map(&String.trim/1)
               |> Enum.filter(&(&1 != "")) do
            [] ->
              send_msg_both(
                "Format: #{cmd} <phrase-cmd> {phrase}\nIf the phrase is missing or blank then it deletes the command",
                chan,
                state.client
              )

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

                [_ | _] = old when length(old) >= 8 ->
                  send_msg_both(
                    "Existing phrase `#{cmd}` already has too many lines",
                    chan,
                    state.client
                  )

                old ->
                  db_put(state, :kv, {:phrase, cmd}, List.wrap(old) ++ [phrase])

                  send_msg_both(
                    "Extended existing phrase `#{cmd}` with new line",
                    chan,
                    state.client
                  )
              end
          end
        else
          send_msg_both("You don't have access", chan, state.client)
        end

        nil
      end
    }

    case Map.get(cache, cmd) do
      nil ->
        case cmd do
          "help" ->
            if args == "" do
              msg =
                cache
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
              nil ->
                nil

              phrase ->
                send_msg_both(phrase, chan, state.client)
                message_extra(:phrase, args, auth, chan, state)
            end
        end

      msg when is_binary(msg) ->
        send_msg_both(msg, chan, state.client)

      [_ | _] = msgs ->
        Enum.map(msgs, &send_msg_both(&1, chan, state.client))

      fun when is_function(fun, 5) ->
        case fun.(cmd, args, auth, chan, state) do
          nil ->
            nil

          str when is_binary(str) ->
            send_msg_both(str, chan, state.client)

          [] ->
            nil

          [_ | _] = msgs when length(msgs) > 4 ->
            Enum.map(msgs, fn msg ->
              send_msg_both(msg, chan, state.client)
              Process.sleep(200)
            end)

          [_ | _] = msgs ->
            Enum.map(msgs, &send_msg_both(&1, chan, state.client))
        end
    end
  rescue
    exc ->
      IO.puts("COMMAND_EXCEPTION" <> Exception.format(:error, exc))

      send_msg_both(
        "Exception in command execution, report this to OvermindDL1",
        chan,
        state.client
      )
  catch
    e ->
      IO.inspect(e, label: :COMMAND_CRASH)
      send_msg_both("Crash in command execution, report this to OvermindDL1", chan, state.client)
  end

  def message_cmd_url_with_summary(url, chan, client) do
    ExIRC.Client.msg(client, :privmsg, chan, url)

    case IO.inspect(Overdiscord.SiteParser.get_summary_cached(url), label: :UrlSummary) do
      nil -> "No information found at URL"
      summary -> send_msg_both(summary, chan, client, discord: false)
    end
  end

  def message_extra(:msg, "?TEST " <> cmd, auth, chan, state) do
    IO.inspect({cmd, auth, chan, state}, label: :TEST_MESSAGE)
    Overdiscord.Cmd.task_handle_cmd(:msg, {chan, auth, state}, cmd)
    nil
  end

  def message_extra(:msg, "?" <> cmd, auth, chan, state) do
    [call | args] = String.split(cmd, " ", parts: 2)
    args = String.trim(to_string(args))
    message_cmd(call, args, auth, chan, state)
  end

  def message_extra(:msg, "ß" <> cmd, auth, chan, state) do
    [call | args] = String.split(cmd, " ", parts: 2)
    args = String.trim(to_string(args))
    message_cmd(call, args, auth, chan, state)
  end

  def message_extra(:msg, "=2+2", _auth, chan, state) do
    send_msg_both("Fish", chan, state.client)
  end

  def message_extra(:msg, "=", _auth, chan, state) do
    send_msg_both(
      "General scientific calculator, try `=2pi` or `=toCelsius(fromFahrenheit(98))`",
      chan,
      state.client
    )
  end

  def message_extra(:msg, "=" <> expression, _auth, chan, state) do
    # lua_eval_msg(
    #   state,
    #   chan,
    #   "return #{expression}",
    #   cb: fn
    #     {:ok, [result]} -> send_msg_both("#{inspect(result)}", chan, state.client)
    #     {:ok, result} -> send_msg_both("#{inspect(result)}", chan, state.client)
    #     {:error, _reason} -> send_msg_both("= <failed>", chan, state.client)
    #   end
    # )
    IO.inspect({:request, expression}, label: :Insect)

    case System.cmd("/var/insect/index.js", [expression], stderr_to_stdout: true) do
      {"", 0} ->
        send_msg_both("=> <Invalid Input>", chan, state.client)

      {result, 0} ->
        result = String.trim(result)
        result = String.replace(result, ~R/\e[[][0-9]+m/, "")
        IO.inspect({:result, result}, label: :Insect)
        send_msg_both("=> " <> result, chan, state.client)

      {reason, code} ->
        id = :erlang.unique_integer()
        IO.inspect({id, reason, code}, label: :Insect)

        send_msg_both(
          "Failed with error, report to OvermindDL1 with code: #{inspect(id)}",
          chan,
          state.client
        )
    end
  end

  def message_extra(_type, msg, _auth, chan, %{client: client} = _state) do
    # URL summary
    # Regex.scan(~r"https?://[^)\]\s]+"i, msg, captures: :first)
    Regex.scan(~R"\((https?://\S+)\)|(https?://\S+)"i, msg, capture: :all_but_first)
    # |> IO.inspect(label: :ExtraScan)
    |> Enum.map(&Enum.join/1)
    # |> IO.inspect(label: :ExtraScan1)
    |> Enum.map(fn url ->
      if url =~ ~r/xkcd.com/i do
        []
      else
        case IO.inspect(Overdiscord.SiteParser.get_summary_cached(url), label: :Summary) do
          nil ->
            nil

          summary ->
            if summary =~
                 ~r/Minecraft Mod by GregoriusT - overhauling your Minecraft experience completely/ do
              nil
            else
              send_msg_both(summary, chan, client, discord: false)
            end
        end
      end

      # _ ->
      #  []
    end)

    # Reddit subreddit links
    Regex.scan(~r"(^|[^/]\b)(?<sr>r/[a-zA-Z0-9_-]{4,})($|[^/])"i, msg, captures: :all)
    |> Enum.map(fn
      [_, _, sr, _] -> "https://www.reddit.com/#{sr}/"
      _ -> false
    end)
    |> Enum.filter(& &1)
    |> Enum.join(" ")
    |> (fn
          "" -> nil
          srs -> ExIRC.Client.msg(client, :privmsg, chan, srs)
        end).()
  end

  defp handle_greg(msg, client) do
    msg = String.downcase(msg)
    last_msg_part = String.slice(msg, -26, 26)

    cond do
      IO.inspect(
        String.jaro_distance("good night/bye everyone o/", last_msg_part),
        label: :Distance
      ) > 0.87 or msg =~ ~r"bye everyone"i ->
        ExIRC.Client.msg(client, :privmsg, "#gt-dev", Enum.random(farewells()))

      true ->
        :ok
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

    if last_link != xkcd_link and
         IO.inspect(away?(state, "#gt-dev", nick: "GregoriusTechneticies") == false) do
      db_put(state, :kv, :xkcd_greg_link, xkcd_link)
      send_msg_both("#{xkcd_link} #{xkcd_title}", "#gt-dev", state.client)
      true
    else
      nil
    end
  end

  def split_at_irc_max_length(msg) do
    # TODO: Look into this more, fails on edge cases...
    # IO.inspect(msg, label: :Unicode?)
    # Regex.scan(~R".{1,420}\s\W?"iu, msg, capture: :first)# Actually 425, but safety margin
    # [[msg]]
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
      :not_found ->
        db

      {:ok, values} ->
        oldValues = :erlang.binary_to_term(values, [:safe])
        values = Map.delete(oldValues, value)
        Exleveldb.put(db, key, values)
    end
  end

  def db_put(db, type, key, value) do
    IO.inspect(
      "Invalid DB put type of `#{inspect(type)}` of key `#{inspect(key)}` with value: #{
        inspect(value)
      }",
      label: :ERROR_DB_TYPE
    )

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
      :not_found ->
        []

      {:ok, values} ->
        values = :erlang.binary_to_term(values, [:safe])
        Map.keys(values)
    end
  end

  def db_get(_db, type, key) do
    IO.inspect(
      "Invalid DB get type for `#{inspect(type)}` of key `#{inspect(key)}`",
      label: :ERROR_DB_TYPE
    )

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
    IO.inspect(
      "Invalid DB delete type for `#{inspect(type)}` of key `#{inspect(key)}`",
      label: :ERROR_DB_TYPE
    )

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
  rescue
    r ->
      IO.inspect(r, label: :LuaException)
      {:error, r}
  catch
    e ->
      IO.inspect(e, label: :LuaError)
      {:error, e}
  end

  def lua_eval_msg(state, chan, expression, opts \\ []) do
    cb = opts[:cb]

    pid =
      spawn(fn ->
        case lua_eval(state, expression) do
          {:ok, result} ->
            if cb,
              do: cb.({:ok, result}),
              else: send_msg_both("Result: #{inspect(result)}", chan, state.client)

          {:error, reason} ->
            if cb,
              do: cb.({:error, reason}),
              else:
                send_msg_both(
                  "Failed running with reason: #{inspect(reason)}",
                  chan,
                  state.client
                )
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
      :error ->
        {:error, "Invalid number where number was expected: #{str}"}

      {value, rest} ->
        case reltime_mult(rest) do
          {:error, _} = error ->
            error

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
  defp reltime_mult("s" <> rest), do: {:ok, 1, rest}
  defp reltime_mult("m" <> rest), do: {:ok, 60, rest}
  defp reltime_mult("h" <> rest), do: {:ok, 60 * 60, rest}
  defp reltime_mult("d" <> rest), do: {:ok, 60 * 60 * 24, rest}
  defp reltime_mult("w" <> rest), do: {:ok, 60 * 60 * 24 * 7, rest}
  defp reltime_mult("M" <> rest), do: {:ok, 60 * 60 * 24 * 30, rest}
  defp reltime_mult("y" <> rest), do: {:ok, 60 * 60 * 24 * 365, rest}
  defp reltime_mult(str), do: {:error, "Invalid multiplier spec: #{str}"}

  def mdlt(op, expr, chan, state, opts \\ []) do
    pid =
      spawn(fn ->
        case System.cmd("mdlt", [op, expr]) do
          {result, _exit_code_which_is_always_0_grr} ->
            case String.split(result, "\n", parts: 2) do
              [] ->
                "#{inspect({op, expr})})} Error processing expression"

              [result | _] ->
                "#{op}(#{expr}) -> #{result}"
                # [err, _rest] -> "#{inspect({op, expr})} Error: #{err}"
            end

            # err ->
            #  IO.inspect({op, expr, err}, label: :MathSolverErr)
            #  "#{inspect({op, expr})} Error loading Math solver, report this to OvermindDL1"
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

  defp is_admin(auth)
  defp is_admin(%{host: "6.ip-144-217-164.net"}), do: true
  defp is_admin(%{user: "~uid16796"}), do: true
  defp is_admin(%{host: "id-16796." <> _}), do: true
  defp is_admin(%{host: "ipservice-" <> _, user: "~Gregorius"}), do: true
  defp is_admin(%{host: "ltea-" <> _, user: "~Gregorius"}), do: true

  defp is_admin(auth),
    do:
      (
        IO.inspect(auth, label: :AuthFailure)
        false
      )

  defp get_name_color(state, name) do
    case db_get(state, :kv, {:name_formatting, name}) do
      nil -> "\x02"
      code -> code
    end
  end

  # defp get_format_code(foreground, background) do
  #   foreground = get_format_code("-" <> foreground)
  #
  #   background =
  #     case get_color_format_code(background) do
  #       "" -> ""
  #       code -> ",#{code}"
  #     end
  #
  #   "#{foreground}#{background}"
  # end

  def get_format_code(format)
  def get_format_code(""), do: ""
  def get_format_code("reset"), do: "\x0F"
  def get_format_code("bold"), do: "\x02"
  def get_format_code("fat"), do: "\x02"
  def get_format_code("italic"), do: "\x1D"
  def get_format_code("underlined"), do: "\x1F"
  def get_format_code("swap"), do: "\x16"

  def get_format_code(color) do
    case String.split(color, "-", parts: 2, trim: true) do
      [] ->
        ""

      [color] ->
        case String.split(color, ":", parts: 2, trim: true) do
          [] ->
            ""

          [_fg] ->
            case get_format_code_color(color) do
              nil -> ""
              color -> "\x03#{color}"
            end

          [fg, bg] ->
            case {get_format_code_color(fg), get_format_code_color(bg)} do
              {nil, nil} -> ""
              {nil, bg} -> "\x0300,#{bg}"
              {fg, nil} -> "\x03#{fg}"
              {fg, bg} -> "\x03#{fg},#{bg}"
            end
        end

      [format, rest] ->
        "#{get_format_code(format)}#{get_format_code(rest)}"
    end
  end

  # nil -> Is not in room at all
  # false -> Is in room and is not away (is here)
  # true -> Is in room and is away (not here)
  def away?(state, channel, [{:nick, nick}]) do
    IO.inspect({channel, :nick, nick}, label: :AwayCheck)

    get_in(state.meta, [:whos, channel, nick])
    |> case do
      nil -> nil
      v -> Map.get(v, :away?)
    end
    |> IO.inspect(label: :AwayCheckResult)
  end

  def away?(state, channel, [{key, value}]) do
    IO.inspect({channel, key, value}, label: :AwayCheck)

    state.meta[:whos][channel]
    |> case do
      nil -> %{}
      v -> v
    end
    |> Map.values()
    |> Enum.find(&(Map.get(&1, key) == value))
    |> case do
      nil -> nil
      v -> Map.get(v, :away?)
    end
    |> IO.inspect(label: :AwayCheckResult)
  end

  def show_away?(%{operator?: true}), do: true
  def show_away?(_), do: true

  def cap?(state, cap) do
    case state.meta[:caps][cap] do
      nil -> false
      false -> false
      true -> true
      :requested -> false
    end
  end

  def get_format_code_color(color)
  def get_format_code_color("fgdefault"), do: "00"
  def get_format_code_color("bgdefault"), do: "01"
  def get_format_code_color("white"), do: "00"
  def get_format_code_color("black"), do: "01"
  def get_format_code_color("blue"), do: "02"
  def get_format_code_color("green"), do: "03"
  def get_format_code_color("red"), do: "04"
  def get_format_code_color("brown"), do: "05"
  def get_format_code_color("purple"), do: "06"
  def get_format_code_color("orange"), do: "07"
  def get_format_code_color("yellow"), do: "08"
  def get_format_code_color("lime"), do: "09"
  def get_format_code_color("teal"), do: "10"
  def get_format_code_color("cyan"), do: "11"
  def get_format_code_color("royal"), do: "12"
  def get_format_code_color("pink"), do: "13"
  def get_format_code_color("grey"), do: "14"
  def get_format_code_color("silver"), do: "15"
  def get_format_code_color(_color), do: nil

  def irc_unping(<<c::utf8>>), do: <<c::utf8, 204, 178>>
  def irc_unping(<<c::utf8, rest::binary>>), do: <<c::utf8, 226, 128, 139, rest::binary>>

  defp dispatch_msg(msg) do
    Overdiscord.Web.GregchatCommander.append_msg(msg)
  end

  def get_valid_format_codes,
    do: [
      "reset",
      "bold",
      "fat",
      "italic",
      "underlined",
      "swap",
      "fgdefault",
      "bgdefault",
      "white",
      "black",
      "blue",
      "green",
      "red",
      "brown",
      "purple",
      "orange",
      "yellow",
      "lime",
      "teal",
      "cyan",
      "royal",
      "pink",
      "grey",
      "silver"
    ]

  defp farewells,
    do: [
      "Fare thee well!",
      "Enjoy!",
      "Bloop!",
      "Be well",
      "Good bye",
      "See you later",
      "Have fun!"
    ]
end
