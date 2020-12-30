# This file is responsible for configuring your application
# and its dependencies with the aid of the Mix.Config module.
use Mix.Config

# This configuration is loaded before any dependency and is restricted
# to this project. If another project depends on this project, this
# file won't be loaded nor affect the parent project. For this reason,
# if you want to provide default values for your application for
# 3rd-party users, it should be done in your "mix.exs" file.

# You can configure for your application as:
#
#     config :overdiscord, key: :value
#
# And access this configuration in your application as:
#
#     Application.get_env(:overdiscord, :key)
#
# Or configure a 3rd-party app:
#
#     config :logger, level: :info
#

config :logger,
  level: :info,
  handle_otp_reports: true,
  handle_sasl_reports: true

# format: "$time $metadata[$level] $message\n",
# metadata: [:request_id]

config :alchemy,
  ffmpeg_path: "/usr/bin/ffmpeg",
  youtube_dl_path: "/usr/local/bin/youtube-dl"

config :overdiscord, Overdiscord.Cron,
  jobs: [
    # {"0 * * * *", {Overdiscord.IRC.Bridge, :poll_xkcd, []}},
    {"*/30 * * * *", {Overdiscord.IRC.Bridge, :poll_feeds, []}},
    {"*/1 * * * *", {Overdiscord.IRC.Bridge, :poll_delay_msgs, []}},
    {"*/15 * * * *", {Overdiscord.Commands, :check_dead, []}}
  ]

# Configure the CI webhook key
config :overdiscord,
       :ci_token_key,
       System.get_env("OVERDISCORD_CI_TOKEN_KEY") || throw("Set `OVERDISCORD_CI_TOKEN_KEY`")

# Configures the endpoint
config :overdiscord, Overdiscord.Web.Endpoint,
  server: true,
  url: [host: "home.overminddl1.com"],
  secret_key_base:
    System.get_env("OVERDISCORD_WEB_KEY_BASE") ||
      (case Mix.env() do
         :test ->
           "<TEST-KEY>"

         _ ->
           throw("Set `secret_key_base` via the environment variable `OVERDISCORD_WEB_KEY_BASE`")
       end),
  render_errors: [view: Overdiscord.Web.ErrorView, accepts: ~w(html json)],
  pubsub: [name: Overdiscord.Web.PubSub, adapter: Phoenix.PubSub.PG2],
  http: [port: 5000],
  debug_errors: false,
  code_reloader: false,
  check_origin: false,
  watchers: [
    node: [
      "node_modules/webpack/bin/webpack.js",
      "--mode",
      "development",
      "--watch-stdin",
      cd: Path.expand("../assets", __DIR__)
    ]
  ],
  live_reload: [
    patterns: [
      ~r{priv/static/.*(js|css|png|jpeg|jpg|gif|svg)$},
      ~r{priv/gettext/.*(po)$},
      ~r{lib/overdiscord_web/views/.*(ex)$},
      ~r{lib/overdiscord_web/templates/.*(eex|drab)$}
    ]
  ]

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
# config :phoenix, :plug_init_mode, :runtime

# Use Jason for JSON parsing in Phoenix and Ecto
config :phoenix, :json_library, Jason

# config :floki, :html_parser, Floki.HTMLParser.Html5ever

config :drab, pubsub: Overdiscord.Web.PubSub

config :phoenix, :template_engines, drab: Drab.Live.Engine

# config :drab,
#  main_phoenix_app: :overdiscord,
#  endpoint: Overdiscord.Web.Endpoint,
#  pubsub: Overdiscord.Web.PubSub,
#  js_socket_constructor: "PhoenixSocket"

config :drab, Overdiscord.Web.Endpoint,
  otp_app: :overdiscord,
  main_phoenix_app: :overdiscord,
  endpoint: Overdiscord.Web.Endpoint,
  pubsub: Overdiscord.Web.PubSub,
  js_socket_constructor: "PhoenixSocket"
