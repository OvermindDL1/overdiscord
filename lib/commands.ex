defmodule Overdiscord.Commands do
  use Alchemy.Events

  alias Overdiscord.Storage

  def send_event(auth, event_data, to)

  def send_event(auth, %{msg: msg}, to) do
    # Alchemy.Client.send_message(to, "#{auth.location}|#{auth.nickname}: #{msg}")
    Alchemy.Client.send_message(to, "**#{auth.nickname}:** #{msg}")
  end

  def send_event(auth, event_data, to) do
    IO.inspect({auth, event_data, to}, label: "Unhandled Discord send_event")
    nil
  end

  def on_msg(%{author: %{id: "336892378759692289"}}) do
    discord_activity(:discord)
    # Ignore bot message
    :ok
  end

  def on_msg(
        %{
          author: %{bot: _true_or_false, username: username},
          channel_id: "320192373437104130",
          content: content
        } = msg
      ) do
    discord_activity(:discord)
    # TODO:  Definitely need to make a protocol to parse these event_data's out!
    # TODO:  Remove this `!` stuff to manage all messages so it is fully configurable
    if not String.starts_with?(content, "!"),
      do: Overdiscord.EventPipe.inject(msg, %{msg: get_msg_content_processed(msg)})

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
                                     } = _attachment ->
          size = Sizeable.filesize(size, spacer: "")
          Overdiscord.IRC.Bridge.send_msg(username, "#{filename} #{size}: #{url}")
        end)
    end
  end

  def on_msg(msg) do
    discord_activity(:discord)
    IO.inspect(msg, label: :UnhandledMsg)
  end

  def on_msg_edit(%{author: nil, channel_id: "320192373437104130", embeds: [_ | _] = embeds}) do
    discord_activity(:discord)
    IO.inspect(embeds, label: :BotEdit)

    Enum.map(embeds, fn %{title: title, description: description} ->
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

    if NaiveDateTime.compare(last_activity, NaiveDateTime.add(now, -60 * 60, :seconds)) == :lt do
      IO.puts("===============================")

      IO.inspect(
        {:DiscordMaybeDead, last_activity, now, NaiveDateTime.add(now, -60 * 60, :seconds)}
      )
    end
  end

  def get_msg_content_processed(%Alchemy.Message{channel_id: channel_id, content: content} = msg) do
    case Alchemy.Cache.guild_id(channel_id) do
      {:error, reason} ->
        IO.inspect("Unable to process guild_id: #{reason}\n\t#{msg}")
        content

      {:ok, guild_id} ->
        Regex.replace(~r/<@!?([0-9]+)>/, content, fn full, user_id ->
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
    end
  end
end
