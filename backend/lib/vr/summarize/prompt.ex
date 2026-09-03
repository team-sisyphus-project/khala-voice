defmodule VR.Summarize.Prompt do
  @moduledoc """
  Summary prompt.

  **Origin: sisyphus** — carried over verbatim from the system prompt in the
  n8n `autosquad-meeting-summary.json` workflow. When n8n was removed, only
  the prompt moved down into code.

  ## Why it is this strict

  The core of this product is **clicking a summary item jumps to the point
  in the recording where it was said**. For that to work, the LLM must read
  `source` straight from the label and **never fabricate it**.
  Loosening the "no abbreviating, no translating, empty string if unreadable"
  rules makes quotes drift from the original text, and the jump lands in the
  wrong place.
  """

  @system """
  You are a tool that converts a meeting transcript into a structured summary. You do not invent content.

  ## Input format

  Each line looks like this:

      [<session_id>|<speaker>|<HH:MM:SS>] utterance text

  ## source extraction rules (must be followed)

  - `session_id` = the token between `[` and the first `|`
  - `speaker` = the second token
  - `time_label` = the third token. Copy the `HH:MM:SS` format as-is
  - `quote` = the **full** utterance after `]`. Do not include the label

  Copy `quote` **exactly** as the string appears in the transcript.
  Do not abbreviate. Do not translate. Do not paraphrase. Do not clean it up.
  If a field cannot be read from the label, leave it as an empty string.
  **Never make up content that is not there.**

  ## Criteria for each item

  - `one_liner`: 1-2 conclusion-focused sentences. Not a list of agenda items but **what was decided**
  - `decisions`: confirmed decisions only. If still under discussion, put it in `open_questions`
  - `action_items`: tasks with an action verb. If there is no owner or due date, use an empty string
  - `facts`: objective facts stated in the transcript (numbers, dates, names, metrics)
  - `open_questions`: things raised but not resolved in this meeting
  - `next_steps`: upcoming schedules and milestones not covered by `action_items`
  - `key_topics`: 1-3 word noun phrases. At most 5

  ## Output

  Output JSON only. No explanations, preamble, or code fences.
  Use an empty array when a section has nothing. Do not pad sections to fill them.
  Write the summary in English.
  """

  @doc "System prompt."
  def system, do: @system

  @doc """
  User prompt. Wraps the serialized transcript.

  The meeting title is provided as context only — to keep the model from
  inventing summary content based on the title, we restate "do not write
  anything that is not in the transcript".
  """
  def user(title, transcript_text) do
    """
    Meeting title: #{present(title) || "(none)"}

    Summarize the transcript below. The title is context only. Do not write anything that is not in the transcript.

    ---
    #{transcript_text}
    ---
    """
  end

  @doc """
  Output JSON schema. Providers differ in format, so adapters convert it.

  Locked down with `additionalProperties: false` — if the model invents
  arbitrary fields we would have to filter them in validation; it is cheaper
  to prevent them from existing in the first place.
  """
  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => [
        "one_liner",
        "decisions",
        "action_items",
        "facts",
        "open_questions",
        "next_steps",
        "key_topics"
      ],
      "properties" => %{
        "one_liner" => %{"type" => "string"},
        "decisions" => %{"type" => "array", "items" => sourced_item()},
        "action_items" => %{"type" => "array", "items" => action_item()},
        "facts" => string_array(),
        "open_questions" => string_array(),
        "next_steps" => string_array(),
        "key_topics" => string_array()
      }
    }
  end

  defp sourced_item do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["text", "source"],
      "properties" => %{
        "text" => %{"type" => "string"},
        "source" => source()
      }
    }
  end

  defp action_item do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["who", "what", "due", "source"],
      "properties" => %{
        "who" => %{"type" => "string"},
        "what" => %{"type" => "string"},
        "due" => %{"type" => "string"},
        "source" => source()
      }
    }
  end

  defp source do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["session_id", "speaker", "time_label", "quote"],
      "properties" => %{
        "session_id" => %{"type" => "string"},
        "speaker" => %{"type" => "string"},
        "time_label" => %{"type" => "string"},
        "quote" => %{"type" => "string"}
      }
    }
  end

  defp string_array, do: %{"type" => "array", "items" => %{"type" => "string"}}

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value), do: value
end
