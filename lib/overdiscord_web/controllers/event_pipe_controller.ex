defmodule Overdiscord.Web.EventPipeController do
  use Overdiscord.Web, :controller

  alias Overdiscord.EventPipe

  plug(:plug_authenticated, role: :admin)

  def index(conn, _params) do
    hooks = EventPipe.get_all_hooks()
    render(conn, :index, hooks: hooks)
  end

  def history(conn, _params) do
    events = EventPipe.get_history()
    render(conn, :history, events: events)
  end

  def new_hook(conn, params) do
    IO.inspect(params)
    text(conn, "vwoop")
  end
end
