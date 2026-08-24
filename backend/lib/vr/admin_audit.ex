defmodule VR.AdminAudit do
  @moduledoc """
  관리자 계정 작업의 구조화 감사 저장소.

  이벤트는 수정 API 없이 추가 전용으로 기록한다. 이메일 원문은 저장하지 않으며,
  계정 ID와 제한된 분류 필드로만 검색한다. 온라인 보존 기간은 365일이고 매일
  `VR.Workers.AdminAuditRetentionWorker`가 만료 이벤트를 영구 삭제한다.
  """

  import Ecto.Query, warn: false

  alias VR.AdminAudit.Event
  alias VR.Repo

  @retention_days 365
  @exact_filters ~w(event_id action outcome reason actor_account_id target_account_id request_id)a
  @range_filters ~w(occurred_from occurred_until)a
  @search_filters @exact_filters ++ @range_filters

  @doc "원문 이메일을 마스킹한 뒤 감사 이벤트를 추가한다."
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

  @doc "허용된 정확 일치 및 발생시각 범위 조건으로 이벤트를 검색한다."
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

  @doc "365일이 지난 이벤트를 운영 저장소에서 영구 삭제한다."
  def purge_expired(now \\ DateTime.utc_now(:second)) do
    cutoff = DateTime.add(now, -@retention_days, :day)
    {count, _} = Repo.delete_all(from event in Event, where: event.occurred_at <= ^cutoff)
    count
  end

  @doc "정책에 따른 이메일 표시값을 만든다. 원문은 반환하거나 저장하지 않는다."
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
