defmodule Callee.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      CalleeWeb.Telemetry,
      Callee.Repo,
      {DNSCluster, query: Application.get_env(:callee, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Callee.PubSub},
      {Registry, keys: :unique, name: Callee.CallRegistry},
      {Registry, keys: :duplicate, name: Callee.OnlineRegistry},
      {Registry, keys: :duplicate, name: Callee.InviteRegistry},
      {DynamicSupervisor, name: Callee.CallSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Callee.MediaSupervisor, strategy: :one_for_one},
      {Task.Supervisor, name: Callee.TaskSupervisor},
      {Task, &Callee.Boot.run/0},
      # Start to serve requests, typically the last entry
      CalleeWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Callee.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CalleeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
