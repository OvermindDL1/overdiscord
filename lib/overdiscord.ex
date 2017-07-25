defmodule Overdiscord do
  @moduledoc """
  """

  use Application
  alias Alchemy.Client


  def start(_type, _args) do
    import Supervisor.Spec, warn: false
    {:ok, client} = ExIrc.start_link!()

    children = [
      worker(Overdiscord.IRC.Bridge, [client]),
      worker(Client, [System.get_env("OVERDISCORD_TOKEN"), []]),
      worker(Overdiscord.Commands, [])
    ]

    opts = [strategy: :one_for_one, name: Overdiscord.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
