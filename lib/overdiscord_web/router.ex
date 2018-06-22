defmodule Overdiscord.Web.Router do
  use Overdiscord.Web, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_flash)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/", Overdiscord.Web do
    # Use the default browser stack
    pipe_through(:browser)

    get("/gregchat", GregchatController, :index)
  end

  # Other scopes may use custom stacks.
  # scope "/api", Overdiscord.Web do
  #   pipe_through :api
  # end
end
