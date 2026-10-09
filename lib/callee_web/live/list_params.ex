defmodule CalleeWeb.ListParams do
  @moduledoc "Shared URL-param handling (q / filter / page) for paginated LiveViews."
  import Phoenix.LiveView, only: [push_patch: 2]

  def take(params), do: Map.take(params, ["q", "filter", "page"])

  def search(socket, path, q) do
    params = Map.merge(socket.assigns.params, %{"q" => q, "page" => nil})
    push_patch(socket, to: CalleeWeb.UI.patch_url(path, params))
  end

  def filtered?(params), do: (params["q"] || "") != "" or (params["filter"] || "all") != "all"
end
