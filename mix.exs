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
      {:inch_ex, "~> 1.0", only: [:docs, :dev, :test]},
      {:credo, "~> 0.8", only: [:docs, :dev, :test]},
      {:alchemy, "~> 0.6.1", hex: :discord_alchemy},
      {:httpoison, "~> 1.2.0", override: true},
      {:exirc, "~> 1.0"},
      {:sizeable, "~> 1.0"},
      {:meeseeks, "~> 0.9"},
      {:cachex, "~> 3.0"},
      {:exsync, "~> 0.2", only: :dev},
      {:dialyxir, "~> 0.5.1", only: [:dev, :test], runtime: false},
      {:exleveldb, "~> 0.12"},
      {:gen_stage, "~> 0.13", override: true},
      {:quantum, "~> 2.2"},
      {:timex, "~> 3.2"},
      {:luerl, "~> 0.3"},
      {:protocol_ex, "~> 0.4.0"},
      {:phoenix, github: "phoenixframework/phoenix", override: true},
      {:phoenix_pubsub, "~> 1.0"},
      {:phoenix_html, "~> 2.11"},
      {:phoenix_live_reload, "~> 1.0", only: :dev},
      {:gettext, "~> 0.11"},
      {:jason, "~> 1.0"},
      {:cowboy, "~> 1.0"},
      {:drab, "~> 0.9.0"},
      {:gh_webhook_plug, "~> 0.0.5"}
    ]
  end
end
