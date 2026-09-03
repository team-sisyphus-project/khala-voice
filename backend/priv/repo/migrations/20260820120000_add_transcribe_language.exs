defmodule VR.Repo.Migrations.AddTranscribeLanguage do
  use Ecto.Migration

  @moduledoc """
  Puts the default transcription language on the account.

  `nil` means **auto** — follow the browser language. We do not hard-code a
  string default: the moment we do, "what the user chose" and "what we set for
  them" become indistinguishable, and auto-detection can never be enabled later.

  The microphone does not live here — that setting belongs to the **seat**,
  not the person, so it stays on the device (localStorage).
  """

  def change do
    alter table(:accounts) do
      add :transcribe_language, :string
    end
  end
end
