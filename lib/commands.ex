defmodule Overdiscord.Commands do
  require Logger

  use Alchemy.Events

  alias Overdiscord.Storage

  @db :discord_commands

  @max_msg_size 1900

  def string_hard_split(msg, size \\ @max_msg_size, acc \\ [])

  def string_hard_split("", _size, acc) do
    :lists.reverse(acc)
  end

  def string_hard_split(msg, size, acc) when byte_size(msg) > size do
    {first, last} = String.split_at(msg, size)
    string_hard_split(last, size, [first | acc])
  end

  def string_hard_split(msg, size, acc) do
    string_hard_split("", size, [msg | acc])
  end

  def recombine_strings(msgs, combiner, size \\ @max_msg_size, acc \\ [])

  def recombine_strings([], _combiner, _size, acc) do
    :lists.reverse(acc)
  end

  def recombine_strings([msg | rest], combiner, size, []) do
    recombine_strings(rest, combiner, size, [msg])
  end

  def recombine_strings([msg | rest], combiner, size, [acc_first | _acc_rest] = acc)
      when byte_size(acc_first) + byte_size(msg) + byte_size(combiner) > size do
    recombine_strings(rest, combiner, size, [msg | acc])
  end

  def recombine_strings([msg | rest], combiner, size, [acc_first | acc_rest]) do
    recombine_strings(rest, combiner, size, [acc_first <> combiner <> msg | acc_rest])
  end

  def send_event(auth, event_data, to)

  def send_event(auth, %{msg_discord: msg}, to) do
    case msg do
      %Alchemy.Embed{} = embed ->
        Alchemy.Client.send_message(to, "", embed: embed, tts: false)

      {msg, %Alchemy.Embed{} = embed} when is_binary(msg) ->
        Alchemy.Client.send_message(to, msg, embed: embed, tts: false)

      msg when is_binary(msg) ->
        Alchemy.Client.send_message(to, "**#{auth.nickname}:** #{msg}")
    end
  end

  def send_event(auth, %{msg: msg}, to) do
    msg = Overdiscord.IRC.Bridge.convert_message_to_discord(msg)
    # Using byte_size because discord may not operate on graphemes, just being careful...

    msgs =
      if byte_size(msg) > @max_msg_size do
        fixed_msg =
          msg
          # Split into lines that are easy to break on first
          |> String.split("\n")
          # Then split individual lines that are too long
          |> Enum.flat_map(fn msg ->
            if byte_size(msg) > @max_msg_size do
              msg
              |> String.split(msg, " ")
              # Hard split anywhere now
              |> Enum.flat_map(fn msg ->
                string_hard_split(msg)
              end)
            else
              [msg]
            end
            |> recombine_strings(" ")
          end)
          |> recombine_strings("\n")

        fixed_msg
      else
        [msg]
      end

    Logger.warn(inspect({:done, msgs}))

    # Alchemy.Client.send_message(to, "#{auth.location}|#{auth.nickname}: #{msg}")
    if to == "320192373437104130" do
      wh = Overdiscord.IRC.Bridge.alchemy_webhook()
      username = auth.nickname
      down_username = String.downcase(username)

      try do
        Alchemy.Cache.search(:members, fn
          %{user: %{username: ^username}} ->
            true

          %{user: %{username: discord_username}} ->
            down_username == String.downcase(discord_username)

          _ ->
            false
        end)
      rescue
        _ -> []
      catch
        _ -> []
      end
      |> case do
        [%{user: %{id: id, avatar: avatar}}] when avatar not in [nil, ""] ->
          avatar_url = "https://cdn.discordapp.com/avatars/#{id}/#{avatar}.jpg?size=128"

          Enum.each(msgs, fn msg ->
            Alchemy.Webhook.send(wh, {:content, msg}, username: username, avatar_url: avatar_url)
            |> IO.inspect(label: DiscordWebhookSendResult0)

            Process.sleep(250)
          end)

        _ ->
          case username do
            # "GregoriusTechneticies" ->
            #  aurl =
            #    "https://forum.gregtech.overminddl1.com/user_avatar/forum.gregtech.overminddl1.com/gregorius/120/29_2.png"
            #  Alchemy.Webhook.send(wh, {:content, msg}, username: username, avatar_url: aurl)

            _ ->
              db = Overdiscord.IRC.Bridge.get_db()

              case Overdiscord.IRC.Bridge.db_get(db, :kv, {:discord_avatar, username}) do
                nil ->
                  Enum.each(msgs, fn msg ->
                    Alchemy.Webhook.send(wh, {:content, msg}, username: username)
                    |> IO.inspect(label: DiscordWebhookSendResult1)

                    Process.sleep(250)
                  end)

                aurl ->
                  Enum.each(msgs, fn msg ->
                    Alchemy.Webhook.send(wh, {:content, msg}, username: username, avatar_url: aurl)
                    |> IO.inspect(label: DiscordWebhookSendResult2)

                    Process.sleep(25)
                  end)
              end
          end
      end
    else
      Enum.each(msgs, fn msg ->
        Alchemy.Client.send_message(to, "**#{auth.nickname}:** #{msg}")
        |> IO.inspect(label: DiscordSendMessageResult0)

        Process.sleep(250)
      end)
    end
  end

  def send_event(auth, event_data, to) do
    IO.inspect({auth, event_data, to}, label: "Unhandled Discord send_event")
    nil
  end

  # This is self, ignore all about self's messages
  def on_msg(%{author: %{id: "336892378759692289"}}) do
    discord_activity(:discord)
    # Ignore self bot message
    :ok
  end

  def on_msg(
        %{
          author: %{bot: _true_or_false, username: username},
          # "320192373437104130",
          channel_id: channel_id,
          content: content
        } = msg
      ) do
    discord_activity(:discord)
    # IO.inspect(msg, label: :DiscordMsg)

    %{id: wh_id} = Overdiscord.IRC.Bridge.alchemy_webhook()
    # TODO:  Definitely need to make a protocol to parse these event_data's out!
    # TODO:  Remove this `!` stuff to manage all messages so it is fully configurable
    # Ignore self webhook
    if not String.starts_with?(content, "!") and content != "" and msg.webhook_id != wh_id do
      Overdiscord.EventPipe.inject(msg, %{msg: get_msg_content_processed(msg)})
      Storage.put(@db, :list_truncated, {:historical_messages, channel_id}, {msg, 10000, 9000})
    end

    # Ignore self webhook
    if channel_id == "320192373437104130" and msg.webhook_id != wh_id do
      case content do
        "!list" ->
          Overdiscord.IRC.Bridge.list_users()

        "!" <> _ ->
          :ok

        content ->
          # IO.inspect("Msg dump: #{inspect msg}")
          IO.inspect("Sending message from Discord to IRC: #{username}: #{content}")
          # irc_content = get_msg_content_processed(msg)
          #        Overdiscord.IRC.Bridge.send_msg(username, irc_content)

          Enum.map(msg.attachments, fn %{
                                         filename: filename,
                                         size: size,
                                         url: url,
                                         proxy_url: _proxy_url
                                       } = attachment ->
            size = Sizeable.filesize(size, spacer: "")
            IO.inspect({filename, size, url}, label: "Sending attachment")
            # Overdiscord.IRC.Bridge.send_msg(username, "#{filename} #{size}: #{url}")
            Overdiscord.EventPipe.inject(msg, %{
              simple_msg: "#{filename}, #{size}: #{url}",
              file: attachment
            })
          end)
      end
    end
  end

  def on_msg(msg) do
    discord_activity(:discord)
    IO.inspect(msg, label: :UnhandledMsg)
  end

  def on_msg_edit(%{author: nil, channel_id: "320192373437104130", embeds: [_ | _] = embeds}) do
    discord_activity(:discord)
    IO.inspect(embeds, label: :BotEdit)

    Enum.map(embeds, fn
      %{title: title, description: description, url: url} when is_binary(url) ->
        IO.inspect("Discord embed bot url back to IRC: #{title} - #{description} - #{url}",
          label: :DiscordBotEdit
        )

      %{title: title, description: description} ->
        IO.inspect(
          "Discord embed bot back to IRC: #{title} - #{description}",
          label: :DiscordBotEdit
        )

        # Overdiscord.IRC.Bridge.send_msg(nil, "#{title} - #{description}")
    end)
  end

  def on_msg_edit(%{author: %{id: "336892378759692289"}} = msg) do
    discord_activity(:discord)
    # We were edited, likely by discord itself, pass that information back?
    IO.inspect(msg, label: :BotEdited)
  end

  def on_msg_edit(
        %{
          author: %{bot: _true_or_false, username: username} = author,
          channel_id: "320192373437104130",
          content: content
        } = msg
      ) do
    discord_activity(:discord)

    case content do
      "!" <> _ -> :ok
      _content -> on_msg(%{msg | author: %{author | username: "#{username}{EDIT}"}})
    end
  end

  def on_msg_edit(msg) do
    discord_activity(:discord)
    IO.inspect(msg, label: :EditedMsg)
  end

  def on_msg_delete(msg_id, chan_id) do
    old_msgs = Storage.get(@db, :list, {:historical_messages, chan_id})

    case Enum.find(old_msgs, fn %{id: id} -> id == msg_id end) do
      nil ->
        Logger.info(
          "Discord deleted old message #{msg_id} from channel #{chan_id} but too old to be in history"
        )

      %{author: %{username: username}} = msg ->
        Logger.info(
          "Discord deleted old message #{msg_id} from channel #{chan_id}: #{inspect(msg)}"
        )

        short_msg =
          msg
          |> get_msg_content_processed()
          |> String.split("\n", parts: 2, trim: true)
          |> List.first()
          |> String.split_at(128)
          |> case do
            {short_msg, ""} -> short_msg
            {short_msg, _} -> short_msg <> "..."
          end

        Overdiscord.EventPipe.inject(msg, %{
          msg: "Discord Deleted Msg from `#{username}`: " <> short_msg
        })
    end
  end

  def on_presence_update(
        %{
          guild_id: "225742287991341057" = guild_id,
          # status: "online",
          game: game,
          user: %{bot: false, id: id}
        } = _presence
      ) do
    discord_activity(:discord)
    # IO.inspect(presence, label: "Presence")

    case Alchemy.Cache.member(guild_id, id) do
      {:ok, %Alchemy.Guild.GuildMember{user: %{username: nick}}} when is_binary(nick) ->
        # IO.inspect({nick, presence}, label: "Presence Update")
        Overdiscord.IRC.Bridge.on_presence_update(nick, game)

      {:ok, _member} ->
        # Ignored Presence
        # IO.inspect(_member, label: "Presence Member Ignored")
        :ok

      _member ->
        # Not a valid member
        # IO.inspect(_member, label: "Presence Invalid Member")
        if id == "225728625238999050" do
          Overdiscord.IRC.Bridge.on_presence_update("Bear989", game)
        end

        :ok
    end
  end

  def on_presence_update(_presence) do
    discord_activity(:discord)
    # Unhandled presence
    # IO.inspect(_presence, label: "Unhandled Presence")
    :ok
  end

  def start_link() do
    GenServer.start_link(__MODULE__, [])
  end

  def init(_) do
    use Overdiscord.Commands.Basic
    use Overdiscord.Commands.GT6
    use Overdiscord.Commands.GD
    Alchemy.Cogs.EventHandler.add_handler({:message_create, {__MODULE__, :on_msg}})
    Alchemy.Cogs.EventHandler.add_handler({:message_update, {__MODULE__, :on_msg_edit}})
    Alchemy.Cogs.EventHandler.add_handler({:message_delete, {__MODULE__, :on_msg_delete}})
    Alchemy.Cogs.EventHandler.add_handler({:presence_update, {__MODULE__, :on_presence_update}})

    spawn(fn ->
      Process.sleep(5000)
      # Load entire userlist, at a rate of 100 per minutes because of discord limits
      Alchemy.Cache.load_guild_members(
        elem(Alchemy.Cache.guild_id(Overdiscord.IRC.Bridge.alchemy_channel()), 1),
        "",
        0
      )
    end)

    {:ok, nil}
  end

  ## Helpers

  @db :discord

  def discord_activity(server_name) do
    db = Storage.get_db(@db)
    now = NaiveDateTime.utc_now()
    Storage.put(db, :kv, :activity, now)
    Storage.put(db, :kv, {:activity, server_name}, now)
  end

  def check_dead() do
    now = NaiveDateTime.utc_now()
    last_activity = Storage.get(@db, :kv, :activity, now)

    if NaiveDateTime.compare(last_activity, NaiveDateTime.add(now, -60 * 60, :second)) == :lt do
      IO.puts("===============================")

      IO.inspect(
        {:DiscordMaybeDead, last_activity, now, NaiveDateTime.add(now, -60 * 60, :seconds)}
      )
    end
  end

  def get_msg_content_processed(%Alchemy.Message{channel_id: channel_id, content: content} = _msg) do
    case Alchemy.Cache.guild_id(channel_id) do
      {:error, _reason} ->
        # IO.inspect("Unable to process guild_id: #{reason}\n\t#{inspect msg}")
        content

      {:ok, guild_id} ->
        content =
          Regex.replace(~R/<@!?([0-9]+)>/, content, fn full, user_id ->
            case Alchemy.Cache.member(guild_id, user_id) do
              {:ok, %Alchemy.Guild.GuildMember{user: %{username: username}}} ->
                "@#{username}"

              v ->
                case Alchemy.Client.get_member(guild_id, user_id) do
                  {:ok, %Alchemy.Guild.GuildMember{user: %{username: username}}} ->
                    "@#{username}"

                  err ->
                    IO.inspect(
                      "Unable to get member of guild: #{inspect(v)}\n\tError: #{inspect(err)}"
                    )

                    full
                end
            end
          end)

        content =
          Regex.replace(~R/<:([a-zA-Z0-9_-]+):([0-9]+)>/, content, fn
            _full, emoji_name, _emoji_id ->
              ":#{emoji_name}:"
          end)

        content
    end
  end
end
