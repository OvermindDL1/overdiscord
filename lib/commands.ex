defmodule Overdiscord.Commands do

  use Alchemy.Events

  def on_msg(%{author: %{id: "336892378759692289"}}) do
    # Ignore bot message
    :ok
  end
  def on_msg(%{author: %{bot: _true_or_false, username: username}, channel_id: "320192373437104130", content: content}=msg) do
    case content do
      "!list" -> Overdiscord.IRC.Bridge.list_users()
      "!"<>_ -> :ok
      content ->
        IO.inspect("Sending message from Discord to IRC: #{username}: #{content}")
        Overdiscord.IRC.Bridge.send_msg(username, content)
    end
  end
  def on_msg(msg) do
    #IO.inspect(msg, label: :UnhandledMsg)
  end

  def start_link() do
    GenServer.start_link(__MODULE__, [])
  end

  def init(_) do
    use Overdiscord.Commands.Basic
    use Overdiscord.Commands.GT6
    Alchemy.Cogs.EventHandler.add_handler({:message_create, {__MODULE__, :on_msg}})
    {:ok, nil}
  end

end
