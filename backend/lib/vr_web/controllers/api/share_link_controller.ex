defmodule VRWeb.API.ShareLinkController do
  @moduledoc """
  Share link management. **Reviewer only.**

  sisyphus (a) opened this to lv0 or lv1, and (b) let any project member read
  plaintext tokens and PINs and kill other people's links
  (`shared_link_controller.ex` `authorized_for_link?`). In this app it is
  exactly one person: **the meeting's Reviewer**.

  ## Plaintext goes out only once

  Plaintext appears only in the responses of issuance (`create`), rotation
  (`rotate`), and PIN enablement (`set_pincode`). After that, `index` carries
  only `token_prefix` and `has_pincode`. The DB stores only hashes, so a lost
  token can only be reissued.
  """

  use VRWeb, :controller

  alias VR.{Meetings, Sharing}
  alias VR.Sharing.SharedLink
  alias VRWeb.API.JSONView

  action_fallback VRWeb.API.FallbackController

  def index(conn, %{"meeting_id" => meeting_id}) do
    account = conn.assigns.current_account

    with {:ok, meeting, _level} <- Meetings.authorize(meeting_id, account, :lv0) do
      json(conn, %{share_links: Enum.map(Sharing.list_links(meeting.id), &JSONView.shared_link/1)})
    end
  end

  def create(conn, %{"meeting_id" => meeting_id} = params) do
    account = conn.assigns.current_account

    attrs =
      Map.take(
        params,
        ~w(granted_role max_uses expires_at require_name require_email with_pincode)
      )

    with {:ok, meeting, _level} <- Meetings.authorize(meeting_id, account, :lv0),
         {:ok, link, token, pincode} <- Sharing.issue_link(meeting, account, attrs) do
      conn
      |> put_status(:created)
      |> json(
        JSONView.shared_link(link)
        # Included in this response only
        |> Map.put(:url, Sharing.link_url(token))
        |> Map.put(:pincode, pincode)
      )
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, link} <- authorize_link(conn, id),
         {:ok, updated} <-
           Sharing.update_link(
             link,
             Map.take(params, ~w(is_active max_uses expires_at require_name require_email))
           ) do
      json(conn, JSONView.shared_link(updated))
    end
  end

  @doc "For when the URL is lost. Keeps the settings and use count; only the token is regenerated."
  def rotate(conn, %{"id" => id}) do
    with {:ok, link} <- authorize_link(conn, id),
         {:ok, updated, token} <- Sharing.rotate_token(link) do
      json(conn, Map.put(JSONView.shared_link(updated), :url, Sharing.link_url(token)))
    end
  end

  def set_pincode(conn, %{"id" => id} = params) do
    mode = if params["enabled"] in [true, "true"], do: :on, else: :off

    with {:ok, link} <- authorize_link(conn, id),
         {:ok, updated, pincode} <- Sharing.set_pincode(link, mode) do
      json(conn, Map.put(JSONView.shared_link(updated), :pincode, pincode))
    end
  end

  @doc "Revoke. **Guests currently inside via this link are disconnected too.**"
  def delete(conn, %{"id" => id}) do
    with {:ok, link} <- authorize_link(conn, id),
         {:ok, _} <- Sharing.revoke_link(link) do
      send_resp(conn, :no_content, "")
    end
  end

  # ── Internal ────────────────────────────────────────────

  # Looks up the meeting via the link id and checks whether the caller is that
  # meeting's Reviewer. Whether the link is missing or permission is missing,
  # **the response is identically 404.**
  defp authorize_link(conn, id) do
    account = conn.assigns.current_account

    with %SharedLink{} = link <- Sharing.get_link(id),
         {:ok, _meeting, _level} <- Meetings.authorize(link.meeting_id, account, :lv0) do
      {:ok, link}
    else
      _ -> {:error, :not_found}
    end
  end
end
