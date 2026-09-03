defmodule Mix.Tasks.Vr.BootstrapAdmin do
  @moduledoc """
  Creates the initial admin account.

      mix vr.bootstrap_admin
      mix vr.bootstrap_admin --email you@example.com

  Right after installation there is no admin, so `/_admin` is unreachable.
  This command creates a temporary key that opens that door.

  **If an admin already exists, it does nothing.** Safe to run multiple times.

  ## Password

  Uses the `BOOTSTRAP_ADMIN_PASSWORD` environment variable; without it, a
  random password is generated and shown **on screen exactly once**. Only the
  hash is stored, so it cannot be looked up later.

  ## When you are done

  Sign up as a real user, promote that account from the admin screens, and
  **delete this temporary account to close the door.** Leaving it behind
  creates a permanent backdoor.
  """
  @shortdoc "Creates the initial admin account"

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
          Initial admin account created

            Email     #{account.email}
            Password  #{password}

          This password is shown only now. Save it somewhere safe.
        └──────────────────────────────────────────────────────────┘

        Next steps:

          1. Sign in with this account → open /_admin
          2. Sign up separately with your own account
          3. Promote your account to admin under Admin → Accounts
          4. **Delete this temporary account** — this closes the door

        Skipping step 4 leaves a permanent backdoor.
        """)

      {:error, :admin_exists} ->
        admins = Admin.list_accounts(only: :admins)

        Mix.shell().info("""

        An admin already exists. Nothing was created.

        #{Enum.map_join(admins, "\n", fn a -> "  · #{a.email}#{if a.is_bootstrap, do: "  (temporary account — deletion recommended)", else: ""}" end)}

        To grant admin to more accounts:  mix vr.make_admin <email>
        """)

      {:error, :email_required} ->
        Mix.raise("""
        An email is required. There is no default address —
        if every deployment used the same one, it would itself become a target.

            mix vr.bootstrap_admin --email you@example.com

        Or set the BOOTSTRAP_ADMIN_EMAIL environment variable.
        """)

      {:error, changeset} ->
        errors =
          changeset
          |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
          |> Enum.map_join("; ", fn {k, v} -> "#{k}: #{Enum.join(v, ", ")}" end)

        Mix.raise("Failed to create account — #{errors}")
    end
  end
end
