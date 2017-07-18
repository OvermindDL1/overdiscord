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

    #p=Overdiscord.IRC.Bridge.start_link(client)

    #case System.get_env("OVERDISCORD_TOKEN") do
    #  nil -> System.halt(0)
    #  "" -> System.halt(0)
    #  token when is_binary(token) ->
    #    run = Client.start(token)
    #    use Overdiscord.Commands.Basic
    #    use Overdiscord.Commands.GT6
    #    run
    #end
    #p
  end
end
