defmodule Overdiscord.Mixfile do
  use Mix.Project

  def project do
    [
      app: :overdiscord,
      version: "0.1.0",
      elixir: "~> 1.4",
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      compilers: [:phoenix, :gettext] ++ Mix.compilers() ++ [:protocol_ex],
      deps: deps(),
      dialyzer: [
        plt_add_deps: :transitive
      ]
    ]
  end

  # Configuration for the OTP application
  #
  # Type "mix help compile.app" for more information
  def application do
    # Specify extra applications you'll use from Erlang/Elixir
    [
      mod: {Overdiscord, []},
      extra_applications: [
        :logger
      ]
    ]
  end

  defp deps do
    [
      {:inch_ex, "~> 2.0", only: [:docs, :dev, :test]},
      {:credo, "~> 1.1.2", only: [:docs, :dev, :test]},
      {:alchemy, "~> 0.7.0", hex: :discord_alchemy},
      {:httpoison, "~> 1.5.0", override: true},
      # {:exirc, "~> 1.0.1"},
      {:exirc, github: "bitwalker/exirc"},
      {:sizeable, "~> 1.0"},
      {:meeseeks, "~> 0.15.1"},
      {:cachex, "~> 3.0"},
      {:exsync, "~> 0.2", only: :dev},
      {:dialyxir, "~> 0.5.1", only: [:dev, :test], runtime: false},
      {:earmark, "~> 1.4.2"},
      {:exleveldb, "~> 0.14"},
      {:gen_stage, "~> 0.14.2"},
      {:quantum, "~> 2.2"},
      {:timex, "~> 3.6.1"},
      {:luerl, "~> 0.3"},
      {:protocol_ex, "~> 0.4.0"},
      {:plug, "~> 1.8.2"},
      {:plug_cowboy, "~> 2.1.0"},
      {:phoenix, "~> 1.4.9"},
      {:phoenix_pubsub, "~> 1.1"},
      {:phoenix_html, "~> 2.13.3"},
      {:phoenix_live_reload, "~> 1.0", only: :dev},
      {:gettext, "~> 0.17.0"},
      {:jason, "~> 1.0"},
      # {:rustler, "~> 0.18.0", override: true},
      # {:html5ever, "~> 0.6.1"},
      {:floki, "~> 0.31.0"},
      {:drab, "~> 0.10.1"},
      {:gh_webhook_plug, "~> 0.0.5"},
      {:decimal, "~> 1.8"}
    ]
  end
end
