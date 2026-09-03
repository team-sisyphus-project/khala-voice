defmodule Mix.Tasks.Vr.MakeAdmin do
  @moduledoc """
  Grants system admin permission to an account.

      mix vr.make_admin someone@example.com
      mix vr.make_admin someone@example.com --revoke

  Admin accounts are created only this way. There is no self-promotion in the
  UI — a compromised admin screen would otherwise lead straight to privilege
  escalation.
  """
  @shortdoc "Grants or revokes admin permission for an account"

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, argv, _} = OptionParser.parse(args, switches: [revoke: :boolean])

    case argv do
      [email] -> toggle(email, not (opts[:revoke] || false))
      _ -> Mix.raise("Usage: mix vr.make_admin <email> [--revoke]")
    end
  end

  defp toggle(email, grant?) do
    case VR.Accounts.get_account_by_email(email) do
      nil ->
        Mix.raise("Account not found: #{email}")

      account ->
        {:ok, updated} =
          account
          |> Ecto.Changeset.change(%{is_admin: grant?})
          |> VR.Repo.update()

        if grant? do
          Mix.shell().info("""

          ✅ Admin permission granted.

             #{updated.email}  (#{updated.id})

          This account can now access /_admin.
          """)
        else
          Mix.shell().info("\n✅ Admin permission revoked: #{updated.email}\n")
        end
    end
  end
end
