defmodule VR.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use VR.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias VR.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import VR.DataCase
      # 워커를 직접 실행해 검증한다 — 큐를 돌리지 않고 로직만 본다
      use Oban.Testing, repo: VR.Repo
    end
  end

  setup tags do
    VR.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  presign 을 거친 세션처럼 저장 키를 박는다.

  `register_upload/2` 는 `audio_url` 을 클라이언트에서 받지 않고
  `storage_key` 에서 서버가 만든다. 실제 흐름에서는 presign 이 키를 정한다.
  """
  def with_storage_key(session, ext \\ "webm") do
    key =
      VR.Storage.recording_key(session.meeting_id, session.id, session.started_at_unix, ext)

    {:ok, session} = VR.Meetings.set_storage_key(session, key)
    session
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(VR.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
