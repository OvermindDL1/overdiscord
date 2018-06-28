defmodule Overdiscord.Web.GregchatCommander do
  use Drab.Commander, access_session: [Overdiscord.Web.Account.session_tag()]
  use Overdiscord.Web, :commander

  @msgs "#greg-irc-messages"

  onload(:page_loaded)

  def page_loaded(socket) do
    # :ok = subscribe(socket, @msgs)
    :ok = Overdiscord.Web.Endpoint.subscribe(@msgs)
    set_prop(socket, @msgs, innerText: "Message connection established...")
  end

  def append_msg(msg) do
    topic = same_path(Routes.gregchat_path(Overdiscord.Web.Endpoint, :index))

    {:safe, h} = ~E"""
    <%= msg %><br>
    """

    {:ok, :broadcasted} = broadcast_insert(topic, @msgs, :afterBegin, to_string(h))
  end

  defhandler send_body(socket, %{params: %{"send_body" => body}}) do
    {:ok, event_auth} = Account.to_event_auth(socket)
    {:ok, name} = Account.get_name(socket)
    IO.puts("Sending message from `#{name}` at Web:  #{body}")

    # Alchemy.Client.send_message(Overdiscord.IRC.Bridge.alchemy_channel(), "**#{name}:** #{body}")
    # Overdiscord.IRC.Bridge.send_msg(name, body)
    Overdiscord.EventPipe.inject(event_auth, %{msg: body})
    set_prop(socket, "#send_body", value: "")
  end
end
