# Seeds for development and first-time installs.
#
#     mix run priv/repo/seeds.exs
#
# `mix ecto.setup` runs this automatically. Safe to run multiple times.
#
# **Never seed the test DB.** Tests assume an empty DB and create their own data.
# If `MIX_ENV=test mix ecto.reset` ran the seeds too, the free plan would be
# duplicated and the billing tests would break wholesale.

if Mix.env() == :test do
  IO.puts("[seeds] not seeding in the test environment")
  System.halt(0)
end

alias VR.Accounts.Admin
alias VR.Billing
alias VR.Billing.Credits

# ── Bootstrap admin ────────────────────────────────────────
case Admin.ensure_bootstrap_admin() do
  {:ok, account, password} ->
    IO.puts("""

    ┌──────────────────────────────────────────────────────────┐
      Created the initial admin account

        Email     #{account.email}
        Password  #{password}

      This password is only shown right now. Save it somewhere.
      Delete this account after promoting a real user to admin.
    └──────────────────────────────────────────────────────────┘
    """)

  {:error, :admin_exists} ->
    IO.puts("[seeds] an admin already exists. Skipping.")

  {:error, :email_required} ->
    IO.puts("""
    [seeds] skipping the initial admin — BOOTSTRAP_ADMIN_EMAIL is not set.

      BOOTSTRAP_ADMIN_EMAIL=you@example.com mix run priv/repo/seeds.exs
      or  mix vr.bootstrap_admin --email you@example.com
    """)

  {:error, _changeset} ->
    IO.puts("[seeds] could not create the initial admin. Try mix vr.bootstrap_admin.")
end

# ── Credit conversion policy ───────────────────────────────
#
# 1 credit = $N. Changed from the admin UI.
# The default follows devkanban's reference value (≈ $0.0015, Cookie Crate basis).
# Without this value usage cannot be converted into credits, so transcription
# and summarization would go unmetered.
if is_nil(Credits.conversion_setting()) do
  {:ok, setting} = Credits.put_conversion_setting(%{credit_value_usd: Decimal.new("0.0015")})
  IO.puts("[seeds] created credit conversion policy — 1 credit = $#{setting.credit_value_usd}")
else
  IO.puts("[seeds] credit conversion policy already exists.")
end

# ── Free plan ──────────────────────────────────────────────
#
# Every signup is subscribed to this automatically. Included credits are
# changed from the admin UI (changing them publishes a new revision —
# existing subscriptions are grandfathered).
case Billing.get_plan_by_key(Billing.free_plan_key()) do
  nil ->
    {:ok, plan} =
      Billing.create_plan(%{
        key: Billing.free_plan_key(),
        display_name: "Free",
        description: "Record meetings, then transcribe and summarize them.",
        status: "published",
        publicly_listed: true,
        sort_order: 0
      })

    {:ok, revision} =
      Billing.publish_revision(plan, %{
        prices: %{"KRW" => %{"amount" => 0}, "USD" => %{"amount" => 0}},
        interval: "month",
        included_credits: 3_000,
        limits: %{}
      })

    IO.puts("[seeds] created free plan — #{revision.included_credits} credits/month")

  _plan ->
    IO.puts("[seeds] free plan already exists.")
end
