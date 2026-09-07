defmodule Mix.Tasks.Vr.BootstrapAdminTest do
  @moduledoc """
  The third way to the initial admin account — `mix vr.bootstrap_admin`.

  The other two are the deploy's seed step and `mix run priv/repo/seeds.exs`,
  covered in `VR.ReleaseSeedTest`. All three call the same
  `VR.Accounts.Admin.ensure_bootstrap_admin/1` and get the same four answers
  back, so what these tests hold is that this one reads them the way the seed
  does: a configured password stays out of the output, a lost race is an
  account that exists rather than a failed command, and a refused address is
  loud.

  Not async: `Mix.shell/0` is node-wide.
  """
  use VR.DataCase, async: false

  import ExUnit.CaptureIO

  alias VR.Accounts
  alias VR.Accounts.Admin
  alias VR.Config
  alias VR.Release

  @task Mix.Tasks.Vr.BootstrapAdmin
  @email "founder@example.com"
  @password "correct-horse-battery"

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.IO)
    on_exit(fn -> Mix.shell(shell) end)
    :ok
  end

  defp run(args \\ []) do
    capture_io(fn -> @task.run(args) end)
  end

  defp configure(email \\ @email, password \\ @password) do
    {:ok, _} = Config.put("app.bootstrap_admin_email", email)
    if password, do: {:ok, _} = Config.put("app.bootstrap_admin_password", password)
    :ok
  end

  # ── Created ────────────────────────────────────────────────

  describe "with an address and no admin yet" do
    test "creates one admin that can sign in" do
      configure()

      output = run()

      assert Admin.count_admins() == 1
      assert account = Accounts.get_account_by_email_and_password(@email, @password)
      assert account.is_admin
      assert account.is_bootstrap
      assert account.confirmed_at

      assert output =~ "Created the initial admin account"
      assert output =~ @email
      assert output =~ "Delete this temporary account"
    end

    test "takes the address from --email" do
      output = run(["--email", "cli@example.com"])

      assert Accounts.get_account_by_email("cli@example.com").is_admin
      assert output =~ "cli@example.com"
    end
  end

  # ── The password ───────────────────────────────────────────

  describe "the password" do
    test "one set in BOOTSTRAP_ADMIN_PASSWORD is never printed" do
      configure()

      output = run()

      refute output =~ @password
      assert output =~ "the value set in BOOTSTRAP_ADMIN_PASSWORD"
      assert output =~ "not the only place it exists"
    end

    test "one passed with --password is never printed" do
      output = run(["--email", @email, "--password", @password])

      assert Accounts.get_account_by_email_and_password(@email, @password)
      refute output =~ @password
      assert output =~ "the value passed with --password"
    end

    test "a generated one is printed once, because nothing else can show it" do
      configure(@email, nil)

      output = run()

      assert output =~ "only shown right now"

      [_, printed] = Regex.run(~r/Password\s+(\S+)/, output)
      assert Accounts.get_account_by_email_and_password(@email, printed)
    end
  end

  # ── Already there ──────────────────────────────────────────

  describe "when an admin already exists" do
    test "creates nothing and says who can already get in" do
      configure()
      run()

      output = run()

      assert Admin.count_admins() == 1
      assert output =~ "an admin already exists."
      assert output =~ "Nothing was created."
      refute output =~ "Created the initial admin account"

      # The reason for the extra query: the operator typed this to get into
      # /_admin, and this is the address that already can.
      assert output =~ @email
      assert output =~ "temporary account"
      assert output =~ "mix vr.make_admin"
    end
  end

  # ── Another run got there first ────────────────────────────

  describe "when another run creates the admin at the same time" do
    # The same window the seed step has: this command counts the admins, gets
    # zero, and by the time it inserts, the deploy's seed step has committed
    # its own. Reproduced without a second connection — the count is a query,
    # and the row goes in behind it.
    #
    # `on: 1` lands the row after that count and before the changeset's own
    # lookup for the email index, so the lookup reports it
    # (`validation: :unsafe_unique`); `on: 2` lands it behind the lookup, so
    # the index does (`constraint: :unique`). One fact, two reporters, and
    # this command has to read both the way the seed does.
    for {reporter, nth} <- [{"the email index", 2}, {"the changeset's own lookup", 1}] do
      test "reports the account as already there — #{reporter}" do
        configure()

        race_after_read(
          "accounts",
          [
            "INSERT INTO accounts (id, email, is_admin, is_bootstrap, confirmed_at, " <>
              "inserted_at, updated_at) VALUES ('acct-race', '#{@email}', true, true, " <>
              "now(), now(), now())"
          ],
          on: unquote(nth)
        )

        output = run()

        assert Admin.count_admins() == 1
        assert output =~ "an admin already exists"
        assert output =~ "created by a concurrent run"
        # It is the other run's account: there is no new password to announce,
        # and the one it was given is not ours to print.
        refute output =~ "Created the initial admin account"
        refute output =~ @password
      end
    end

    # Same rejection, different fact: the address is taken by an account that
    # is not an admin. Reading that as "already exists" leaves an operator
    # with a green command and no way into /_admin.
    test "an address owned by someone else is not mistaken for the race" do
      configure()

      race_after_read("accounts", [
        "INSERT INTO accounts (id, email, is_admin, inserted_at, updated_at) " <>
          "VALUES ('acct-member', '#{@email}', false, now(), now())"
      ])

      message = assert_raise(Mix.Error, fn -> run() end)

      assert message.message =~ "the initial admin account could not be created"
      assert message.message =~ "BOOTSTRAP_ADMIN_EMAIL"
      assert Admin.count_admins() == 0
    end
  end

  # ── Refused input ──────────────────────────────────────────

  describe "with an address the schema rejects" do
    test "fails, naming the value, where it was read from, and this command" do
      configure("not-an-email")

      message = assert_raise(Mix.Error, fn -> run() end)

      assert message.message =~ "the initial admin account could not be created"
      assert message.message =~ "not-an-email"
      assert message.message =~ "BOOTSTRAP_ADMIN_EMAIL, BOOTSTRAP_ADMIN_PASSWORD"
      assert message.message =~ "Nothing was created."
      assert message.message =~ "mix vr.bootstrap_admin"
      assert Admin.count_admins() == 0
    end

    test "names the switches instead when that is where the values came from" do
      message =
        assert_raise(Mix.Error, fn ->
          run(["--email", "not-an-email", "--password", @password])
        end)

      assert message.message =~ "--email, --password"
      refute message.message =~ "BOOTSTRAP_ADMIN_EMAIL"
    end
  end

  # ── No address ─────────────────────────────────────────────

  describe "without an address" do
    # The seed step steps over this one — it has two others to run. Here it is
    # the whole command, so nothing happened at all.
    test "stops, and shows both ways to supply the address" do
      message = assert_raise(Mix.Error, fn -> run() end)

      assert message.message =~ "no initial admin was created"
      assert message.message =~ "BOOTSTRAP_ADMIN_EMAIL is not set"
      assert message.message =~ "all this command does, so nothing was created"
      assert message.message =~ "/_admin"
      assert message.message =~ "BOOTSTRAP_ADMIN_EMAIL=you@example.com mix vr.bootstrap_admin"
      assert message.message =~ "mix vr.bootstrap_admin --email you@example.com"
      assert Admin.count_admins() == 0
    end
  end

  # ── The same reading as the seed ───────────────────────────

  describe "this command and the seed step" do
    @task_source Path.expand("../../../lib/mix/tasks/vr.bootstrap_admin.ex", __DIR__)

    test "one implementation decides what each outcome means" do
      source = File.read!(@task_source)

      assert source =~ "BootstrapAdmin.ensure"

      # Each of these appearing here means this command has started reading an
      # outcome for itself again — which is how it came to print a configured
      # password and to call a lost race a failure.
      for duplicated <- ~w(ensure_bootstrap_admin :admin_exists :email_required
                           random_password constraint) do
        refute source =~ duplicated,
               "#{duplicated} is read in the Mix task; VR.Release.BootstrapAdmin decides it"
      end
    end

    test "both entry points say the same thing about the same outcome" do
      configure()
      run()

      from_seed = capture_io(fn -> assert :ok = Release.seed() end)
      from_task = run()

      assert from_seed =~ "an admin already exists."
      assert from_task =~ "an admin already exists."
    end

    # Same budget the migration and seed messages are held to: a deploy log or
    # a terminal wraps at 80, and a wrapped line is a line nobody reads.
    test "no message is wider than the terminal it is read in" do
      refused = assert_raise(Mix.Error, fn -> run(["--email", "no", "--password", "x"]) end)
      no_address = assert_raise(Mix.Error, fn -> run() end)

      configure()
      created = run()
      exists = run()

      for text <- [refused.message, no_address.message, created, exists],
          line <- String.split(text, "\n") do
        assert String.length(line) <= 80, "#{String.length(line)} chars:\n#{line}"
      end
    end
  end

  # Ecto emits telemetry for every query. The handler runs after the read the
  # command decides from and before the write it builds from that answer, so
  # the racing row lands exactly in the window a second deploy would use. It
  # goes in as a statement of its own, so the savepoint that takes back the
  # failed INSERT leaves it standing — as another transaction's commit would.
  defp race_after_read(source, statements, opts \\ []) do
    handler = {__MODULE__, source, make_ref()}
    counter = :counters.new(1, [])
    nth = Keyword.get(opts, :on, 1)

    :telemetry.attach(
      handler,
      [:vr, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if meta[:source] == source and String.starts_with?(meta.query, "SELECT") do
          :counters.add(counter, 1, 1)

          if :counters.get(counter, 1) == nth do
            :telemetry.detach(handler)
            Enum.each(statements, &Repo.query!/1)
          end
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end
end
