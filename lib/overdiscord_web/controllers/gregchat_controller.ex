defmodule Overdiscord.Web.GregchatController do
  use Overdiscord.Web, :controller

  plug(:plug_authenticated, role: :admin)

  def index(conn, _params) do
    {:ok, name} = Account.get_name(conn)
    render(conn, "index.html", name: name)
  end

  def index(conn, _params) do
    conn
    |> put_status(:not_found)
    |> put_layout(false)
    |> put_view(Overdiscord.Web.ErrorView)
    |> render("404.html")
  end
end
