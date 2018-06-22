defmodule Overdiscord do
  @moduledoc """
  Central Application and Supervisor for the various systems.
  """

  use Application

  @doc "Application entrance location, unused args"
  def start(_type, _args) do
    import Supervisor.Spec, warn: false
    import Cachex.Spec

    case Code.ensure_loaded(ExSync) do
      {:module, ExSync} -> ExSync.start()
      _ -> :ok
    end

    # {:ok, client} = ExIrc.start_link!()

    children = [
      worker(Overdiscord.Storage, []),
      worker(Overdiscord.Cron, []),
      Overdiscord.Web.Endpoint,
      worker(Overdiscord.IRC.Bridge, []),
      worker(Alchemy.Client, [System.get_env("OVERDISCORD_TOKEN"), []]),
      worker(Overdiscord.Commands, []),
      worker(Cachex, [
        :summary_cache,
        [
          # fallback: fallback(default: &Overdiscord.SiteParser.get_summary_cache_init/1),
          # default_ttl: :timer.hours(24),
          disable_ode: true,
          # ttl_interval: :timer.hours(1),
          limit: limit(size: 10000, reclaim: 0.1, policy: Cachex.Policy.LRW),
          record_stats: true
        ]
      ])
    ]

    opts = [strategy: :one_for_one, name: Overdiscord.Supervisor, restart: :permanent]
    Supervisor.start_link(children, opts)
  end

  def config_change(changed, _new, removed) do
    Overdiscord.Web.Endpoint.config_change(changed, removed)
    :ok
  end
end
