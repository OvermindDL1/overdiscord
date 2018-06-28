defmodule Overdiscord.Web.Router do
  use Overdiscord.Web, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_flash)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :authenticated do
    plug(:plug_authenticated)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/eventpipe", Overdiscord.Web do
    pipe_through([:browser, :authenticated])

    get("/", EventPipeController, :index)
    get("/history", EventPipeController, :history)
    post("/new_hook", EventPipeController, :new_hook)
    delete("/delete_hook/:priority", EventPipeController, :delete_hook)
  end

  scope "/", Overdiscord.Web do
    pipe_through(:browser)

    get("/", IndexController, :index)
    post("/authenticate", IndexController, :authenticate)
    get("/logout", IndexController, :logout)

    get("/gregchat", GregchatController, :index)
  end

  # Other scopes may use custom stacks.
  # scope "/api", Overdiscord.Web do
  #   pipe_through :api
  # end
end
