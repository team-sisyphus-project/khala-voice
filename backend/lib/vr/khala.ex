defmodule VR.Khala do
  @moduledoc """
  Khala integration — **the side where we send to Khala**.

  The opposite direction (external parties reading our archive) is `VR.MCP`.
  Design notes: [`docs/15-mcp-khala.md`](../../docs/15-mcp-khala.md).

  ## What we send

  **The summary is the body; the full transcript is an attachment. We never send audio.**
  A voice is itself personal data — sharing meeting notes is not the same as
  dropping an audio file into someone else's inbox. If audio is needed, use a
  share link — that path has expiry, PIN, and roles, and can be cut off anytime.
  """

  import Ecto.Query

  require Logger

  alias VR.Khala.{Connection, MCPClient, OAuth}
  alias VR.Meetings
  alias VR.Meetings.{Export, Meeting}
  alias VR.Repo

  # Khala's inline attachment limit. When exceeded, drop the attachment and send the body only.
  @max_attachment_bytes 5 * 1024 * 1024

  # ── Connection ──────────────────────────────────────────

  @doc "The live connection for this account. nil if none."
  def connection(account_id) when is_binary(account_id) do
    Repo.one(
      from c in Connection,
        where: c.account_id == ^account_id and is_nil(c.revoked_at)
    )
  end

  def connection(_), do: nil

  def connected?(account_id), do: not is_nil(connection(account_id))

  @doc "Store a connection. If one already exists, revoke it and create a new one — one per account."
  def connect(account_id, client_id, tokens) do
    Repo.transaction(fn ->
      if existing = connection(account_id) do
        {:ok, _} = existing |> Connection.revoke_changeset() |> Repo.update()
      end

      account_id
      |> Connection.build(%{
        client_id: client_id,
        access_token: tokens.access_token,
        refresh_token: tokens.refresh_token,
        expires_at: tokens.expires_at
      })
      |> Repo.insert()
      |> case do
        {:ok, connection} -> connection
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc "Revoke the connection. The row is kept — when it was revoked is part of the record."
  def disconnect(account_id) do
    case connection(account_id) do
      nil -> {:error, :not_connected}
      connection -> connection |> Connection.revoke_changeset() |> Repo.update()
    end
  end

  # ── Tokens ──────────────────────────────────────────────

  @doc """
  A usable access token. Refreshes when expiry is near.

  **We refresh starting one minute before expiry.** Cutting it to the exact
  expiry moment means the token can expire mid-flight and the request fails.
  """
  def access_token(%Connection{} = connection) do
    if fresh?(connection) do
      {:ok, connection.access_token, connection}
    else
      refresh(connection)
    end
  end

  defp fresh?(%Connection{expires_at: nil}), do: true

  defp fresh?(%Connection{expires_at: at}),
    do: DateTime.compare(at, DateTime.utc_now() |> DateTime.add(60, :second)) == :gt

  defp refresh(%Connection{refresh_token: nil}), do: {:error, :reconnect_required}

  defp refresh(%Connection{} = connection) do
    with {:ok, meta} <- OAuth.discover(),
         {:ok, tokens} <- OAuth.refresh(meta, connection.client_id, connection.refresh_token),
         {:ok, updated} <-
           connection
           |> Connection.refresh_changeset(%{
             access_token: tokens.access_token,
             refresh_token: tokens.refresh_token || connection.refresh_token,
             expires_at: tokens.expires_at
           })
           |> Repo.update() do
      {:ok, updated.access_token, updated}
    else
      {:error, {:token_failed, status}} when status in [400, 401] ->
        # Khala rejected it. Reconnection is required — retrying gets the same answer.
        {:error, :reconnect_required}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Tool calls ──────────────────────────────────────────

  defp call(account_id, tool, args) do
    with %Connection{} = connection <- connection(account_id),
         {:ok, token, connection} <- access_token(connection),
         url when is_binary(url) <- OAuth.mcp_url() do
      case MCPClient.call_tool(url, token, tool, args) do
        {:ok, result} ->
          {:ok, result, connection}

        {:error, :unauthorized} ->
          # A 401 even after refreshing means the token is dead
          {:error, :reconnect_required}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_connected}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "List my Khala inboxes. Used to pick a destination."
  def list_inboxes(account_id) do
    case call(account_id, "khala_list_inboxes", %{"target" => "mine", "limit" => 50}) do
      {:ok, result, _} -> {:ok, inboxes_from(MCPClient.json_of(result))}
      {:error, reason} -> {:error, reason}
    end
  end

  # The shape of Khala responses varies slightly between versions. We scan the
  # common spots — relying on just one means an empty list the day Khala
  # changes its wrapper key.
  defp inboxes_from(%{"inboxes" => list}) when is_list(list), do: Enum.map(list, &inbox/1)
  defp inboxes_from(%{"items" => list}) when is_list(list), do: Enum.map(list, &inbox/1)
  defp inboxes_from(%{"data" => data}), do: inboxes_from(data)
  defp inboxes_from(list) when is_list(list), do: Enum.map(list, &inbox/1)
  defp inboxes_from(_), do: []

  defp inbox(item) when is_map(item) do
    %{
      code: item["inbox_code"] || item["code"] || item["id"],
      name: item["name"] || item["inbox_name"] || item["title"],
      tagline: item["tagline"] || item["description"]
    }
  end

  defp inbox(_), do: %{code: nil, name: nil, tagline: nil}

  @doc """
  Create our inbox on Khala. If it already exists, reuse it.

  This is the sender side (`sender_inbox_code`) — recipients must be able to
  tell "this was sent by KHALA VOICE".
  """
  def ensure_inbox(account_id) do
    case connection(account_id) do
      nil ->
        {:error, :not_connected}

      %Connection{inbox_code: code} = connection when is_binary(code) ->
        {:ok, code, connection}

      %Connection{} = connection ->
        args = %{
          "name" => "khala-voice",
          "tagline" => "Meeting recording, transcription, and summaries",
          "description" => """
          Meeting notes sent by KHALA VOICE.
          The body is the summary; the full transcript is attached as Markdown.
          """
        }

        case call(account_id, "khala_register_inbox", args) do
          {:ok, result, _} ->
            data = MCPClient.json_of(result)
            code = inbox_code_from(data)

            if is_binary(code) do
              {:ok, updated} =
                connection
                |> Connection.inbox_changeset(code, "khala-voice")
                |> Repo.update()

              {:ok, code, updated}
            else
              {:error, :no_inbox_code}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp inbox_code_from(%{"inbox_code" => code}) when is_binary(code), do: code
  defp inbox_code_from(%{"my_inbox_code" => code}) when is_binary(code), do: code
  defp inbox_code_from(%{"inbox" => inner}) when is_map(inner), do: inbox_code_from(inner)
  defp inbox_code_from(%{"data" => inner}) when is_map(inner), do: inbox_code_from(inner)
  defp inbox_code_from(_), do: nil

  # ── Sending ─────────────────────────────────────────────

  @doc """
  Send a meeting to a Khala inbox.

  With `attach_transcript: false`, only the summary is sent.
  """
  def send_meeting(account_id, %Meeting{} = meeting, recipient, opts \\ []) do
    attach? = Keyword.get(opts, :attach_transcript, true)

    with {:ok, sender, _} <- ensure_inbox(account_id) do
      sessions = Meetings.list_sessions(meeting.id)
      body = body_for(meeting, opts[:app_url])

      case attachment(meeting, sessions, attach?) do
        nil ->
          call(account_id, "khala_send", %{
            "sender_inbox_code" => sender,
            "recipient_inbox_code" => recipient,
            "body" => body
          })

        file ->
          call(account_id, "khala_send_attachment", %{
            "sender_inbox_code" => sender,
            "recipient_inbox_code" => recipient,
            "body" => body,
            "files" => [file]
          })
      end
      |> case do
        {:ok, _result, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp attachment(_meeting, _sessions, false), do: nil

  defp attachment(meeting, sessions, true) do
    if Export.exportable?(meeting, sessions) do
      markdown = Export.to_markdown(meeting, sessions)

      # Over the limit, drop the attachment. The body (summary) still goes —
      # failing the entire send over one attachment is worse.
      if byte_size(markdown) <= @max_attachment_bytes do
        %{
          "filename" => Export.filename(meeting),
          "mime" => "text/markdown",
          "base64" => Base.encode64(markdown)
        }
      else
        Logger.warning("[Khala] transcript too large, dropping attachment: #{meeting.id}")
        nil
      end
    end
  end

  @doc false
  # Body = summary. The recipient should know what the meeting was about the moment they open it.
  def body_for(%Meeting{} = meeting, app_url) do
    data = meeting.summary_data || %{}

    [
      "# #{meeting.title || "Untitled Meeting"}",
      "",
      data["one_liner"],
      section("Decisions", data["decisions"]),
      section("Action Items", data["action_items"]),
      section("Open Questions", data["open_questions"]),
      link_line(meeting, app_url),
      "",
      "— KHALA VOICE"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp section(_title, nil), do: nil
  defp section(_title, []), do: nil

  defp section(title, items) when is_list(items) do
    lines =
      items
      |> Enum.map(&item_text/1)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.map(&"- #{&1}")

    if lines == [], do: nil, else: "\n## #{title}\n" <> Enum.join(lines, "\n")
  end

  defp item_text(%{"text" => text}) when is_binary(text), do: text

  defp item_text(%{"what" => what} = item) when is_binary(what) do
    who = item["who"]
    due = item["due"]

    [who && "#{who}: ", what, due && " (#{due})"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join()
  end

  defp item_text(text) when is_binary(text), do: text
  defp item_text(_), do: nil

  defp link_line(_meeting, nil), do: nil
  defp link_line(meeting, base), do: "\n[Open meeting](#{base}/go/meetings/#{meeting.id})"
end
