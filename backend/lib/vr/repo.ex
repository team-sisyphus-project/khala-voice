defmodule VR.Repo do
  use Ecto.Repo,
    otp_app: :vr,
    adapter: Ecto.Adapters.Postgres
end
