defmodule Overdiscord.IRC.Bridge do
  # TODO:  `?update` Download Link, Screenshot, Changelog order all at once

  @large_msg_lines 10

  require Logger

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

  def send_msg(auth, msg) do
    # IO.inspect({"Casting", auth, msg})
    :gen_server.cast(:irc_bridge, {:send_msg, auth, msg})
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

  def poll_feeds() do
    :gen_server.cast(:irc_bridge, :poll_feeds)
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
      %{reply?: true, simple_msg: msg} ->
        handle_cast({:send_msg, nil, {:simple, msg}, to}, state)

      %{reply?: true, msg: msg} ->
        handle_cast({:send_msg, nil, msg, to}, state)

      %{simple_msg: msg} ->
        handle_cast({:send_msg, %{nick: auth.nickname, user: ""}, {:simple, msg}, to}, state)

      %{msg: msg} ->
        handle_cast({:send_msg, %{nick: auth.nickname, user: ""}, msg, to}, state)

      %{irc_cmd: cmd} ->
        IO.inspect(%{event_data: event_data, auth: auth, to: to}, label: :IRCEventDataCmd)
        message_extra(:msg, cmd, %{nick: auth.nickname, user: ""}, "#gt-dev", state)
        {:noreply, state}

      _ ->
        IO.inspect(%{event_data: event_data, auth: auth, to: to}, label: :IRCUnhandledEventData)
        {:noreply, state}
    end
  end

  def handle_cast({:send_msg, auth, msg}, state) do
    handle_cast({:send_msg, auth, msg, "#gt-dev"}, state)
  end

  def handle_cast({:send_msg, auth, msg, chan}, state) do
    {is_simple_msg, msg} =
      case msg do
        msg when is_binary(msg) -> {false, msg}
        {:simple, msg} -> {true, msg}
      end

    prefix =
      case auth do
        nil ->
          "> "

        %{nick: nick, user: _user} ->
          nick_color = get_name_color(state, nick)

          db_user_messaged(state, %{nick: nick, user: nick, host: "#{nick}@Discord"}, msg)

          # |> Enum.flat_map(&split_at_irc_max_length/1)
          escaped_nick = irc_unping(nick)

          "#{nick_color}#{escaped_nick}\x0F: "
      end

    msg
    |> String.split("\n")
    |> IO.inspect()
    |> Enum.flat_map(&split_at_irc_max_length(prefix, &1))
    # |> Enum.split(10)
    |> case do
      [] ->
        0

      [line] ->
        ExIRC.Client.msg(state.client, :privmsg, chan, line)
        dispatch_msg(line)

        if auth != nil and not is_simple_msg do
          message_extra(:send_msg, line, auth, chan, state)
        end

      [_ | _] = lines ->
        spawn(fn ->
          if length(lines) > @large_msg_lines do
            db_put(state, :set_add, {:big_msgs, chan}, self())

            ExIRC.Client.msg(
              state.client,
              :notice,
              chan,
              "Big message received, printing slowly for esper lag prevention:"
            )
          end

          Enum.reduce(lines, 1, fn line, acc ->
            ExIRC.Client.msg(state.client, :privmsg, chan, line)
            dispatch_msg(line)

            if auth != nil and not is_simple_msg do
              message_extra(:send_msg, line, auth, chan, state)
            end

            receive do
              :kill -> Process.exit(self(), :normal)
            after
              acc * 110 -> nil
            end

            (acc > 10 && 10) || acc + 1
          end)

          if length(lines) > @large_msg_lines do
            ExIRC.Client.msg(state.client, :notice, chan, "Big message complete")
            db_put(state, :set_remove, {:big_msgs, chan}, self())
          end
        end)

        # {sending, delayed} ->
        # count =
        #  Enum.reduce(sending, 0, fn irc_msg, count ->
        #    # ExIRC.Client.nick(state.client, "#{nick}{Discord}")
        #    ExIRC.Client.msg(state.client, :privmsg, chan, irc_msg)
        #    # ExIRC.Client.nick(state.client, state.nick)
        #    dispatch_msg(irc_msg)
        #    Process.sleep(count * 10)
        #    count + 1
        #  end)

        # {current, total} =
        #  add_delayed_messages(state, chan, delayed, Timex.shift(Timex.now(), minutes: 5))

        # if delayed != [] do
        #  ExIRC.Client.msg(
        #    state.client,
        #    :privmsg,
        #    chan,
        #    "Run `?more` within 5m to get #{current}/#{total} more messages (anti-flood protection, don't run this too rapidly or esper will eat messages)"
        #  )
        # end

        # count
    end

    # Process.sleep(count * 10)

    # if auth != nil and not is_simple_msg do
    #  message_extra(:send_msg, msg, auth, "#gt-dev", state)
    # end

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
            case Overdiscord.SiteParser.get_summary("https://www.youtube.com/c/aBear989/live") do
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
                      #  "> If Bear989 is streaming then see it at: https://www.youtube.com/c/aBear989/live"
                      # )

                      [simple_summary | _] = String.split(summary, " - YouTube Gaming :")
                      IO.inspect(simple_summary, label: "BearUpdate")
                      # send_msg_both(simple_summary, "#gt-dev", state, discord: false)
                      send_msg_both(
                        "Bear989 is now playing/streaming at https://www.youtube.com/c/aBear989/live #{
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

  def handle_cast(:poll_feeds, state) do
    import Meeseeks.CSS

    # db_put(state, :kv, :feed_links, [
    #  "https://xkcd.com/rss.xml",
    #  "https://factorio.com/blog/rss"
    # ])
    db_get(state, :kv, :feed_links)
    |> List.wrap()
    |> IO.inspect(label: :AllFeeds)
    |> Enum.each(fn meta_url ->
      {url, category} =
        case String.split(meta_url, " ", parts: 2) do
          [url] -> {url, nil}
          [url, category] -> {String.trim(url), String.trim(category)}
        end

      Logger.info("Fetching feed at:  #{meta_url}")

      case HTTPoison.get(url) do
        {:error, reason} ->
          Logger.error("Feed Fetch Failure at `#{url}`:  #{inspect(reason)}")

        {:ok, %{status_code: status_code}} when status_code != 200 ->
          Logger.error("Feed Invalid Status Code at `#{url}`: #{inspect(status_code)}")

        {:ok, %{status_code: 200, body: body}} ->
          Logger.info("Feed Fetch Success at `#{url}`")
          doc = Meeseeks.parse(body, :xml)

          cond do
            # Atom
            feed = Meeseeks.one(doc, css("feed")) ->
              title =
                try do
                  with(
                    entry when entry != nil <- Meeseeks.one(feed, css("entry")),
                    true <-
                      if category == nil do
                        true
                      else
                        atom_category =
                          Meeseeks.attr(Meeseeks.one(entry, css("category")), "term")

                        Logger.info("Feed Category Found: #{atom_category}")
                        category == atom_category
                      end,
                    title when title != nil <- Meeseeks.one(entry, css("title")),
                    nil <- Meeseeks.text(Meeseeks.one(title, css("[type=\"text\"]"))),
                    nil <-
                      case Meeseeks.one(title, css("[type=\"html\"]")) do
                        nil ->
                          nil

                        title ->
                          title
                          |> Meeseeks.text()
                          |> Meeseeks.parse()
                          |> Meeseeks.one(css("*"))
                          |> Meeseeks.text()
                      end,
                    nil <- Meeseeks.text(title),
                    do: nil
                  )
                rescue
                  e -> IO.puts(Exception.format(:error, e, __STACKTRACE__))
                catch
                  e -> IO.puts(Exception.format(:error, e, __STACKTRACE__))
                end

              data = %{
                link: Meeseeks.attr(Meeseeks.one(feed, css("feed > entry > link[href]")), "href"),
                title: title
              }

              Logger.info("Atom Feed Data: #{inspect(data)}")

              if data.link && data.title do
                data
              else
                nil
              end

            # RSS
            Meeseeks.one(doc, css("rss")) ->
              {_sort, item} =
                doc
                |> Meeseeks.all(css("channel item"))
                |> Enum.map(fn item ->
                  case Meeseeks.one(item, css("pubDate")) do
                    nil ->
                      {0, item}

                    date ->
                      date = Meeseeks.text(date)

                      case Timex.parse(date, "{RFC1123}") do
                        {:ok, date} -> {-Timex.to_unix(date), item}
                        _ -> {0, item}
                      end
                  end
                end)
                |> Enum.sort()
                |> List.first()

              data =
                if item do
                  %{
                    link: Meeseeks.text(Meeseeks.one(item, css("link"))),
                    title: Meeseeks.text(Meeseeks.one(item, css("title")))
                  }
                else
                  %{link: nil, title: nil}
                end

              Logger.info("RSS Feed Data: #{inspect(data)}")

              if data.link && data.title do
                data
              else
                nil
              end

            :else ->
              Logger.error("Unknown Feed Type at `#{url}`: #{String.slice(body, 0..100)}")
              nil
          end
          |> case do
            nil ->
              Logger.info("Feed failed to acquire useful data")
              nil

            data ->
              case db_get(state, :kv, {:feed_link, meta_url}) do
                # No change
                ^data ->
                  Logger.info("Feed data unchanged from database")
                  nil

                old_data ->
                  Logger.info(
                    "Feed data changed:\n\tOld: #{inspect(old_data)}\n\tNew: #{inspect(data)}"
                  )

                  db_put(state, :kv, {:feed_link, meta_url}, data)
              end
          end
      end
    end)

    send_feeds(state)

    {:noreply, state, :hibernate}
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
    send_msg_both("_#{state.nick} has joined IRC_", chan, state.client, irc: false)
    ExIRC.Client.who(state.client, "#gt-dev")
    {:noreply, state}
  end

  def handle_info({:received, msg, %{nick: nick, user: user} = auth, "#gt-dev" = chan}, state) do
    db_user_messaged(state, auth, msg)

    case msg do
      "!" <> _ ->
        :ok

      omsg ->
        spawn(fn -> Overdiscord.EventPipe.inject({chan, auth, msg, state}, %{msg: msg}) end)
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
        spawn(fn -> Overdiscord.EventPipe.inject({chan, auth, msg, state}, %{msg: msg}) end)
        message_extra(:msg, msg, auth, chan, state)
    end

    {:noreply, state}
  end

  def handle_info({:received, msg, %{nick: nick, user: _user} = auth}, state) do
    case msg do
      "!" <> _ ->
        :ok

      msg ->
        IO.inspect("BLAH!")
        spawn(fn -> Overdiscord.EventPipe.inject({nick, auth, msg, state}, %{msg: msg}) end)
        message_extra(:msg, msg, auth, nick, state)
    end

    {:noreply, state}
  end

  def handle_info({:me, action, %{nick: nick, user: user} = auth, "#gt-dev" = chan}, state) do
    db_user_messaged(state, auth, action)
    if(user === "~Gregorius", do: handle_greg(action, state.client))

    spawn(fn ->
      Overdiscord.EventPipe.inject({chan, auth, nick <> " " <> action, state}, %{
        action: action,
        msg: "_#{action}_"
      })
    end)

    action = convert_message_to_discord(action)
    IO.inspect("Sending emote From IRC to Discord: **#{nick}** #{action}", label: "State")
    # Alchemy.Client.send_message("320192373437104130", "_**#{nick}** #{action}_")
    dispatch_msg("_#{action}_")
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
            check_greg_xkcd(%{state | meta: put_in(state.meta, [:whos, channel], whosm)})
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
    send_feeds(state)
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
    send_feeds(state)
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

  def transform_earmark_ast_to_markdown(ast)

  def transform_earmark_ast_to_markdown(list) when is_list(list) do
    list
    |> Enum.map(&transform_earmark_ast_to_markdown/1)
    |> Enum.join("")
  end

  def transform_earmark_ast_to_markdown(string) when is_binary(string) do
    # TODO:  Escape markdown 'things'
    transform_string_to_discord(string)
  end

  def transform_earmark_ast_to_markdown({"a", attrs, body}) do
    IO.inspect({attrs, body}, label: :a)
    first = List.first(body)
    body = transform_earmark_ast_to_markdown(body)

    case :proplists.get_value("href", attrs) do
      nil -> body
      "" -> body
      ^first -> " " <> first
      ^body -> " " <> body
      href -> " [#{body}](#{href})"
    end
  end

  def transform_earmark_ast_to_markdown({"blockquote", _, body}) do
    body = transform_earmark_ast_to_markdown(body)
    body = String.trim_trailing(body, "\n")
    "> " <> String.replace(body, "\n", "\n> ")
  end

  def transform_earmark_ast_to_markdown({"strong", _, body}) do
    "**" <> transform_earmark_ast_to_markdown(body) <> "**"
  end

  def transform_earmark_ast_to_markdown({"del", _, body}) do
    "~~" <> transform_earmark_ast_to_markdown(body) <> "~~"
  end

  def transform_earmark_ast_to_markdown({"em", _, body}) do
    "_" <> transform_earmark_ast_to_markdown(body) <> "_"
  end

  def transform_earmark_ast_to_markdown({"hr", _, []}) do
    "\n---\n"
  end

  def transform_earmark_ast_to_markdown({"pre", _, [{"code", _, body}]}) do
    body = transform_earmark_ast_to_markdown(body) |> String.trim()
    "    " <> String.replace(body, "\n", "\n    ")
  end

  def transform_earmark_ast_to_markdown({"pre", _, body}) do
    body = transform_earmark_ast_to_markdown(body) |> String.trim()
    "    " <> String.replace(body, "\n", "\n    ")
  end

  def transform_earmark_ast_to_markdown({"code", _, body}) do
    body = transform_earmark_ast_to_markdown(body)
    count = Enum.count(String.graphemes(body), &(&1 == "`"))
    delim = String.duplicate("`", div(count, 2))
    delim <> body <> delim
  end

  def transform_earmark_ast_to_markdown({"p", _, elems}) do
    transform_earmark_ast_to_markdown(elems) <> "\n"
  end

  def transform_earmark_ast_to_markdown({"ol", opts, branches}) do
    start = :proplists.get_value("start", opts, "1") |> String.to_integer()

    branches
    |> Enum.with_index(start)
    |> Enum.map(fn {branch, idx} ->
      idx = "#{idx}. "
      prefix = String.duplicate(" ", String.length(idx))

      body =
        branch
        |> transform_earmark_ast_to_markdown()
        |> String.trim()
        |> String.replace("\n", "\n#{prefix}")

      idx <> body
    end)
    |> Enum.join("\n")
  end

  def transform_earmark_ast_to_markdown({"ul", [], branches}) do
    branches
    |> Enum.map(&transform_earmark_ast_to_markdown/1)
    |> Enum.map(&["* " | &1])
    |> Enum.join("\n")
  end

  def transform_earmark_ast_to_markdown({"li", [], body}) do
    transform_earmark_ast_to_markdown(body)
  end

  def transform_earmark_ast_to_markdown(unhandled) do
    Logger.error("Unhandled Earmark AST Type: #{inspect(unhandled)}")
    "{unhandled-markdown:<@240159434859479041>:#{inspect(unhandled)}}"
  end

  def convert_message_to_discord(msg) do
    case Earmark.as_ast(msg) do
      {:ok, ast, deprecation_messages} ->
        if deprecation_messages != [] do
          Logger.warn(
            "Earmark Deprecation Messages: #{inspect(deprecation_messages)}\n#{inspect(ast)}"
          )
        end

        # IO.inspect(ast, label: :AST)
        transform_earmark_ast_to_markdown(ast)

      {:error, ast, error_messages} ->
        if error_messages != [] do
          Logger.warn("Earmark Error Messages: #{inspect(error_messages)}\n#{inspect(ast)}")
        end

        # IO.inspect(ast, label: :AST)
        transform_earmark_ast_to_markdown(ast)
    end

    # |> IO.inspect(label: :DOC)
  catch
    _ -> msg
  end

  def transform_string_to_discord(msg) do
    # TODO:  Escape markdown 'things'
    msg =
      Regex.replace(~R/([^<]|^)\B@!?([a-zA-Z0-9]+)\b/i, msg, fn full, pre, username ->
        down_username = String.downcase(username)

        try do
          cond do
            down_username in ["everyone"] ->
              "@ everyone"

            down_username in ["all"] ->
              "@ all"

            down_username in ["here"] ->
              "@ here"

            :else ->
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

    msg =
      msg
      |> String.replace(~R/@here\b/i, "@ here")
      |> String.replace(~R/@everyone\b/i, "@ everyone")
      |> String.replace(~R/@?\bbear989\b|@?\bbear989sr\b|@?\bbear\b/i, "<@225728625238999050>")
      |> String.replace(
        ~R/@?\bqwertygiy\b|@?\bqwerty\b|@?\bqwertys\b|@?\bqwertz\b|@?\bqwertzs\b/i,
        "<@80832726017511424>"
      )
      |> String.replace(~R/@?\bSuperCoder79\b|@?\bsc79\b/i, "<@222338097604460545>")
      |> String.replace(~R/@?\bandyafw\b|@?\bandy\b|@?\banna\b/i, "<@179586256752214016>")
      |> String.replace(~R/@?\bcrazyj1984\b|@?\bcrazyj\b/i, "<@225742972145238018>")
      |> String.replace(~R/@?\bSpeiger\b/i, "<@90867844530573312>")
      |> String.replace(~R/@?\bmitchej\b/i, "<@287804310509584387>")
      |> String.replace(~R/@?\bnetmc\b/i, "<@185586090416013312>")
      |> String.replace(~R/@?\be99+\b/i, "<@349598994193711124>")
      |> String.replace(~R/@?\bdbp\b|@?\bdpb\b/i, "<@138742528051642369>")
      |> String.replace(~R/@?\baxlegear\b/i, "<@226165192814362634>")
      |> String.replace(~R/@?\bbart\b/i, "<@258399730302844928>")
      |> String.replace(~R/@?\byuesha\b/i, "<@712305158352273418>")
      |> String.replace(~R/@?\boverminddl1\b|@?\bovermind\b/i, "<@240159434859479041>")
      |> String.replace(~R/@?\bxarses\b/i, "<@290667609920372737>")
      |> String.replace(~R/@?\btrinsdar\b/i, "<@313675165261103105>")
      |> String.replace(~R/@?\braven\b|@?\beigenraven\b/i, "<@148428133551439872>")
      |> to_string()

    msg =
      Regex.replace(~R/:([a-zA-Z0-9_-]+):/, msg, fn full, emoji_name ->
        case Alchemy.Cache.search(:emojis, &(&1.name == emoji_name)) do
          [result | _] ->
            to_string(result)

          [] ->
            with(
              {:error, _} <- Alchemy.Cache.guild(alchemy_guild()),
              do: Alchemy.Client.get_guild(alchemy_guild())
            )
            |> case do
              {:ok, %{emojis: emojis}} ->
                case Enum.filter(emojis, &(&1.name == emoji_name)) do
                  [] -> full
                  [result | _] -> to_string(result)
                end

              unknown_response ->
                Logger.error(
                  "Unhandled guild response in `convert_message_to_discord`: #{
                    inspect(unknown_response)
                  }"
                )
            end
        end
      end)

    msg
  end

  #def alchemy_channel(), do: "320192373437104130"
  #def alchemy_guild(), do: "225742287991341057"
  def alchemy_channel(), do: "1213612141429653566"
  def alchemy_guild(), do: "1213386848299122740"

  def alchemy_webhook_url(),
    do:
      unquote(
        System.get_env("OVERDISCORD_WEBHOOK_BEARIRC") ||
          throw("Set `OVERDISCORD_WEBHOOK_BEARIRC`")
      )

  def alchemy_webhook do
    unquote(
      case System.get_env("OVERDISCORD_WEBHOOK_BEARIRC") do
        nil ->
          throw("Set `OVERDISCORD_WEEBHOOK_BEARIRC`")

        #"https://discordapp.com/api/webhooks/" <> data ->
        "https://discord.com/api/webhooks/" <> data ->
          [wh_id, wh_token] = String.split(data, "/", parts: 2)
          Macro.escape(%Alchemy.Webhook{id: wh_id, token: wh_token})
      end
    )
  end

  def send_msg_both(msgs, chan, client, opts \\ [])

  def send_msg_both(msgs, chan, %{client: client}, opts) do
    send_msg_both(msgs, chan, client, opts)
  end

  def send_msg_both(msgs, chan, client, opts) do
    prefix = opts[:prefix] || "> "

    opts = if(client == nil, do: [{:irc, false} | opts], else: opts)

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

      case opts[:name] do
        nil ->
          Alchemy.Client.send_message(alchemy_channel(), amsg)

        name when is_binary(name) ->
          Alchemy.Webhook.send(alchemy_webhook(), {:content, amsg}, username: name)
          |> IO.inspect(label: :WebhookSendResult)
      end
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
      "more" => fn _cmd, _args, _auth, chan, state ->
        case get_delayed_messages(state, chan) do
          {[], 0} ->
            "No delayed messages"

          {msgs, 0} ->
            msgs

          {msgs, remaining} ->
            [
              msgs,
              "Run `?more` to get #{remaining} more messages (anti-flood protection, don't run this too rapidly or esper will eat messages)"
            ]
        end
      end,
      "stop" => fn _cmd, _args, auth, _chan, state ->
        if not is_admin(auth) do
          "You do not have access to the `stop` command"
        else
          case db_get(state, :set, {:big_msgs, chan}) do
            [] ->
              "No message streams to stop"

            streams when is_list(streams) ->
              Enum.each(streams, fn stream ->
                send(stream, :kill)
                Process.exit(stream, :kill)
                db_put(state, :set_remove, {:big_msgs, chan}, stream)
              end)

              "Stopped #{length(streams)} stream(s)"
          end
        end
      end,
      "changelog" => fn _cmd, args, _auth, chan, state ->
        case args do
          "link" ->
            "https://gregtech.overminddl1.com/com/gregoriust/gregtech/gregtech_1.7.10/changelog.txt"

          _ ->
            IO.inspect(args)

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
      "emojis" => fn _cmd, _args, _auth, _chan, _state ->
        guild =
          with(
            {:error, _} <- Alchemy.Cache.guild(alchemy_guild()),
            do: Alchemy.Client.get_guild(alchemy_guild())
          )

        guild_emojis =
          case guild do
            {:ok, guild} -> Enum.map(guild.emojis, &":#{&1.name}:")
            _ -> ["Discord not responding"]
          end

        [
          "Guild Emojis: #{Enum.join(guild_emojis, ", ")}"
        ]
      end,
      "discordavatar" => fn _cmd, args, auth, _chan, state ->
        is_admin = is_admin(auth)

        case String.split(args, " ", parts: 3) do
          [""] ->
            "?discordavatar (get)|(set <url>) -> Set URL to 'nil' to clear"

          ["get"] ->
            case db_get(state, :kv, {:discord_avatar, auth.nick}) do
              nil -> "No avatar URL override set"
              url -> "Override URL: #{url}"
            end

          ["get", nickname] ->
            case db_get(state, :kv, {:discord_avatar, nickname}) do
              nil -> "No avatar URL override set"
              url -> "Override URL: #{url}"
            end

          ["set"] ->
            {:set, nil, auth.nick}

          ["set", "nil"] ->
            {:set, nil, auth.nick}

          ["set", url] ->
            {:set, url, auth.nick}

          ["set", nickname, "nil"] when is_admin ->
            {:set, nil, nickname}

          ["set", nickname, url] when is_admin ->
            {:set, url, nickname}

          _ ->
            "Invalid entry"
        end
        |> case do
          msg when is_binary(msg) ->
            msg

          {:set, nil, nickname} ->
            db_delete(state, :kv, {:discord_avatar, nickname})
            "Deleted override URL"

          {:set, url, nickname} ->
            case URI.parse(url) do
              %URI{scheme: scheme, host: host, path: path} = uri
              when scheme in ["http", "https"] and is_binary(host) and is_binary(path) ->
                uri = URI.to_string(uri)
                db_put(state, :kv, {:discord_avatar, nickname}, uri)
                "Set override avatar URL to: #{uri}"

              _ ->
                "Invalid URL"
            end
        end
      end,
      "presence" => fn _cmd, args, _auth, _chan, _state ->
        name = String.trim(args)

        case Alchemy.Cache.search(:members, &(&1.user.username == name)) do
          [] ->
            "`#{name}`` is not found in Discord cache"

          [%{user: %{id: uid}}] ->
            case Alchemy.Cache.presence(alchemy_guild(), uid) do
              {:ok, %{game: game, status: status}} ->
                "`#{name}` is in `#{game}` with status `#{status}`"

              {:error, reason} when is_binary(reason) ->
                "Failed to get presence for `#{name}` because: #{reason}"
            end

          _ ->
            "Multiple `#{name}` were found?"
        end
      end,
      "feeds" => fn _cmd, args, auth, _chan, _state ->
        case args do
          "" ->
            is_admin = is_admin(auth)

            [
              "?feeds -> Shows this help screen",
              "?feeds list -> Lists Feed URLs",
              is_admin && "?feeds add [type] <url> -> Adds a new Feed url to track",
              is_admin && "?feeds remove <url> -> Removes a Feed url from tracking",
              "?feeds ping <subcmd> -> Manages pings for feed subscription auto-popups, run just `?feeds ping` for help",
              "?feeds <urlpart> -> Searches for the first URL that matches the selection and shows it"
            ]
            |> Enum.filter(& &1)
            |> Enum.join("\n")

          "list" ->
            feeds =
              db_get(state, :kv, :feed_links)
              |> List.wrap()
              |> Enum.map(&to_string/1)
              |> Enum.join("\n\t")

            "Feeds:\n\t" <> feeds

          "add " <> url ->
            url = String.trim(url)

            {type, url} =
              case String.split(url, " ", parts: 2, trim: true) do
                [url] -> {:rss_atom, url}
                ["rss", url] -> {:rss_atom, url}
                ["atom", url] -> {:rss_atom, url}
                [type, url] -> {type, url}
              end

            uri = URI.parse(url)
            url = URI.to_string(uri)
            urls = List.wrap(db_get(state, :kv, :feed_links))

            cond do
              not is_admin(auth) ->
                "Missing required access permissions"

              type not in [:rss_atom] ->
                "Invalid type: `#{type}`"

              not is_binary(uri.host) and is_binary(uri.path) and uri.scheme in ["http", "https"] ->
                "Not a valid URL for tracking"

              Enum.member?(urls, url) ->
                "Already exists as a feed URL: #{url}"

              true ->
                db_put(state, :kv, :feed_links, Enum.sort([url | urls]))

                "Added `#{url}` feed"
            end

          "remove " <> url ->
            url = String.trim(url)
            url = URI.to_string(URI.parse(url))
            urls = db_get(state, :kv, :feed_links)

            cond do
              not is_admin(auth) ->
                "Missing required access permissions"

              true ->
                case Enum.filter(urls, &(&1 != url)) do
                  [] ->
                    "No feeds to remove"

                  new_urls when length(new_urls) == length(urls) ->
                    [{_closeness, found} | _] =
                      urls
                      |> Enum.map(&{-String.jaro_distance(&1, url), &1})
                      |> Enum.sort()

                    "No exact matching URL's found for `#{url}`, maybe you meant: #{found}"

                  new_urls ->
                    db_put(state, :kv, :feed_links, Enum.sort(new_urls))
                    "Removed: #{Enum.join(urls -- new_urls, ",")}"
                end
            end

          "ping" ->
            "Subcommands:\n  add <nick> {feedmatches} -> feedmatch can be left out to subscribe to all\n  delete <nick> {feedmatches}\n  <nick> -> List pings for nick"

          "ping add " <> args ->
            is_admin(auth) || throw({:NOT_ALLOWED, "`#{auth.nick}` is not an admin"})
            [nick | searches] = args |> String.split() |> Enum.map(&String.trim/1)
            searches = (searches == [] && [""]) || searches
            pings = List.wrap(db_get(state, :kv, :feed_pings))

            pings
            |> Enum.filter(
              &(elem(&1, 0) == nick and (Enum.member?(searches, elem(&1, 1)) or elem(&1, 1) == ""))
            )
            |> case do
              [] ->
                {"", searches}

              already ->
                already = already |> Enum.map(&elem(&1, 1))

                msg =
                  "FeedMatch's already exists for `#{nick}`: \"" <>
                    Enum.join(already, "\", \"") <> "\"\n"

                searches =
                  Enum.reject(searches, &(Enum.member?(already, &1) or Enum.member?(already, "")))

                {msg, searches}
            end
            |> case do
              {msg, []} ->
                msg

              {msg, [""]} ->
                pings = Enum.reject(pings, &(elem(&1, 0) == nick))
                pings = [{nick, ""} | pings]
                db_put(state, :kv, :feed_pings, Enum.sort(pings))
                msg <> "Added FeedMatches for `#{nick}`: \"\""

              {msg, searches} ->
                pings = Enum.map(searches, &{nick, &1}) ++ pings

                db_put(state, :kv, :feed_pings, Enum.sort(pings))

                msg <>
                  "Added FeedMatches for `#{nick}`: \"" <> Enum.join(searches, "\", \"") <> "\""
            end

          "ping delete " <> args ->
            is_admin(auth) || throw({:NOT_ALLOWED, "`#{auth.nick}` is not an admin"})
            [nick | searches] = args |> String.split() |> Enum.map(&String.trim/1)
            pings = List.wrap(db_get(state, :kv, :feed_pings))

            case Enum.split_with(
                   pings,
                   &(elem(&1, 0) == nick and
                       (elem(&1, 1) == "" or Enum.member?(searches, elem(&1, 1))))
                 ) do
              {[], _pings} ->
                "No matching feedspecs for `#{nick}` to remove"

              {removed, pings} ->
                db_put(state, :kv, :feed_pings, pings)

                "Removed FeedMatches for `#{nick}`: \"" <>
                  Enum.join(Enum.map(removed, &elem(&1, 1)), "\", \"") <> "\""
            end

          "ping " <> nick ->
            nick = String.trim(nick)

            db_get(state, :kv, :feed_pings)
            |> IO.inspect()
            |> List.wrap()
            |> Enum.filter(&(elem(&1, 0) == nick))
            |> case do
              [] ->
                "No matches found for `#{nick}`"

              matches ->
                "Found matches for `#{nick}`: \"" <>
                  (matches |> Enum.map(&elem(&1, 1)) |> Enum.join("\", \"")) <> "\""
            end

          search ->
            with(
              urls <- db_get(state, :kv, :feed_links),
              url when is_binary(url) <- Enum.find(urls, &String.contains?(&1, search)),
              %{link: link, title: title} <- db_get(state, :kv, {:feed_link, url}),
              do: "#{link} #{title}",
              else: (_ -> "No matching feed for: #{search}")
            )
        end
      end,
      "xkcd" => fn _cmd, args, _auth, _chan, _state ->
        case Integer.parse(String.trim(args)) do
          {id, ""} ->
            "https://xkcd.com/#{id}"

          _ ->
            with(
              urls <- db_get(state, :kv, :feed_links),
              url when is_binary(url) <- Enum.find(urls, &String.contains?(&1, "xkcd")),
              %{link: link, title: title} <- db_get(state, :kv, {:feed_link, url}),
              do: "#{link} #{title}",
              else: (_ -> "XKCD Feed not found")
            )
        end
      end,
      "fff" => fn _cmd, args, _auth, _chan, _state ->
        case Integer.parse(String.trim(args)) do
          {id, ""} ->
            "https://factorio.com/blog/post/fff-#{id}"

          _ ->
            with(
              urls <- db_get(state, :kv, :feed_links),
              url when is_binary(url) <- Enum.find(urls, &String.contains?(&1, "factorio")),
              %{link: link, title: title} <- db_get(state, :kv, {:feed_link, url}),
              do: "#{link} #{title}",
              else: (_ -> "Factorio Feed not found")
            )
        end
      end,
      "yt" => fn _cmd, args, _auth, chan, state ->
        case String.trim(args) do
          "" ->
            "Example:  ?yt someYtID <anything-after-is-ignore>"

          id ->
            [id | _rest] = String.split(id, " ", parts: 2)

            if Regex.match?(~R/[a-zA-Z0-9_-]{11}/, id) do
              url = "https://www.youtube.com/watch?v=#{id}"

              case IO.inspect(Overdiscord.SiteParser.get_summary_cached(url), label: :UrlSummary) do
                nil ->
                  "Not an active YouTube ID"

                summary ->
                  send_msg_both(url, chan, state.client)
                  send_msg_both(summary, chan, state.client, discord: false)
              end
            else
              "Not a valid YouTube ID"
            end
        end
      end,
      "google" => fn _cmd, args, _auth, _chan, _state ->
        "https://lmgtfy.com/?q=#{URI.encode(args)}"
      end,
      "wiki" => fn _cmd, args, _auth, chan, state ->
        url = IO.inspect("https://en.wikipedia.org/wiki/#{URI.encode(args)}", label: "Lookup")
        message_cmd_url_with_summary(url, chan, state.client)
        url
      end,
      "ftbwiki" => fn _cmd, args, _auth, chan, state ->
        url = IO.inspect("https://ftb.gamepedia.com/#{URI.encode(args)}", label: "Lookup")
        message_cmd_url_with_summary(url, chan, state.client)
        url
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

              [%{user: %{id: id}} | _] ->
                case Alchemy.Cache.presence(alchemy_guild(), id) do
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

          [_ | _] = msgs ->
            msgs = List.flatten(msgs)

            Enum.map(msgs, fn msg ->
              send_msg_both(msg, chan, state.client)
              Process.sleep(100)
            end)
        end
    end
  rescue
    exc ->
      IO.puts("COMMAND_EXCEPTION" <> Exception.format(:error, exc, __STACKTRACE__))

      send_msg_both(
        "Exception in command execution, report this to OvermindDL1",
        chan,
        state.client
      )
  catch
    {:NOT_ALLOWED, reason} ->
      send_msg_both("Not allowed to perform that command: #{reason}", chan, state.client)

    e ->
      IO.inspect(e, label: :COMMAND_CRASH)
      send_msg_both("Crash in command execution, report this to OvermindDL1", chan, state.client)
  end

  def message_cmd_url_with_summary(url, chan, client) do
    # ExIRC.Client.msg(client, :privmsg, chan, url)

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
    expression = String.replace(expression, ";", "\n")
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
    |> IO.inspect(label: :ExtraScan1)
    |> Enum.map(fn url ->
      url = String.trim_trailing(url, ">")

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

  def send_feeds(state) do
    db_get(state, :kv, :feed_links)
    |> List.wrap()
    |> Enum.each(&send_feeds(state, &1))
  end

  def send_feeds(state, url) do
    send_feeds(state, url, db_get(state, :kv, {:feed_link, url}))
  end

  def send_feeds(_state, _url, nil), do: nil

  def send_feeds(state, url, %{link: link, title: title} = acquired_data)
      when is_binary(link) and is_binary(title) do
    case db_get(state, :kv, {:feed_link, :last, url}) do
      # No change
      ^acquired_data ->
        nil

      last_data ->
        Logger.info(
          "Processing Feed data `#{url}` to channels:\n\tOld: #{inspect(last_data)}\n\tNew: #{
            inspect(acquired_data)
          }"
        )

        pings =
          db_get(state, :kv, :feed_pings)
          |> List.wrap()
          |> Enum.filter(
            &(String.contains?(link, elem(&1, 1)) or String.contains?(title, elem(&1, 1)))
          )
          |> case do
            [] ->
              ""

            pings ->
              "(" <> (pings |> Enum.map(&elem(&1, 0)) |> Enum.dedup() |> Enum.join(", ")) <> ")"
          end

        db_put(state, :kv, {:feed_link, :last, url}, acquired_data)

        send_msg_both("Feed#{pings}: #{link} #{title}", "#gt-dev", state.client)
    end
  end

  def send_feeds(_state, url, unknown_data) do
    Logger.error("Unknown feed data in channel processing at `#{url}`: #{inspect(unknown_data)}")
  end

  def split_at_irc_max_length(msg) do
    # TODO: Look into this more, fails on edge cases...
    # IO.inspect(msg, label: :Unicode?)
    # Regex.scan(~R".{1,420}\s\W?"iu, msg, capture: :first)# Actually 425, but safety margin
    # [[msg]]
    Regex.scan(~R".{1,419}\S(\s|$)"iu, msg, capture: :first)
  end

  def split_at_irc_max_length(prefix, msg) do
    msg = prefix <> msg

    Regex.run(~R".{1,419}\S(\s|$)"iu, msg, return: :index, capture: :first)
    |> case do
      [{0, len} | _] when len <= :erlang.size(prefix) -> 419
      [{0, len} | _] -> len
      _ -> 419
    end
    |> case do
      len ->
        case String.split_at(msg, len) do
          {part, ""} -> [part]
          {part, rest} -> [part | split_at_irc_max_length(prefix, rest)]
        end
    end
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

  def add_delayed_messages(state, chan, msgs, expires_at)

  def add_delayed_messages(state, chan, msg, expires_at) when is_binary(msg) do
    add_delayed_messages(state, chan, [msg], expires_at)
  end

  def add_delayed_messages(state, chan, msgs, %DateTime{} = expires_at)
      when is_list(msgs) and is_binary(chan) do
    old_msgs =
      (db_get(state, :kv, {:delayed_messages, chan}) || [])
      |> prune_delayed_messages()

    msgs =
      msgs
      |> Enum.with_index()
      |> Enum.map(&{Timex.shift(expires_at, microseconds: elem(&1, 1)), elem(&1, 0)})

    new_msgs = Enum.sort(old_msgs ++ msgs, &(Timex.compare(&1, &2) > 0))
    # IO.inspect(new_msgs, label: DelayedMessages)
    db_put(state, :kv, {:delayed_messages, chan}, new_msgs)
    {length(msgs), length(new_msgs)}
  end

  defp prune_delayed_messages(msgs, now \\ Timex.now()) do
    Enum.filter(msgs, &(Timex.compare(elem(&1, 0), now) > 0))
  end

  defp get_delayed_messages(state, chan, count \\ 10, now \\ Timex.now()) do
    (db_get(state, :kv, {:delayed_messages, chan}) || [])
    |> prune_delayed_messages(now)
    |> Enum.split(count)
    |> case do
      {[], []} ->
        {[], 0}

      {return, rest} ->
        db_put(state, :kv, {:delayed_messages, chan}, rest)
        {Enum.map(return, &elem(&1, 1)), length(rest)}
    end
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

  defp get_name_color(_state, "") do
    ""
  end

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
  def irc_unping(""), do: ""

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
