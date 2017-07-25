defmodule Overdiscord do
  @moduledoc """
  """

  use Application

  def start(_type, _args) do
    import Supervisor.Spec, warn: false
    {:ok, client} = ExIrc.start_link!()

    children = [
      worker(Overdiscord.IRC.Bridge, [client]),
      worker(Alchemy.Client, [System.get_env("OVERDISCORD_TOKEN"), []]),
      worker(Overdiscord.Commands, [])
    ]

    opts = [strategy: :one_for_one, name: Overdiscord.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
