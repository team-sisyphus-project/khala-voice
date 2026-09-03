defmodule VR.Repo.Migrations.AddStorageKeyToSessions do
  use Ecto.Migration

  @moduledoc """
  The **server** now chooses and records the upload target key.

  Until now the client finished uploading, sent `audio_url`, and we trusted it
  as-is. That value flows into the worker's `Req.get/2`, so an authenticated
  user could point it at a private-network address and make the server issue
  requests on their behalf (SSRF).

  Now the server picks the key at presign time and records it here; playback
  and transcription both access only through this key. Client-supplied URLs
  are never used.
  """

  def change do
    alter table(:recording_sessions) do
      add :storage_key, :string
    end
  end
end
