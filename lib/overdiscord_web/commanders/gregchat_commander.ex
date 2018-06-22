defmodule Overdiscord.Web.GregchatCommander do
  use Drab.Commander
  use Overdiscord.Web, :commander

  @msgs "#greg-irc-messages"

  # Place your event handlers here
  #
  # defhandler button_clicked(socket, sender) do
  #   set_prop socket, "#output_div", innerHTML: "Clicked the button!"
  # end
  #
  # Place you callbacks here
  #
  onload(:page_loaded)

  def page_loaded(socket) do
    # :ok = subscribe(socket, @msgs)
    :ok = Overdiscord.Web.Endpoint.subscribe(@msgs)
    set_prop(socket, @msgs, innerText: "Message connection established...")
  end

  def append_msg(msg) do
    topic = same_path(Routes.gregchat_path(Overdiscord.Web.Endpoint, :index))

    {:safe, h} = ~E"""
    <br><%= msg %>
    """

    {:ok, :broadcasted} = broadcast_insert(topic, @msgs, :beforeEnd, to_string(h))
  end
end
