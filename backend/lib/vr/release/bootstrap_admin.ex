defmodule VR.Release.BootstrapAdmin do
  @moduledoc """
  What an operator is told about the initial admin account — decided once, for
  every entry point that creates one.

  Three commands reach `VR.Accounts.Admin.ensure_bootstrap_admin/1`:

      bin/vr eval 'VR.Release.seed()'   # the deploy's preparation step
      mix run priv/repo/seeds.exs       # the same seed, from a checkout
      mix vr.bootstrap_admin            # the account, and nothing else

  It answers all three with the same four outcomes — created, an admin was
  already there, another run got there first, the address was refused — and
  reading those answers in two places is how the two readings drift apart.
  They had: the Mix task printed a password its operator had configured into
  `BOOTSTRAP_ADMIN_PASSWORD`, and reported a lost unique-index race as a
  failed command. Both readings live here now.

  ## What the entry point still decides

  Two things, and both are genuinely its own.

  **Whether an outcome is fatal.** No address configured is a skipped step in
  a seed that has two others to run, and a command that did nothing at all
  when creating the account *is* the whole command. Same outcome, same first
  sentence, different exit — which is the rule the app already follows for a
  value one entry point reads and another does not.

  **What else to print.** `mix vr.bootstrap_admin` is typed at a terminal and
  can afford to list the admins it found; a deploy log cannot.

  `:as` says which entry point is asking, and every sentence that is true of
  only one of them is chosen from it. Everything else is the same string.
  """

  alias VR.Accounts.Account
  alias VR.Accounts.Admin
  alias VR.Config
  alias VR.Release.Rejection

  @typedoc """
  Which entry point is asking.

    * `:seed` — one step of the preparation sequence, with steps around it
    * `:task` — `mix vr.bootstrap_admin`, where this is the only step
  """
  @type entry :: :seed | :task

  @typedoc """
  What happened, and the message that says so.

    * `:created` / `:exists` — print it and carry on
    * `:skipped` — no address was configured; nothing is broken, and whether
      that is fatal is the caller's to decide
    * `:rejected` — the input was refused; fatal at every entry point
  """
  @type outcome :: {:created | :exists | :skipped | :rejected, String.t()}

  @entry_points %{
    seed: "bin/vr eval 'VR.Release.seed()'",
    task: "mix vr.bootstrap_admin"
  }

  @doc """
  Creates the initial admin when there is none, and returns what to say.

  ## Options

    * `:as` — the entry point asking (required). See `t:entry/0`.
    * `:entry_point` — the exact command to quote back. Defaults to the usual
      command for `:as`; `priv/repo/seeds.exs` passes its own, so an operator
      on the Mix path is not told to run a release command that does not exist
      there.
    * `:email`, `:password` — passed straight through to
      `VR.Accounts.Admin.ensure_bootstrap_admin/1`. When absent, that function
      reads `BOOTSTRAP_ADMIN_EMAIL` / `BOOTSTRAP_ADMIN_PASSWORD` through
      `VR.Config`.

  ## The password is printed only when nothing else can show it

  A generated password exists nowhere but this output, so it is printed. A
  password the operator supplied — on the command line or in
  `BOOTSTRAP_ADMIN_PASSWORD` — is already theirs, and a second copy in a
  terminal scrollback or a deploy log is a second place it can leak from. The
  test is not "is it secret" but "is this the only place it can be seen".

  Which one it is has to be asked *before* the account is created: afterwards
  the password is only a hash.
  """
  @spec ensure(keyword()) :: outcome()
  def ensure(opts) do
    as = Keyword.fetch!(opts, :as)
    entry_point = Keyword.get(opts, :entry_point) || Map.fetch!(@entry_points, as)
    inputs = Keyword.take(opts, [:email, :password])
    supplied = password_source(inputs)

    case Admin.ensure_bootstrap_admin(inputs) do
      {:ok, account, password} ->
        {:created, created_message(account, supplied, password)}

      {:error, :admin_exists} ->
        {:exists, exists_message(as, :already)}

      {:error, :email_required} ->
        {:skipped, skipped_message(as, entry_point)}

      # The address is taken *and* an admin now exists: another run created it
      # between the count `ensure_bootstrap_admin/1` took and its insert.
      # Asking again is what tells the two apart — if no admin exists, the
      # address belongs to somebody else's account, and that is a typo the
      # operator has to see rather than a race to shrug off.
      {:error, %Ecto.Changeset{} = changeset} ->
        if Rejection.already_there?(changeset) and Admin.count_admins() > 0 do
          {:exists, exists_message(as, :concurrent)}
        else
          {:rejected, rejected_message(as, changeset, inputs, entry_point)}
        end
    end
  end

  # ── Messages ─────────────────────────────────────────────

  @spec created_message(Account.t(), String.t() | nil, String.t()) :: String.t()
  defp created_message(account, nil, password) do
    box(account, password, "This password is only shown right now. Save it somewhere.")
  end

  defp created_message(account, source, _password) do
    box(
      account,
      phrase(source, :password),
      "It was not printed — you set it, so this is not the only place it exists."
    )
  end

  defp box(account, password_column, note) do
    """

    ┌──────────────────────────────────────────────────────────┐
      Created the initial admin account

        Email     #{account.email}
        Password  #{password_column}

      #{note}
      Delete this account after promoting a real user to admin.
    └──────────────────────────────────────────────────────────┘
    """
  end

  # One sentence, one shape, whichever run created the row: an operator greps
  # a deploy log for `already exists`. How it got there, and how far this run
  # got, are appended.
  defp exists_message(as, origin) do
    prefix(as) <> "an admin already exists" <> got_there(origin) <> " " <> nothing_else(as)
  end

  defp got_there(:already), do: "."
  defp got_there(:concurrent), do: Rejection.concurrently()

  defp skipped_message(:seed, entry_point) do
    """

    #{prefix(:seed)}no initial admin was created — BOOTSTRAP_ADMIN_EMAIL is not set.

        Nothing else was skipped. Until an admin exists, /_admin cannot be
        opened by anyone. Set the address and run the seed again:

            BOOTSTRAP_ADMIN_EMAIL=you@example.com #{entry_point}

    #{password_note()}
    """
  end

  # Raised rather than printed, so it does not open with a blank line: this
  # command creates the admin and nothing else, so no address means the
  # command did nothing at all.
  defp skipped_message(:task, entry_point) do
    """
    no initial admin was created — BOOTSTRAP_ADMIN_EMAIL is not set.

        Creating the admin is all this command does, so nothing was created.
        Until an admin exists, /_admin cannot be opened by anyone. Set the
        address and run it again:

            BOOTSTRAP_ADMIN_EMAIL=you@example.com #{entry_point}

        Or pass the address directly:

            #{entry_point} --email you@example.com

    #{password_note()}
    """
  end

  defp password_note do
    """
        The password is optional — BOOTSTRAP_ADMIN_PASSWORD is used when set,
        and a random one is generated and printed once when it is not.\
    """
  end

  # `read from` is what turns "the schema refused this" into something to go
  # and fix: the value is in the block above it, and this is where it came
  # from. Naming the inputs here rather than in the sentence below keeps the
  # sentence a fixed length — a `--email` run and a `BOOTSTRAP_ADMIN_EMAIL`
  # run would otherwise wrap differently.
  defp rejected_message(as, changeset, inputs, entry_point) do
    """
    the initial admin account could not be created.

        email     #{inspect(email(inputs))}
        rejected  #{Rejection.errors(changeset)}
        read from #{read_from(inputs)}

    #{progress(as)} Fix the input named above, then re-run:

        #{entry_point}
    """
  end

  # ── Sentences that are true of one entry point only ──────

  # The area a message comes from. The seed is a step inside a longer run and
  # says so; a command the operator just typed is already labelled by the
  # prompt above it.
  defp prefix(:seed), do: "[seeds] "
  defp prefix(:task), do: ""

  # How far this run got — the question an operator asks next, and the one
  # answer that differs between a step and a whole command.
  defp nothing_else(:seed), do: "Skipping."
  defp nothing_else(:task), do: "Nothing was created."

  defp progress(:seed), do: "Everything else has been seeded."
  defp progress(:task), do: "Nothing was created."

  # ── Where the inputs came from ───────────────────────────

  defp email(inputs), do: inputs[:email] || Config.fetch("app.bootstrap_admin_email")

  # Only the names, not "email set in …": a row long enough to wrap is a row
  # the 80-column budget already rejects, and the labels above it say which
  # value is which.
  defp read_from(inputs) do
    case password_source(inputs) do
      nil -> [name(email_source(inputs), :email)]
      source -> [name(email_source(inputs), :email), name(source, :password)]
    end
    |> Enum.join(", ")
  end

  # `nil` means nothing was supplied and the password was generated — the one
  # case where printing it is the only way the operator ever sees it.
  defp password_source(inputs) do
    cond do
      supplied?(inputs[:password]) -> :option
      Config.configured?("app.bootstrap_admin_password") -> :config
      true -> nil
    end
  end

  defp email_source(inputs), do: if(supplied?(inputs[:email]), do: :option, else: :config)

  defp supplied?(value), do: value not in [nil, ""]

  defp name(:option, field), do: "--#{field}"
  defp name(:config, :email), do: "BOOTSTRAP_ADMIN_EMAIL"
  defp name(:config, :password), do: "BOOTSTRAP_ADMIN_PASSWORD"

  defp phrase(source, field), do: "the value " <> said(source, field)

  defp said(:option, field), do: "passed with #{name(:option, field)}"
  defp said(:config, field), do: "set in #{name(:config, field)}"
end
