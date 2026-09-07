defmodule Mix.Tasks.Vr.DoctorTest do
  @moduledoc """
  What `mix vr.doctor` says about the preparation sequence.

  Two sections are held here. **Required config** answers, per entry point,
  whether that command can run — a migration is never reported as missing a
  value it does not read, which is the defect this Story exists to remove.
  **Seed data** answers whether a migrated database is actually usable: the
  conversion policy, the free plan, and whether anyone can open `/_admin`.

  The rows are checked as rendered text, because the format is the deliverable:
  an operator reads these lines in a terminal, and a line that wraps is a line
  that is skipped.

  Not async: the config rows read the environment, which is node-wide.
  """
  use VR.DataCase, async: false

  import ExUnit.CaptureIO

  alias VR.Accounts.Admin
  alias VR.Billing
  alias VR.Config
  alias VR.Release

  @doctor Mix.Tasks.Vr.Doctor
  @vars ~w(DATABASE_URL CLOAK_KEY SECRET_KEY_BASE)

  # The doctor reads the real environment; each test states the whole of it.
  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)
    end)

    :ok
  end

  defp env(values) do
    Enum.each(@vars, fn var ->
      case values[var] do
        nil -> System.delete_env(var)
        value -> System.put_env(var, value)
      end
    end)
  end

  # `config/test.exs` always carries a connection, so the case a release is in
  # — no Mix config, only the variable — is stated rather than simulated.
  defp config_rows(values, opts \\ [repo_configured: false]) do
    env(values)
    @doctor.config_rows(opts)
  end

  defp detail(rows, label) do
    Enum.find(rows, &(&1.label == label)).detail
  end

  defp status(rows, label) do
    Enum.find(rows, &(&1.label == label)).status
  end

  defp rendered(rows) do
    Enum.flat_map(rows, &@doctor.render/1)
  end

  # ── Required config, by entry point ────────────────────────

  describe "config rows" do
    test "a migration with only DATABASE_URL is ready" do
      rows = config_rows(%{"DATABASE_URL" => "ecto://u:p@localhost/vr"})

      assert status(rows, "migrate") == :ok
      assert detail(rows, "migrate") == "DATABASE_URL set"
    end

    test "no row blames the migration for a value the migration does not read" do
      rows = config_rows(%{"DATABASE_URL" => "ecto://u:p@localhost/vr"})

      assert Enum.flat_map(rows, & &1.missing) == [
               {"CLOAK_KEY", "seed"},
               {"SECRET_KEY_BASE", "app boot"}
             ]

      refute Enum.any?(
               rendered(rows),
               &String.contains?(&1, "migrate            SECRET_KEY_BASE")
             )
    end

    test "each entry point names only the value it adds" do
      rows = config_rows(%{})

      assert Enum.map(rows, & &1.label) == ["migrate", "seed", "app boot"]
      assert detail(rows, "migrate") == "DATABASE_URL missing"
      assert detail(rows, "seed") == "CLOAK_KEY missing"
      assert detail(rows, "app boot") == "SECRET_KEY_BASE missing"
    end

    test "everything set is three ready commands" do
      rows =
        config_rows(%{
          "DATABASE_URL" => "ecto://u:p@localhost/vr",
          "CLOAK_KEY" => "irrelevant",
          "SECRET_KEY_BASE" => "irrelevant"
        })

      assert Enum.map(rows, & &1.status) == [:ok, :ok, :ok]
      assert Enum.flat_map(rows, & &1.missing) == []
    end

    test "a later command whose own value is set still names what stops it" do
      rows =
        config_rows(%{"CLOAK_KEY" => "irrelevant", "SECRET_KEY_BASE" => "irrelevant"})

      assert status(rows, "seed") == :error
      assert detail(rows, "seed") == "CLOAK_KEY set — waiting on DATABASE_URL"
      assert detail(rows, "app boot") == "SECRET_KEY_BASE set — waiting on DATABASE_URL"

      # Named once, by the command that reads it.
      assert Enum.flat_map(rows, & &1.missing) == [{"DATABASE_URL", "migrate"}]
    end

    test "a checkout without DATABASE_URL is not a broken migration" do
      rows = config_rows(%{}, repo_configured: true)

      assert status(rows, "migrate") == :ok
      assert detail(rows, "migrate") == "DATABASE_URL not set — using config/test.exs"

      assert Enum.flat_map(rows, & &1.missing) == [
               {"CLOAK_KEY", "seed"},
               {"SECRET_KEY_BASE", "app boot"}
             ]
    end
  end

  # ── Seed data ──────────────────────────────────────────────

  describe "seed rows" do
    test "a green-field database names each missing row and the command for it" do
      rows = @doctor.seed_rows(@doctor.seed_facts(:ready))

      assert Enum.map(rows, & &1.status) == [:error, :error, :error]
      assert detail(rows, "credit conversion") =~ "missing"
      assert detail(rows, "free plan") =~ "missing"
      assert detail(rows, "admin sign-in") == "no admin — /_admin cannot be opened by anyone"

      hints = Enum.map(rows, & &1.hint)

      assert hints == [
               "create: mix run priv/repo/seeds.exs",
               "create: mix run priv/repo/seeds.exs",
               "create: mix vr.bootstrap_admin --email you@example.com"
             ]
    end

    test "what the seed leaves behind is what the doctor reads back" do
      {:ok, _} = Config.put("app.bootstrap_admin_email", "founder@example.com")
      capture_io(fn -> assert :ok = Release.seed() end)

      rows = @doctor.seed_rows(@doctor.seed_facts(:ready))

      assert Enum.map(rows, & &1.status) == [:ok, :ok, :ok]
      assert Enum.flat_map(rows, & &1.missing) == []
      assert detail(rows, "credit conversion") == "1 credit = $0.0015"
      assert detail(rows, "free plan") == "3000 credits/month"
      assert detail(rows, "admin sign-in") == "1 admin can open /_admin"
      assert Admin.count_admins() == 1
    end

    test "a plan the seed never finished is not reported as ready" do
      {:ok, _plan} =
        Billing.create_plan(%{
          key: Billing.free_plan_key(),
          display_name: "Free",
          status: "published"
        })

      rows = @doctor.seed_rows(@doctor.seed_facts(:ready))

      assert status(rows, "free plan") == :warn
      assert detail(rows, "free plan") == "no revision — signups get no included credits"
      assert Enum.member?(Enum.flat_map(rows, & &1.missing), "free plan revision")
    end

    test "an unmigrated database is not asked for rows it cannot have" do
      assert [row] = @doctor.seed_rows(@doctor.seed_facts(:pending))
      assert row.status == :info
      assert row.detail == "not checked — the migrations above have not run"

      assert [%{status: :info, detail: "not checked — the database cannot be reached"}] =
               @doctor.seed_rows(@doctor.seed_facts(:unreachable))
    end
  end

  # ── Format ─────────────────────────────────────────────────

  describe "the printed rows" do
    test "fit the 80-column budget" do
      facts = %{conversion: nil, free_plan: nil, admins: 0}

      lines =
        rendered(config_rows(%{"CLOAK_KEY" => "x", "SECRET_KEY_BASE" => "x"})) ++
          rendered(config_rows(%{}, repo_configured: true)) ++
          rendered(@doctor.seed_rows(facts)) ++
          rendered(@doctor.seed_rows(:pending))

      for line <- lines do
        assert String.length(line) <= 80, "#{String.length(line)} chars:\n#{line}"
      end
    end

    test "put the command on its own line, the way a missing binary does" do
      [row, hint] =
        @doctor.render(hd(@doctor.seed_rows(%{conversion: nil, free_plan: nil, admins: 0})))

      assert row =~ "❌ credit conversion"
      assert hint == "       create: mix run priv/repo/seeds.exs"
    end

    test "a row with nothing to do prints one line" do
      assert [_only] = @doctor.render(hd(@doctor.seed_rows(:pending)))
    end
  end
end
