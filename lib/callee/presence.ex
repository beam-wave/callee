defmodule Callee.Presence do
  @moduledoc """
  Which parties have at least one connected tab. Each signalling channel process
  registers under its party; Registry drops the entry when the process exits.
  """
  @registry Callee.OnlineRegistry

  def track(party), do: Registry.register(@registry, party, nil)
  def online?(party), do: Registry.lookup(@registry, party) != []
end
