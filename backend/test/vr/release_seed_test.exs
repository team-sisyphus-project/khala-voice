defmodule VR.ReleaseSeedTest do
  @moduledoc """
  The release seed entry point — `bin/vr eval 'VR.Release.seed()'`.

  What a green-field database needs before the app is of any use: a credit
  conversion policy, the free plan, and one account that can open `/_admin`.
  The deploy runs this on **every** deploy, chained after the migration, so
  the tests below care as much about the second run as the first.

  Not async: the missing-`CLOAK_KEY` case removes an environment variable, and
  the environment is shared by the whole node.
  """
  use VR.DataCase, async: false

  import ExUnit.CaptureIO

  alias VR.Accounts
  alias VR.Accounts.Admin
  alias VR.Billing
  alias VR.Billing.CreditConversionSetting
  alias VR.Billing.Plan
  alias VR.Billing.PlanRevision
  alias VR.Config
  alias VR.Release

  @entry_point "bin/vr eval 'VR.Release.seed()'"
  @email "founder@example.com"
  @password "correct-horse-battery"

  # Captures what the operator would read in the deploy log.
  defp seed(opts \\ []) do
    capture_io(fn -> assert :ok = Release.seed(opts) end)
  end

  defp configure_admin(email \\ @email, password \\ @password) do
    {:ok, _} = Config.put("app.bootstrap_admin_email", email)
    if password, do: {:ok, _} = Config.put("app.bootstrap_admin_password", password)
    :ok
  end

  defp counts do
    %{
      plans: Repo.aggregate(Plan, :count),
      revisions: Repo.aggregate(PlanRevision, :count),
      conversion_settings: Repo.aggregate(CreditConversionSetting, :count),
      admins: Admin.count_admins()
    }
  end

  # ── First run against a green-field database ───────────────

  describe "seed/1 on an empty database" do
    test "creates the conversion policy, the free plan and the admin" do
      configure_admin()

      output = seed()

      assert %{plans: 1, revisions: 1, conversion_settings: 1, admins: 1} = counts()

      plan = Billing.get_plan_by_key(Billing.free_plan_key())
      assert plan.status == "published"
      assert Billing.current_revision(plan).included_credits == 3_000
      assert Decimal.equal?(VR.Billing.Credits.conversion_setting().credit_value_usd, "0.0015")

      assert output =~ "created credit conversion policy"
      assert output =~ "created free plan"
      assert output =~ "Created the initial admin account"
      assert output =~ @email
    end

    test "the admin it creates can sign in" do
      configure_admin()
      seed()

      assert account = Accounts.get_account_by_email_and_password(@email, @password)
      assert account.is_admin
      assert account.is_bootstrap
      # Email delivery may not be configured yet, so the account is usable now.
      assert account.confirmed_at
    end

    test "a password the operator configured is never printed" do
      configure_admin()

      output = seed()

      refute output =~ @password
      assert output =~ "BOOTSTRAP_ADMIN_PASSWORD"
    end

    test "a generated password is printed once, because nothing else can show it" do
      configure_admin(@email, nil)

      output = seed()

      assert output =~ "only shown right now"

      [_, printed] = Regex.run(~r/Password\s+(\S+)/, output)
      assert Accounts.get_account_by_email_and_password(@email, printed)
    end
  end

  # ── Second run ─────────────────────────────────────────────

  describe "seed/1 run again" do
    test "creates no duplicates and still leaves exactly one admin" do
      configure_admin()
      seed()
      before = counts()

      output = seed()

      assert counts() == before
      assert %{plans: 1, revisions: 1, conversion_settings: 1, admins: 1} = before

      assert output =~ "credit conversion policy already exists"
      assert output =~ "free plan already exists"
      assert output =~ "an admin already exists"
      refute output =~ "Created the initial admin account"
    end

    test "the admin can still sign in after the second run" do
      configure_admin()
      seed()
      seed()

      assert Accounts.get_account_by_email_and_password(@email, @password)
    end
  end

  # ── No email configured ────────────────────────────────────

  describe "seed/1 without BOOTSTRAP_ADMIN_EMAIL" do
    test "skips the admin with a message, and seeds everything else" do
      output = seed()

      assert %{plans: 1, conversion_settings: 1, admins: 0} = counts()

      assert output =~ "no initial admin was created"
      assert output =~ "BOOTSTRAP_ADMIN_EMAIL"
      assert output =~ "Nothing else was skipped"
      # The consequence, not only the cause: this is the difference between a
      # preview someone can sign in to and one nobody can.
      assert output =~ "/_admin"
    end

    test "the skip message quotes the entry point that printed it" do
      assert seed() =~ @entry_point

      assert seed(entry_point: "mix run priv/repo/seeds.exs") =~
               "BOOTSTRAP_ADMIN_EMAIL=you@example.com mix run priv/repo/seeds.exs"
    end
  end

  # ── Bad input ──────────────────────────────────────────────

  describe "seed/1 with an address the schema rejects" do
    test "fails loudly, naming the value and the command to re-run" do
      configure_admin("not-an-email")

      message =
        assert_raise(RuntimeError, fn -> capture_io(fn -> Release.seed() end) end)

      assert message.message =~ "initial admin account could not be created"
      assert message.message =~ "not-an-email"
      assert message.message =~ "BOOTSTRAP_ADMIN_EMAIL"
      assert message.message =~ @entry_point
    end

    test "everything that does not depend on the operator is seeded first" do
      configure_admin("not-an-email")

      assert_raise(RuntimeError, fn -> capture_io(fn -> Release.seed() end) end)

      # A typo in one variable must not cost the deploy its billing rows.
      assert %{plans: 1, conversion_settings: 1, admins: 0} = counts()
    end
  end

  # ── Requirements of this entry point ───────────────────────

  defmodule UnconfiguredRepo do
    # A repo config with no url, hostname or socket: nowhere to connect to.
    def config, do: [pool_size: 2, log: false]
  end

  describe "seed/1 requirements" do
    test "a missing DATABASE_URL does not claim CLOAK_KEY is unnecessary here" do
      message =
        assert_raise(RuntimeError, fn ->
          Release.ensure_configured!(UnconfiguredRepo, @entry_point)
        end)

      assert message.message =~ "DATABASE_URL"
      assert message.message =~ @entry_point
      # The migration's message says CLOAK_KEY is not read. On this path that
      # would send an operator to remove the one value the seed does need.
      assert message.message =~ "Seeding also needs CLOAK_KEY"
      refute message.message =~ "Only DATABASE_URL is needed here"
    end

    test "a missing CLOAK_KEY names the value, this entry point, and how to make one" do
      original = System.get_env("CLOAK_KEY")
      System.delete_env("CLOAK_KEY")

      try do
        message = assert_raise(RuntimeError, fn -> Release.seed() end)

        assert message.message =~ "CLOAK_KEY"
        assert message.message =~ @entry_point
        assert message.message =~ "openssl rand -base64 32"
        # Migration is the neighbouring step in the same deploy line; saying it
        # does not need this value keeps the operator from "fixing" that too.
        assert message.message =~ "bin/vr eval 'VR.Release.migrate()'"
      after
        if original, do: System.put_env("CLOAK_KEY", original)
      end
    end

    test "nothing is seeded when a requirement is missing" do
      configure_admin()
      original = System.get_env("CLOAK_KEY")
      System.delete_env("CLOAK_KEY")

      try do
        assert_raise(RuntimeError, fn -> Release.seed() end)
        assert %{plans: 0, conversion_settings: 0, admins: 0} = counts()
      after
        if original, do: System.put_env("CLOAK_KEY", original)
      end
    end
  end

  # ── The two entry points stay one implementation ───────────

  describe "the Mix path and the release path" do
    @backend_root Path.expand("../..", __DIR__)
    @repo_root Path.expand("../../..", __DIR__)

    test "priv/repo/seeds.exs delegates instead of keeping a second copy" do
      seeds = File.read!(Path.join(@backend_root, "priv/repo/seeds.exs"))

      assert seeds =~ "VR.Release.seed("

      # The whole point of the delegation: a rule added to one path cannot go
      # missing from the other. Any of these appearing here means it has.
      for duplicated <- ~w(ensure_bootstrap_admin create_plan publish_revision
                           put_conversion_setting) do
        refute seeds =~ duplicated,
               "priv/repo/seeds.exs re-implements #{duplicated}; call VR.Release.seed/1"
      end
    end

    test "deploy.toml runs the seed after the migration, in the same step" do
      deploy = File.read!(Path.join(@repo_root, "deploy.toml"))

      assert deploy =~ "VR.Release.migrate()"
      assert deploy =~ "VR.Release.seed()"

      [migrate_line] =
        deploy
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "migrate ="))

      migrate_at = :binary.match(migrate_line, "VR.Release.migrate()") |> elem(0)
      seed_at = :binary.match(migrate_line, "VR.Release.seed()") |> elem(0)

      assert migrate_at < seed_at, "the seed must not run before the schema exists"
    end
  end
end
