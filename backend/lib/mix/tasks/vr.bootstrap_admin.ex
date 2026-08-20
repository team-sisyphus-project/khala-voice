defmodule Mix.Tasks.Vr.BootstrapAdmin do
  @moduledoc """
  초기 어드민 계정을 만든다.

      mix vr.bootstrap_admin
      mix vr.bootstrap_admin --email you@example.com

  설치 직후에는 어드민이 없어 `/_admin` 에 들어갈 수 없다.
  이 명령이 입구를 여는 임시 열쇠를 만든다.

  **이미 어드민이 있으면 아무것도 하지 않는다.** 여러 번 실행해도 안전하다.

  ## 비밀번호

  `BOOTSTRAP_ADMIN_PASSWORD` 환경변수를 쓰고, 없으면 무작위로 만들어
  **화면에 한 번만** 보여준다. 해시로만 저장하므로 나중에 조회할 수 없다.

  ## 다 쓰고 나서

  실사용자로 가입한 뒤 어드민 화면에서 그 계정을 승격하고,
  **이 임시 계정을 삭제해 입구를 닫는다.** 남겨두면 영구 백도어가 된다.
  """
  @shortdoc "초기 어드민 계정을 만든다"

  use Mix.Task

  alias VR.Accounts.Admin

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    Logger.configure(level: :warning)
    {opts, _, _} = OptionParser.parse(args, switches: [email: :string, password: :string])

    case Admin.ensure_bootstrap_admin(opts) do
      {:ok, account, password} ->
        Mix.shell().info("""

        ┌──────────────────────────────────────────────────────────┐
          초기 어드민 계정을 만들었습니다

            이메일    #{account.email}
            비밀번호  #{password}

          이 비밀번호는 지금만 볼 수 있습니다. 저장해 두세요.
        └──────────────────────────────────────────────────────────┘

        다음 순서로 진행하세요.

          1. 이 계정으로 로그인 → /_admin 접속
          2. 본인 계정으로 따로 가입
          3. 어드민 → 계정 에서 본인 계정을 어드민으로 승격
          4. **이 임시 계정을 삭제** — 입구를 닫습니다

        4번을 하지 않으면 영구 백도어가 남습니다.
        """)

      {:error, :admin_exists} ->
        admins = Admin.list_accounts(only: :admins)

        Mix.shell().info("""

        이미 어드민이 있습니다. 새로 만들지 않았습니다.

        #{Enum.map_join(admins, "\n", fn a -> "  · #{a.email}#{if a.is_bootstrap, do: "  (임시 계정 — 삭제 권장)", else: ""}" end)}

        권한을 더 주려면:  mix vr.make_admin <이메일>
        """)

      {:error, :email_required} ->
        Mix.raise("""
        이메일이 필요합니다. 기본 주소를 두지 않습니다 —
        모든 배포본이 같은 주소를 쓰면 그 자체가 공격 대상이 됩니다.

            mix vr.bootstrap_admin --email you@example.com

        또는 BOOTSTRAP_ADMIN_EMAIL 환경변수를 설정하세요.
        """)

      {:error, changeset} ->
        errors =
          changeset
          |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
          |> Enum.map_join("; ", fn {k, v} -> "#{k}: #{Enum.join(v, ", ")}" end)

        Mix.raise("계정을 만들지 못했습니다 — #{errors}")
    end
  end
end
