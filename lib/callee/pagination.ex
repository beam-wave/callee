defmodule Callee.Pagination do
  @moduledoc "Offset pagination for Ecto queries."
  import Ecto.Query
  alias Callee.Repo

  defstruct entries: [], page: 1, per_page: 20, total: 0, total_pages: 1

  @type t :: %__MODULE__{}

  def paginate(query, page, per_page \\ 20) do
    total =
      query
      |> exclude(:preload)
      |> exclude(:order_by)
      |> exclude(:select)
      |> select(count())
      |> Repo.one()

    total_pages = max(1, ceil(total / per_page))
    page = page |> to_page() |> min(total_pages)

    entries = query |> limit(^per_page) |> offset(^((page - 1) * per_page)) |> Repo.all()

    %__MODULE__{
      entries: entries,
      page: page,
      per_page: per_page,
      total: total,
      total_pages: total_pages
    }
  end

  def to_page(p) when is_integer(p) and p > 0, do: p

  def to_page(p) when is_binary(p) do
    case Integer.parse(p) do
      {n, _} when n > 0 -> n
      _ -> 1
    end
  end

  def to_page(_), do: 1

  @doc "Escapes LIKE wildcards in user search input."
  def like(q), do: "%" <> String.replace(q, ~r/([\\%_])/, "\\\\\\1") <> "%"
end
