defmodule VR.LogRedactor do
  @moduledoc """
  로그에서 자격증명을 지운다.

  ## 왜 필요한가

  공유 링크 토큰은 **URL 경로에 있다.** Phoenix 는 요청 경로를 `:info` 로 찍으므로
  `GET /api/public/share/slt_xxxxx…` 가 그대로 로그에 남는다. 그 한 줄을 본 사람은
  즉시 그 회의에 들어갈 수 있다 — DB 에 해시만 저장한 이유가 통째로 무효가 된다.

  로그는 파일·수집기·오류 리포터로 흩어지므로 **찍히는 지점마다 막지 않고
  로거 앞단에서 한 번에** 지운다. 우리가 부르는 `Logger` 뿐 아니라 Phoenix ·
  Ecto · 예외 리포트까지 전부 통과한다.

  ## 지우는 것

  | 패턴 | 무엇 |
  |---|---|
  | `slt_…` | 공유 링크 토큰 |
  | `gst_…` | 게스트 세션 토큰 |

  뒤 4자만 남긴다 — 로그에서 "같은 토큰인가"를 판단할 수는 있어야 지원이 가능하다.

  ## 한계

  앱 밖의 접근 로그(리버스 프록시 · CDN · 로드밸런서)는 여기서 못 막는다.
  운영 문서에 그 사실을 적어 둔다.
  """

  @pattern ~r/\b((?:slt|gst)_)([A-Za-z0-9_\-]{8,})/

  @doc "애플리케이션 시작 시 한 번 붙인다."
  def install do
    :logger.add_primary_filter(:vr_redact_tokens, {&__MODULE__.filter/2, []})
  rescue
    # 재시작·핫리로드에서 이미 붙어 있으면 그냥 둔다
    _ -> :ok
  end

  @doc false
  def filter(%{msg: msg} = event, _opts) do
    %{event | msg: redact_msg(msg)}
  rescue
    # 로그를 지우다 로그가 죽으면 안 된다. 실패하면 원본을 그대로 흘린다.
    _ -> event
  end

  def filter(event, _opts), do: event

  @doc "문자열에서 토큰을 가린다. 테스트가 직접 부른다."
  def redact(value) when is_binary(value) do
    Regex.replace(@pattern, value, fn _whole, prefix, body ->
      prefix <> "…" <> String.slice(body, -4, 4)
    end)
  end

  def redact(value), do: value

  # ── 내부 ─────────────────────────────────────────────────

  defp redact_msg({:string, chardata}), do: {:string, redact_chardata(chardata)}

  defp redact_msg({format, args}) when is_list(args) do
    {format, Enum.map(args, &redact_term/1)}
  end

  defp redact_msg({:report, report}), do: {:report, redact_term(report)}
  defp redact_msg(other), do: other

  defp redact_chardata(chardata) do
    chardata |> IO.chardata_to_string() |> redact()
  rescue
    _ -> chardata
  end

  defp redact_term(value) when is_binary(value), do: redact(value)
  defp redact_term(value) when is_list(value), do: Enum.map(value, &redact_term/1)

  defp redact_term(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {k, v} -> {k, redact_term(v)} end)
  end

  defp redact_term({a, b}), do: {redact_term(a), redact_term(b)}
  defp redact_term(value), do: value
end
