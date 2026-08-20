defmodule VR.Repo.Migrations.DefaultThemeDark do
  use Ecto.Migration

  @moduledoc """
  기본 테마를 다크로 바꾼다.

  **기본값만 바꾼다.** 이미 라이트를 쓰고 있던 계정의 값은 건드리지 않는다 —
  사용자가 고른 것과 기본값을 구분할 수 없어지면 되돌릴 방법이 없다.
  """

  def up do
    alter table(:accounts) do
      modify :theme, :string, null: false, default: "dark"
    end
  end

  def down do
    alter table(:accounts) do
      modify :theme, :string, null: false, default: "light"
    end
  end
end
