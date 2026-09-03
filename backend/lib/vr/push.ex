defmodule VR.Push do
  @moduledoc """
  Web push notifications.

  Transcription and summarization take minutes. Even after the user closes the
  screen, they need to be told it finished so they come back to check.

  ## Notifications are a supplementary feature

  A failure **never fails the job.** Rolling back a finished transcription
  because a notification could not be sent is the bigger loss. Every failure is
  only logged.

  ## The body carries no meeting content

  The push payload is encrypted, but it shows up verbatim on the lock screen.
  A title is one thing; a transcript or summary appearing on screen is another.
  We send no more than "Transcription is complete".
  """

  import Ecto.Query, warn: false

  alias VR.Config
  alias VR.Push.Subscription
  alias VR.Repo

  require Logger

  # After this many consecutive failures, treat the subscription as dead
  @max_failures 5

  @doc "Whether push can be sent in this environment. Used by the admin dashboard."
  def ready?, do: not is_nil(public_key()) and not is_nil(private_key())

  @doc "The public key the browser needs when subscribing."
  def public_key, do: present(Config.fetch("push.vapid_public_key"))

  @doc "The account's subscription list."
  def list_subscriptions(account_id) do
    Repo.all(from s in Subscription, where: s.account_id == ^account_id)
  end

  @doc """
  Register a subscription. When the same device registers again, it is updated.

  The browser hands back the same `endpoint`, so creating a new row would send duplicate notifications.
  """
  def subscribe(account_id, attrs) do
    endpoint = attrs["endpoint"] || attrs[:endpoint]

    existing = endpoint && Repo.get_by(Subscription, endpoint: endpoint)

    (existing || %Subscription{})
    |> Subscription.changeset(account_id, attrs)
    |> Ecto.Changeset.put_change(:failed_count, 0)
    |> Repo.insert_or_update()
  end

  @doc "Delete a subscription. For when the browser has unsubscribed."
  def unsubscribe(account_id, endpoint) do
    {count, _} =
      Repo.delete_all(
        from s in Subscription,
          where: s.account_id == ^account_id and s.endpoint == ^endpoint
      )

    {:ok, count}
  end

  @doc """
  Notify every device on the account.

  ## Options
  - `:url` — where tapping the notification goes
  - `:tag` — notifications with the same tag replace each other (so alerts for the same meeting do not pile up)
  """
  def notify(account_id, title, body, opts \\ []) do
    if ready?() do
      payload =
        Jason.encode!(%{
          "title" => title,
          "body" => body,
          "url" => opts[:url] || "/go/meetings",
          "tag" => opts[:tag] || "vr"
        })

      account_id
      |> list_subscriptions()
      |> Enum.each(&deliver(&1, payload))
    end

    :ok
  end

  # ── Internal ─────────────────────────────────────────────

  defp deliver(%Subscription{} = subscription, payload) do
    configure_vapid()

    case WebPushElixir.send_notification(Subscription.to_push_json(subscription), payload) do
      {:ok, _} ->
        touch(subscription)

      # The browser discarded the subscription. No reason to send again.
      {:error, :expired} ->
        Repo.delete(subscription)

      {:error, reason} ->
        Logger.warning("[Push] delivery failed: #{inspect(reason)}")
        bump_failure(subscription)
    end
  rescue
    error ->
      # A notification must never take down the caller
      Logger.warning("[Push] exception during delivery: #{inspect(error)}")
      bump_failure(subscription)
  end

  # The library reads the keys from the application environment. Our config
  # resolves DB→ENV, so we copy them over right before sending. The keys are
  # effectively fixed, so contention is not an issue.
  defp configure_vapid do
    Application.put_env(:web_push_elixir, :vapid_public_key, public_key())
    Application.put_env(:web_push_elixir, :vapid_private_key, private_key())
    Application.put_env(:web_push_elixir, :vapid_subject, subject())
  end

  defp touch(%Subscription{} = subscription) do
    Repo.update_all(
      from(s in Subscription, where: s.id == ^subscription.id),
      set: [last_used_at: DateTime.utc_now(:second), failed_count: 0]
    )
  end

  defp bump_failure(%Subscription{} = subscription) do
    if subscription.failed_count + 1 >= @max_failures do
      Repo.delete(subscription)
    else
      Repo.update_all(from(s in Subscription, where: s.id == ^subscription.id),
        inc: [failed_count: 1]
      )
    end
  end

  defp private_key, do: present(Config.fetch("push.vapid_private_key"))

  defp subject do
    present(Config.fetch("push.vapid_subject")) || "mailto:admin@example.com"
  end

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value), do: value
end
