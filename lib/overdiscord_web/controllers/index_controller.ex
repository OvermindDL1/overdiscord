defmodule Overdiscord.Web.IndexController do
  use Overdiscord.Web, :controller

  def index(conn, _params) do
    if Account.authenticated?(conn) do
      render(conn, :index)
    else
      render(conn, :login)
    end
  end

  def authenticate(conn, %{"authentication" => %{"id" => id}}) do
    if Account.authenticated?(conn) do
      {:error, 404}
    else
      conn = Account.authenticate(conn, id)

      if Account.authenticated?(conn) do
        redirect(conn, to: Routes.index_path(conn, :index))
      else
        conn
        |> put_flash(:error, "Failed Authentication")
        |> redirect(to: Routes.index_path(conn, :index))
      end
    end
  end

  def logout(conn, _params) do
    if Account.authenticated?(conn) do
      Account.unauthenticate(conn)
      |> redirect(to: Routes.index_path(conn, :index))
    else
      {:error, 404}
    end
  end
end
