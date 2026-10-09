defmodule CalleeWeb.LiveHelpers do
  @moduledoc "Formatting helpers shared by the LiveViews."

  def fmt_dt(nil), do: "—"
  def fmt_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%d %b %Y, %H:%M UTC")

  def fmt_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%d %b %Y")
  def fmt_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M")

  def fmt_duration(nil), do: nil
  def fmt_duration(0), do: nil

  def fmt_duration(s) when is_integer(s) do
    h = div(s, 3600)
    m = div(rem(s, 3600), 60)
    sec = rem(s, 60)

    cond do
      h > 0 -> "#{h}h #{m}m"
      m > 0 -> "#{m}m #{sec}s"
      true -> "#{sec}s"
    end
  end

  @doc "Friendly relative time: 'just now', '5 min ago', 'yesterday', '3 days ago'."
  def rel_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)} min ago"
      diff < 86_400 -> "#{div(diff, 3600)} h ago"
      diff < 2 * 86_400 -> "yesterday"
      diff < 7 * 86_400 -> "#{div(diff, 86_400)} days ago"
      true -> fmt_date(dt)
    end
  end

  @doc "Section label for grouping call history by day."
  def day_label(%DateTime{} = dt) do
    today = Date.utc_today()
    d = DateTime.to_date(dt)

    cond do
      d == today -> "Today"
      d == Date.add(today, -1) -> "Yesterday"
      Date.diff(today, d) < 7 -> Calendar.strftime(d, "%A")
      true -> Calendar.strftime(d, "%d %B %Y")
    end
  end

  @doc "Groups an ordered list into [{label, items}] keeping order."
  def group_by_day(items, dt_fun) do
    items
    |> Enum.chunk_by(&day_label(dt_fun.(&1)))
    |> Enum.map(fn chunk -> {day_label(dt_fun.(hd(chunk))), chunk} end)
  end

  def expiry_label(%DateTime{} = exp) do
    days = DateTime.diff(exp, DateTime.utc_now(), :day)

    cond do
      DateTime.compare(exp, DateTime.utc_now()) != :gt -> "Expired #{rel_time(exp)}"
      days == 0 -> "Expires today"
      days == 1 -> "Expires tomorrow"
      true -> "Expires in #{days} days"
    end
  end

  def status_text("completed"), do: "Completed"
  def status_text("active"), do: "On call now"
  def status_text("ringing"), do: "Ringing"
  def status_text("missed"), do: "Missed"
  def status_text("rejected"), do: "Declined"
  def status_text("cancelled"), do: "Cancelled"
  def status_text("busy"), do: "Busy"
  def status_text("failed"), do: "Failed"
  def status_text(s), do: s

  def status_badge(s) do
    cls =
      case s do
        "completed" -> "badge-success"
        "active" -> "badge-info"
        "ringing" -> "badge-warning"
        "busy" -> "badge-warning"
        s when s in ["missed", "rejected", "failed"] -> "badge-error"
        _ -> "badge-ghost"
      end

    {cls, status_text(s)}
  end

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
    |> Enum.map_join("; ", fn {k, v} -> "#{Phoenix.Naming.humanize(k)} #{Enum.join(v, ", ")}" end)
  end
end
