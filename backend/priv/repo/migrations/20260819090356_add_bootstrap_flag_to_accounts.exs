defmodule VR.Repo.Migrations.AddBootstrapFlagToAccounts do
  use Ecto.Migration

  @moduledoc """
  초기 부트스트랩 어드민 표시.

  설치 직후에는 어드민이 아무도 없어 `/_admin` 에 들어갈 수 없다.
  그래서 계정을 하나 자동으로 만든다. 이 계정은 **입구를 여는 임시 열쇠**이고,
  실사용자를 어드민으로 승격한 뒤에는 지워서 입구를 닫는 것이 정상 절차다.

  플래그를 두는 이유: 어드민 화면에서 "이건 임시 계정이니 지우라"고
  명확히 안내하기 위해서다. 표시가 없으면 그냥 남아서 영구 백도어가 된다.
  """

  def change do
    alter table(:accounts) do
      add :is_bootstrap, :boolean, null: false, default: false
    end

    create index(:accounts, [:is_admin], where: "is_admin = true")
  end
end
