defmodule Overdiscord.Web.Endpoint do
  use Phoenix.Endpoint, otp_app: :overdiscord

  require Logger

  plug(
    Plug.Static,
    at: "/",
    from: :overdiscord,
    gzip: false,
    only: ~w(css fonts images js favicon.ico robots.txt)
  )

  plug(GhWebhookPlug,
    secret: "tGEDjaBUxqUYSkOVRMN/H4K8Nb7JdVcx5PlCdO4/n/+1k+Cl76BeI7I65+Xsax0T",
    path: "/github/webhook",
    action: {Overdiscord.Web.GithubWebhookController, :webhook}
  )

  socket("/socket", Overdiscord.Web.UserSocket, websocket: true, longpoll: false)

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
    body_reader: {__MODULE__, :read_body, []},
    json_decoder: Phoenix.json_library()
  )

  plug(:verify_signature,
    matchers: [
      %{
        path: "/api/webhook/ci",
        header: "x-hub-signature",
        hmac: :sha,
        key: Application.get_env(:overdiscord, :ci_token_key, nil) || throw(:missing_ci_token_key)
      }
    ]
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

  def read_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)
    conn = update_in(conn.assigns[:raw_body], &[body | &1 || []])
    {:ok, body, conn}
  end

  def verify_signature(conn, opts) do
    verify_signature(conn, opts, Keyword.get(opts, :matchers))
  end

  def verify_signature(conn, _opts, []) do
    conn
  end

  def verify_signature(conn, opts, [matcher | matchers]) do
    if matcher.path == conn.request_path do
      case matcher do
        %{header: header, hmac: :sha = hmac, key: key} ->
          token =
            case Plug.Conn.get_req_header(conn, header)
                 |> IO.inspect(label: :token)
                 |> List.first() do
              "sha=" <> token -> token
              "sha1=" <> token -> token
              token -> token
            end
            |> String.downcase()
            |> IO.inspect(label: :token_processed)

          # {:ok, body, conn} = Plug.Conn.read_body(conn) |> IO.inspect(label: :body)
          body = conn.assigns[:raw_body] || ""

          verify_token =
            :crypto.hmac(hmac, key, body)
            |> Base.encode16()
            |> String.downcase()
            |> IO.inspect(label: :verify_token)

          if token == verify_token do
            conn |> Plug.Conn.put_private(:verified_signature, true)
          else
            Logger.info("Invalid signature on request")
            conn |> Plug.Conn.send_resp(401, "invalid signature") |> Plug.Conn.halt()
          end
      end
    else
      verify_signature(conn, opts, matchers)
    end
  end
end
