defmodule VR.Release.Rejection do
  @moduledoc """
  Reads a rejected seed write and answers one question: is that row simply
  already there?

  Every seed step asks "is it there?" and then writes. Two deploys running the
  preparation step at the same time — or one re-run after another died
  mid-step — both get *no* to that question and both write, and the second
  write loses on a unique index. That loss is not a failure: it is the same
  answer the check asked for, arriving a moment later.

  **Only that one rejection is forgiven.** A check constraint, a bad format, a
  missing required value — those are the seed being wrong, and they stay loud.
  A conversion policy silently missing is transcription running unmetered.

  Every entry point that seeds shares this reading, because a rejection that
  one of them calls "already there" and another calls a failed deploy is the
  same database row either way.
  """

  @doc """
  The clause that separates a row created a moment ago from one that was
  already there before this run started.

  Appended rather than reworded: an operator greps a deploy log for
  `already exists`, and writing the two cases as two sentences drops one of
  them out of that search.
  """
  @spec concurrently() :: String.t()
  def concurrently, do: " — created by a concurrent run."

  @doc """
  Whether `changeset` was rejected only because the row is already there.

  It arrives in two shapes, and which one depends only on where the other
  deploy's row landed. After the changeset's own lookup for the same index
  (`unsafe_validate_unique/3`), the index rejects the write —
  `constraint: :unique`. Before it, that lookup finds the row and says so
  itself — `validation: :unsafe_unique`. One fact, two reporters: handling
  only one of them leaves code that survives half of the window.
  """
  @spec already_there?(Ecto.Changeset.t()) :: boolean()
  def already_there?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, opts}} ->
      opts[:constraint] == :unique or opts[:validation] == :unsafe_unique
    end)
  end

  # A `label + value` block puts its values in column 14. A second rejected
  # field continues under the first rather than after it: the two of them on
  # one line pass 80 columns, and a line that wraps in a terminal is a line
  # nobody reads.
  @continuation "\n" <> String.duplicate(" ", 14)

  @doc """
  The rejected fields as `field: reason` — what follows `rejected` in a
  failure message's diagnostic block, one field per line.
  """
  @spec errors(Ecto.Changeset.t()) :: String.t()
  def errors(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join(@continuation, fn {field, messages} ->
      "#{field}: #{Enum.join(messages, ", ")}"
    end)
  end
end
