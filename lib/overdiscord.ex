defmodule Overdiscord do
  @moduledoc """
  """

  use Application

  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    case Code.ensure_loaded(ExSync) do
      {:module, ExSync} -> ExSync.start()
      _ -> :ok
    end

    #{:ok, client} = ExIrc.start_link!()

    children = [
      worker(Overdiscord.IRC.Bridge, []),
      worker(Alchemy.Client, [System.get_env("OVERDISCORD_TOKEN"), []]),
      worker(Overdiscord.Commands, []),
      worker(Cachex, [:summary_cache, [
                         fallback: &Overdiscord.SiteParser.get_summary_cache_init/1,
                         #default_ttl: :timer.hours(24),
                         disable_ode: true,
                         #ttl_interval: :timer.hours(1),
                         limit: %Cachex.Limit{limit: 10000, reclaim: 0.1},
                         record_stats: true,
                       ]]),
    ]

    opts = [strategy: :one_for_one, name: Overdiscord.Supervisor, restart: :permanent]
    Supervisor.start_link(children, opts)
  end
end
