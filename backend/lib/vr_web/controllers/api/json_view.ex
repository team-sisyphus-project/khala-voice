defmodule VRWeb.API.JSONView do
  @moduledoc """
  API 응답 직렬화.

  ## 마스킹 규칙

  Viewer 에게는 `audio_url` 을 내려주지 않는다. 화면에서 버튼을 숨기는 것만으로는
  API를 직접 호출하면 그만이다. **서버에서 지운다.**
  """

  alias VR.Access.AccessLevel

  def meeting(meeting, level, opts \\ []) do
    base = %{
      id: meeting.id,
      title: meeting.title,
      description: meeting.description,
      status: meeting.status,
      started_at: meeting.started_at,
      owner_id: meeting.owner_id,
      reviewer_id: meeting.reviewer_id,
      contributor_ids: meeting.contributor_ids,
      topic_id: meeting.topic_id,
      label_ids: meeting.label_ids,
      total_duration_seconds: meeting.total_duration_seconds,
      total_credits_charged: meeting.total_credits_charged,
      summary: meeting.summary,
      summary_data: meeting.summary_data,
      last_summary_error: meeting.last_summary_error,
      guest_link_enabled: meeting.guest_link_enabled,
      archived_at: meeting.archived_at,
      inserted_at: meeting.inserted_at,
      updated_at: meeting.updated_at,
      # 클라이언트가 UI를 그릴 때 쓴다. 판정은 서버가 이미 끝냈다.
      role: AccessLevel.to_role(level),
      view_level: AccessLevel.to_string!(level)
    }

    base =
      if AccessLevel.at_least?(level, :lv0) do
        Map.put(base, :permissions, meeting.permissions)
      else
        base
      end

    base =
      case opts[:taxonomy] do
        nil ->
          base

        %{topics: topics, labels: labels} ->
          # 이름·색을 동봉한다. 그 회의 전문을 이미 읽을 수 있는 사람에게
          # 분류 이름을 숨기는 것은 방어가 아니라 화면만 망가뜨리는 일이다.
          base
          |> Map.put(:topic, topics[meeting.topic_id] && topic(topics[meeting.topic_id]))
          |> Map.put(
            :labels,
            (meeting.label_ids || [])
            |> Enum.map(&labels[&1])
            |> Enum.reject(&is_nil/1)
            |> Enum.map(&label/1)
          )
      end

    case opts[:sessions] do
      nil -> base
      sessions -> Map.put(base, :recording_sessions, Enum.map(sessions, &session(&1, level)))
    end
  end

  def session(session, level) do
    base = %{
      id: session.id,
      meeting_id: session.meeting_id,
      session_index: session.session_index,
      status: session.status,
      started_at_unix: session.started_at_unix,
      duration_seconds: session.duration_seconds,
      transcript: session.transcript,
      speaker_map: session.speaker_map,
      credits_charged: session.credits_charged,
      file_size_bytes: session.file_size_bytes,
      mime_type: session.mime_type,
      metadata: session.metadata,
      error_message: session.error_message,
      inserted_at: session.inserted_at
    }

    # Viewer 는 오디오 원본에 접근하지 못한다.
    #
    # **URL 을 내려보내지 않는다.** 저장 키는 `meeting_id` · `session_id` ·
    # `started_at_unix` · 확장자로 완전히 결정되는데 그 값들이 이 응답에 다 들어 있다.
    # 필드만 지우면 손으로 조립해 원본을 받을 수 있으므로, 서명된 URL 로 리다이렉트하는
    # 엔드포인트만 알려준다.
    if AccessLevel.at_least?(level, :lv1) and present?(session.storage_key) do
      Map.put(base, :audio_href, "/api/sessions/#{session.id}/audio")
    else
      base
    end
  end

  # 카운트가 붙은 형태를 먼저 매치한다 — 순서가 바뀌면 카운트가 사라진다
  def topic(%{topic: topic, meeting_count: count}),
    do: Map.put(topic(topic), :meeting_count, count)

  def topic(%VR.Taxonomy.Topic{} = topic) do
    %{
      id: topic.id,
      name: topic.name,
      color: topic.color,
      sort_order: topic.sort_order,
      deleted: not is_nil(topic.deleted_at)
    }
  end

  def label(%{label: label, meeting_count: count}),
    do: Map.put(label(label), :meeting_count, count)

  def label(%VR.Taxonomy.Label{} = label) do
    %{
      id: label.id,
      name: label.name,
      color: label.color,
      deleted: not is_nil(label.deleted_at)
    }
  end

  @doc """
  공유 링크. **`token_hash` · `pin_hash` · 평문 토큰 · 평문 PIN 은 절대 넣지 않는다.**

  `token_prefix` 는 목록에서 어느 링크인지 알아보기 위한 것이고 이것만으로는 못 들어온다.
  """
  def shared_link(link) do
    %{
      id: link.id,
      granted_role: link.granted_role,
      token_prefix: link.token_prefix,
      max_uses: link.max_uses,
      use_count: link.use_count,
      expires_at: link.expires_at,
      is_active: link.is_active,
      require_name: link.require_name,
      require_email: link.require_email,
      has_pincode: not is_nil(link.pin_hash),
      pin_locked_until: link.pin_locked_until,
      last_used_at: link.last_used_at,
      inserted_at: link.inserted_at
    }
  end

  # ── 요금 ─────────────────────────────────────────────────

  def plan(plan, revision) do
    %{
      key: plan.key,
      display_name: plan.display_name,
      included_credits: revision && revision.included_credits,
      interval: revision && revision.interval
    }
  end

  def subscription(subscription) do
    %{
      status: subscription.state,
      current_period_start: subscription.current_period_start,
      current_period_end: subscription.current_period_end
    }
  end

  def credit_lot(lot) do
    %{
      id: lot.id,
      source: lot.source,
      amount: lot.amount,
      remaining: lot.remaining,
      expires_at: lot.expires_at,
      inserted_at: lot.inserted_at
    }
  end

  @doc """
  원장 한 줄.

  `pricing_snapshot` 은 그대로 내보낸다 — **자기 사용 내역**이라 숨길 이유가 없고,
  "왜 이만큼 나갔나"를 확인할 유일한 근거다.
  """
  def ledger_entry(entry) do
    %{
      id: entry.id,
      delta: entry.delta,
      source: entry.source,
      reason: entry.reason,
      charge_domain: entry.charge_domain,
      usage_cost_usd: entry.usage_cost_usd && Decimal.to_string(entry.usage_cost_usd),
      pricing_snapshot: entry.pricing_snapshot,
      inserted_at: entry.inserted_at
    }
  end

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(_), do: false

  def account(account) do
    %{
      id: account.id,
      email: account.email,
      name: account.name,
      locale: account.locale,
      theme: account.theme,
      # nil = 자동(브라우저 언어). UI 언어(`locale`)와 다른 값이다.
      transcribe_language: account.transcribe_language,
      confirmed: not is_nil(account.confirmed_at),
      # 링크를 보여줄지 말지에만 쓴다. 접근 판정은 서버가 다시 한다.
      is_admin: account.is_admin
    }
  end
end
