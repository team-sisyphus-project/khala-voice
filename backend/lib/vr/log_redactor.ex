defmodule VR.LogRedactor do
  @moduledoc """
  Scrubs credentials from logs.

  ## Why this is needed

  Share link tokens live **in the URL path.** Phoenix logs the request path at
  `:info`, so `GET /api/public/share/slt_xxxxx…` lands in the log verbatim.
  Anyone who sees that one line can immediately enter that meeting — voiding
  the entire point of storing only hashes in the DB.

  Logs scatter across files, collectors, and error reporters, so instead of
  guarding every logging site, we scrub **once, in front of the logger.** Not
  just our own `Logger` calls — Phoenix, Ecto, and exception reports all pass
  through it too.

  ## What gets scrubbed

  | Pattern | What |
  |---|---|
  | `slt_…` | Share link tokens |
  | `gst_…` | Guest session tokens |

  Only the last 4 characters are kept — support work still needs to tell
  "is this the same token" from the logs.

  ## Limitations

  Access logs outside the app (reverse proxy, CDN, load balancer) cannot be
  stopped here. The operations docs note this fact.
  """

  @pattern ~r/\b((?:slt|gst)_)([A-Za-z0-9_\-]{8,})/

  @doc "Attached once at application start."
  def install do
    :logger.add_primary_filter(:vr_redact_tokens, {&__MODULE__.filter/2, []})
  rescue
    # Leave it alone if already attached after a restart or hot reload
    _ -> :ok
  end

  @doc false
  def filter(%{msg: msg} = event, _opts) do
    %{event | msg: redact_msg(msg)}
  rescue
    # Scrubbing must never kill logging. On failure, pass the original through.
    _ -> event
  end

  def filter(event, _opts), do: event

  @doc "Masks tokens in a string. Called directly by tests."
  def redact(value) when is_binary(value) do
    Regex.replace(@pattern, value, fn _whole, prefix, body ->
      prefix <> "…" <> String.slice(body, -4, 4)
    end)
  end

  def redact(value), do: value

  # ── Internal ─────────────────────────────────────────────

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
