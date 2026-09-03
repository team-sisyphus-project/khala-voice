defmodule VRWeb.API.JSONView do
  @moduledoc """
  API response serialization.

  ## Masking rules

  Viewers never receive `audio_url`. Hiding the button in the UI is not enough —
  they could simply call the API directly. **The server strips it.**
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
      # Used by the client to render the UI. The server has already made the access decision.
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
          # Include names and colors. Hiding taxonomy names from someone who can
          # already read the full meeting transcript is not defense — it only breaks the UI.
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

    # Viewers cannot access the original audio.
    #
    # **We do not send a URL.** The storage key is fully determined by
    # `meeting_id`, `session_id`, `started_at_unix`, and the file extension — and all
    # of those values are in this response. Merely omitting the field would let someone
    # assemble the URL by hand and fetch the original, so we only expose the endpoint
    # that redirects to a signed URL.
    if AccessLevel.at_least?(level, :lv1) and present?(session.storage_key) do
      Map.put(base, :audio_href, "/api/sessions/#{session.id}/audio")
    else
      base
    end
  end

  # Match the count-carrying shape first — reversing the order would drop the count
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
  Share link. **Never include `token_hash`, `pin_hash`, the plaintext token, or the plaintext PIN.**

  `token_prefix` exists only to identify a link in a list; it cannot be used to get in.
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

  # ── Billing ─────────────────────────────────────────────

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
  A single ledger line.

  `pricing_snapshot` is exported as-is — it is **the account's own usage history**,
  so there is nothing to hide, and it is the only evidence for answering
  "why was I charged this much?".
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
      # nil = automatic (browser language). Distinct from the UI language (`locale`).
      transcribe_language: account.transcribe_language,
      confirmed: not is_nil(account.confirmed_at),
      # Used only to decide whether to show the link. The server re-checks access.
      is_admin: account.is_admin
    }
  end
end
