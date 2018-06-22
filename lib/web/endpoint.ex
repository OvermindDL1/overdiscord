defmodule Overdiscord.Web.Endpoint do
  use Phoenix.Endpoint, otp_app: :overdiscord

  plug(
    Plug.Static,
    at: "/",
    from: :overdiscord,
    gzip: false,
    only: ~w(css fonts images js favicon.ico robots.txt)
  )

  socket("/socket", DevAppWeb.UserSocket, websocket: true, longpoll: false)

  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)
  end

  plug(Plug.RequestId)
  plug(Plug.Logger)

  plug(
    Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)

  # Set :encryption_salt if you would also like to encrypt it.
  plug(
    Plug.Session,
    store: :cookie,
    key: "_overdiscord_key",
    signing_salt: "W4JZm7gO"
  )

  plug(Overdiscord.Web.Router)
end
