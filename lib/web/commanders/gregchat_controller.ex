defmodule Overdiscord.Web.GregchatController do
  use Overdiscord.Web, :controller

  def index(conn, _params) do
    render(conn, "index.html")
  end
end
