defmodule Mix.Tasks.Vr.MakeAdmin do
  @moduledoc """
  계정에 시스템 어드민 권한을 준다.

      mix vr.make_admin someone@example.com
      mix vr.make_admin someone@example.com --revoke

  어드민 계정은 이 방법으로만 만든다. 화면에서 스스로 승격할 수 없다 —
  어드민 화면이 뚫리면 권한 상승까지 이어지기 때문이다.
  """
  @shortdoc "계정에 어드민 권한을 부여/회수한다"

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, argv, _} = OptionParser.parse(args, switches: [revoke: :boolean])

    case argv do
      [email] -> toggle(email, not (opts[:revoke] || false))
      _ -> Mix.raise("사용법: mix vr.make_admin <이메일> [--revoke]")
    end
  end

  defp toggle(email, grant?) do
    case VR.Accounts.get_account_by_email(email) do
      nil ->
        Mix.raise("계정을 찾을 수 없습니다: #{email}")

      account ->
        {:ok, updated} =
          account
          |> Ecto.Changeset.change(%{is_admin: grant?})
          |> VR.Repo.update()

        if grant? do
          Mix.shell().info("""

          ✅ 어드민 권한을 부여했습니다.

             #{updated.email}  (#{updated.id})

          /_admin 에 접속할 수 있습니다.
          """)
        else
          Mix.shell().info("\n✅ 어드민 권한을 회수했습니다: #{updated.email}\n")
        end
    end
  end
end
