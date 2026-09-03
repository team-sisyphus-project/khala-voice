defmodule VR.AdminAudit do
  @moduledoc """
  Structured audit store for admin account operations.

  Events are recorded append-only with no update API. Raw emails are never stored;
  searches use only account IDs and a limited set of classification fields. Online
  retention is 365 days, and `VR.Workers.AdminAuditRetentionWorker` permanently
  deletes expired events daily.
  """

  import Ecto.Query, warn: false

  alias VR.AdminAudit.Event
  alias VR.Repo

  @retention_days 365
  @exact_filters ~w(event_id action outcome reason actor_account_id target_account_id request_id)a
  @range_filters ~w(occurred_from occurred_until)a
  @search_filters @exact_filters ++ @range_filters

  @doc "Adds an audit event after masking the raw emails."
  def record(attrs) when is_map(attrs) do
    attrs
    |> changeset()
    |> Repo.insert()
  end

  @doc false
  def changeset(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.put_new(:occurred_at, DateTime.utc_now(:second))
      |> Map.put_new(:request_id, request_id())
      |> Map.put(:actor_email_masked, mask_email(attrs[:actor_email] || attrs["actor_email"]))
      |> Map.put(:target_email_masked, mask_email(attrs[:target_email] || attrs["target_email"]))
      |> Map.drop([:actor_email, :target_email, "actor_email", "target_email"])

    Event.changeset(%Event{}, attrs)
  end

  @doc "Searches events using the allowed exact-match and occurrence-time range filters."
  def search(filters \\ []) when is_list(filters) do
    unsupported = filters |> Keyword.keys() |> Enum.uniq() |> Kernel.--(@search_filters)

    if unsupported == [] do
      query =
        Enum.reduce(@exact_filters, Event, fn field, query ->
          case Keyword.fetch(filters, field) do
            {:ok, value} -> where(query, [event], field(event, ^field) == ^value)
            :error -> query
          end
        end)

      query =
        case Keyword.fetch(filters, :occurred_from) do
          {:ok, value} -> where(query, [event], event.occurred_at >= ^value)
          :error -> query
        end

      query =
        case Keyword.fetch(filters, :occurred_until) do
          {:ok, value} -> where(query, [event], event.occurred_at <= ^value)
          :error -> query
        end

      {:ok, Repo.all(order_by(query, [event], desc: event.occurred_at, desc: event.event_id))}
    else
      {:error, {:unsupported_filters, Enum.sort(unsupported)}}
    end
  end

  @doc "Permanently deletes events older than 365 days from the operational store."
  def purge_expired(now \\ DateTime.utc_now(:second)) do
    cutoff = DateTime.add(now, -@retention_days, :day)
    {count, _} = Repo.delete_all(from event in Event, where: event.occurred_at <= ^cutoff)
    count
  end

  @doc "Builds the policy-compliant display value for an email. The raw value is never returned or stored."
  def mask_email(email) when is_binary(email) do
    normalized = email |> String.trim() |> String.downcase()

    with [local, domain] <- String.split(normalized, "@"),
         false <- local == "",
         [_, _ | _] = labels <- String.split(domain, "."),
         false <- Enum.any?(labels, &(&1 == "")),
         {first, _rest} <- String.next_grapheme(local) do
      first <> "***@***." <> List.last(labels)
    else
      _ -> "[redacted]"
    end
  end

  def mask_email(_), do: "[redacted]"

  defp request_id do
    Logger.metadata()[:request_id] || "audit-#{Ecto.UUID.generate()}"
  end
end
