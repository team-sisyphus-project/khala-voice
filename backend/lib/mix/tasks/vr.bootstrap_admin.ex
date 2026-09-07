defmodule Mix.Tasks.Vr.BootstrapAdmin do
  @moduledoc """
  Creates the initial admin account.

      mix vr.bootstrap_admin
      mix vr.bootstrap_admin --email you@example.com

  Right after installation there is no admin, so `/_admin` is unreachable.
  This command creates a temporary key that opens that door.

  **If an admin already exists, it does nothing.** Safe to run multiple times,
  and safe to run while a deploy's seed step is doing the same thing — the run
  that loses reports the account as already there.

  ## Password

  Uses the `BOOTSTRAP_ADMIN_PASSWORD` environment variable, or `--password`;
  without either, a random password is generated and shown **on screen exactly
  once**. A password you supplied is never printed — you already have it, and
  a scrollback is one more place it can leak from. Only the hash is stored, so
  a generated one cannot be looked up later.

  ## When you are done

  Sign up as a real user, promote that account from the admin screens, and
  **delete this temporary account to close the door.** Leaving it behind
  creates a permanent backdoor.

  ## Why so little code

  What to do with each answer — created, already there, another run got there
  first, the address was refused — is decided in `VR.Release.BootstrapAdmin`,
  together with the deploy's seed step. This task only says which outcomes it
  cannot continue past, and prints what an operator at a terminal can use and
  a deploy log cannot.
  """
  @shortdoc "Creates the initial admin account"

  use Mix.Task

  alias VR.Accounts.Admin
  alias VR.Release.BootstrapAdmin

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    Logger.configure(level: :warning)
    {opts, _, _} = OptionParser.parse(args, switches: [email: :string, password: :string])

    case BootstrapAdmin.ensure([as: :task] ++ opts) do
      {:created, message} ->
        Mix.shell().info(message <> next_steps())

      {:exists, message} ->
        Mix.shell().info("\n" <> message <> existing_admins())

      # Creating the account is the whole of this command, so an outcome the
      # seed step steps over is this command having done nothing at all.
      {skipped_or_rejected, message} when skipped_or_rejected in [:skipped, :rejected] ->
        Mix.raise(message)
    end
  end

  defp next_steps do
    """

    Next steps:

      1. Sign in with this account → open /_admin
      2. Sign up separately with your own account
      3. Promote your account to admin under Admin → Accounts
      4. **Delete this temporary account** — this closes the door

    Skipping step 4 leaves a permanent backdoor.
    """
  end

  # Worth the extra query here and nowhere else: someone typed this command to
  # get into `/_admin`, and the answer they need is which address already can.
  defp existing_admins do
    admins = Admin.list_accounts(only: :admins)

    """

    #{Enum.map_join(admins, "\n", &admin_line/1)}

    To grant admin to more accounts:  mix vr.make_admin <email>
    """
  end

  defp admin_line(account) do
    "  · " <>
      account.email <>
      if account.is_bootstrap, do: "  (temporary account — deletion recommended)", else: ""
  end
end
