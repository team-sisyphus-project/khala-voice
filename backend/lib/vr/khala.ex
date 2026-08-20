defmodule VR.Khala do
  @moduledoc """
  칼라 연동 — **우리가 칼라에게 보내는 쪽**.

  반대 방향(외부가 우리 아카이브를 읽는 것)은 `VR.MCP` 다.
  설계는 [`docs/15-mcp-khala.md`](../../docs/15-mcp-khala.md).

  ## 무엇을 보내나

  **요약이 본문이고, 전사 원문이 첨부다. 오디오는 보내지 않는다.**
  목소리 자체가 개인정보라, 회의록을 공유하는 것과 음성 파일을 남의 인박스에
  넣는 것은 다른 일이다. 음성이 필요하면 공유 링크를 쓴다 — 그쪽은 만료·PIN·
  역할이 걸려 있고 언제든 끊을 수 있다.
  """

  import Ecto.Query

  require Logger

  alias VR.Khala.{Connection, MCPClient, OAuth}
  alias VR.Meetings
  alias VR.Meetings.{Export, Meeting}
  alias VR.Repo

  # 칼라 인라인 첨부 한도. 넘으면 첨부를 빼고 본문만 보낸다.
  @max_attachment_bytes 5 * 1024 * 1024

  # ── 연결 ────────────────────────────────────────────────

  @doc "이 계정의 살아 있는 연결. 없으면 nil."
  def connection(account_id) when is_binary(account_id) do
    Repo.one(
      from c in Connection,
        where: c.account_id == ^account_id and is_nil(c.revoked_at)
    )
  end

  def connection(_), do: nil

  def connected?(account_id), do: not is_nil(connection(account_id))

  @doc "연결을 저장한다. 이미 있으면 끊고 새로 만든다 — 계정당 하나다."
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

  @doc "연결을 끊는다. 행은 남긴다 — 언제 끊었는지가 기록이다."
  def disconnect(account_id) do
    case connection(account_id) do
      nil -> {:error, :not_connected}
      connection -> connection |> Connection.revoke_changeset() |> Repo.update()
    end
  end

  # ── 토큰 ────────────────────────────────────────────────

  @doc """
  쓸 수 있는 액세스 토큰. 만료가 가까우면 갱신한다.

  **만료 1분 전부터 갱신한다.** 정확히 만료 시각에 맞추면 요청이 날아가는 사이에
  만료돼 실패한다.
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
        # 칼라가 거절했다. 다시 연결해야 한다 — 재시도해도 같은 답이 온다.
        {:error, :reconnect_required}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── 도구 호출 ────────────────────────────────────────────

  defp call(account_id, tool, args) do
    with %Connection{} = connection <- connection(account_id),
         {:ok, token, connection} <- access_token(connection),
         url when is_binary(url) <- OAuth.mcp_url() do
      case MCPClient.call_tool(url, token, tool, args) do
        {:ok, result} ->
          {:ok, result, connection}

        {:error, :unauthorized} ->
          # 갱신했는데도 401 이면 토큰이 죽은 것이다
          {:error, :reconnect_required}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_connected}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "내 칼라 인박스 목록. 보낼 곳을 고르는 데 쓴다."
  def list_inboxes(account_id) do
    case call(account_id, "khala_list_inboxes", %{"target" => "mine", "limit" => 50}) do
      {:ok, result, _} -> {:ok, inboxes_from(MCPClient.json_of(result))}
      {:error, reason} -> {:error, reason}
    end
  end

  # 칼라 응답 모양이 버전마다 조금씩 다르다. 흔한 자리를 훑는다 —
  # 하나만 보고 쓰면 칼라가 감싸는 키를 바꾸는 날 빈 목록이 된다.
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
  칼라에 우리 인박스를 만든다. 이미 있으면 그대로 쓴다.

  보내는 쪽(`sender_inbox_code`)이 이것이다 — 받는 사람이 "이건 칼라보이스가
  보낸 것"임을 알 수 있어야 한다.
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
          "tagline" => "회의 녹음·전사·요약",
          "description" => """
          KHALA VOICE 가 보내는 회의록입니다.
          본문은 요약이고, 전사 원문은 마크다운으로 첨부됩니다.
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

  # ── 보내기 ──────────────────────────────────────────────

  @doc """
  회의를 칼라 인박스로 보낸다.

  `attach_transcript: false` 면 요약만 보낸다.
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

      # 한도를 넘으면 첨부를 뺀다. 본문(요약)은 그대로 간다 —
      # 첨부 하나 때문에 발송 자체가 실패하는 편이 더 나쁘다.
      if byte_size(markdown) <= @max_attachment_bytes do
        %{
          "filename" => Export.filename(meeting),
          "mime" => "text/markdown",
          "base64" => Base.encode64(markdown)
        }
      else
        Logger.warning("[Khala] 전사가 너무 커서 첨부를 뺀다: #{meeting.id}")
        nil
      end
    end
  end

  @doc false
  # 본문 = 요약. 받는 쪽이 열자마자 무슨 회의였는지 알아야 한다.
  def body_for(%Meeting{} = meeting, app_url) do
    data = meeting.summary_data || %{}

    [
      "# #{meeting.title || "제목 없는 회의"}",
      "",
      data["one_liner"],
      section("결정사항", data["decisions"]),
      section("할 일", data["action_items"]),
      section("열린 질문", data["open_questions"]),
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
  defp link_line(meeting, base), do: "\n[회의 열기](#{base}/go/meetings/#{meeting.id})"
end
