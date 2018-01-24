defmodule Overdiscord.Mixfile do
  use Mix.Project

  def project do
    [
      app: :overdiscord,
      version: "0.1.0",
      elixir: "~> 1.4",
      build_embedded: Mix.env == :prod,
      start_permanent: Mix.env == :prod,
      deps: deps(),
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
        :logger,
      ],
    ]
  end

  defp deps do
    [
      {:alchemy, "~> 0.6.1", hex: :discord_alchemy},
      {:httpoison, "~> 0.12.0", override: true},
      {:exirc, "~> 1.0"},
      {:sizeable, "~> 1.0"},
      {:meeseeks, "~> 0.7.2"},
      {:opengraph, "~> 0.1.0"},
      {:cachex, "~> 2.1"},
      {:exsync, "~> 0.2.1", only: :dev},
      {:exleveldb, "~> 0.12.2"},
      {:gen_stage, "~> 0.13", override: true},
      {:quantum, "~> 2.2"},
      {:timex, "~> 3.1"},
      {:luerl, "~> 0.3.1"},
    ]
  end
end
