defmodule VR.Accounts.MFA do
  @moduledoc """
  Two-factor authentication (TOTP) for system admins.

  ## Why admins only

  A system admin is **the operator of the entire system.** They can delete any account,
  read API keys, and make other people admins. The blast radius of one compromised
  account is different from that of a regular user. So 2FA is applied only here.

  MFA is not exposed to regular users — every setting they never need is itself
  a reason to churn.

  ## Development-environment bypass

  **Outside production, any 6-digit number passes.**

  If development and testing required a real authenticator app, no one would ever
  enable MFA, and it would be enabled for the first time in production. That is riskier.

  In production this bypass **does not work** — `config_env() == :prod` is checked
  at compile time, so it cannot be opened by changing an environment variable.
  """

  alias VR.Accounts.Account
  alias VR.Repo

  require Logger

  @issuer "KHALA VOICE"
  @backup_code_count 10

  # Frozen at compile time. Cannot be bypassed via runtime environment variables.
  @dev_bypass Mix.env() != :prod

  @doc "Whether the development bypass is enabled in this environment. Used to show a warning on screen."
  def dev_bypass?, do: @dev_bypass

  @doc "A new TOTP secret. Not stored yet — it is only enabled after verification succeeds."
  def generate_secret, do: NimbleTOTP.secret()

  @doc """
  The `otpauth://` URI to enter into an authenticator app.

  Shown as a QR code, with the secret also exposed for environments where scanning is not possible.
  """
  def provisioning_uri(%Account{email: email}, secret) do
    NimbleTOTP.otpauth_uri("#{@issuer}:#{email}", secret, issuer: @issuer)
  end

  @doc "The secret in a form a person can transcribe."
  def readable_secret(secret) do
    secret
    |> Base.encode32(padding: false)
    |> String.replace(~r/(.{4})(?=.)/, "\\1 ")
  end

  @doc """
  Verifies a code.

  Outside production, any 6-digit number passes (`dev_bypass?/0`).
  """
  def valid_code?(secret, code) when is_binary(code) do
    normalized = String.replace(code, ~r/\s/, "")

    cond do
      @dev_bypass and normalized =~ ~r/^\d{6}$/ ->
        Logger.warning("[MFA] Passed via the development bypass. This does not work in production.")
        true

      is_nil(secret) ->
        false

      true ->
        # Allow one window on either side to account for clock drift
        NimbleTOTP.valid?(secret, normalized, since: nil)
    end
  end

  def valid_code?(_secret, _code), do: false

  @doc """
  Enables MFA. Only enabled after code verification succeeds.

  `{:ok, account, backup_codes}` — the backup codes are visible **only this once.**
  They are stored only as hashes.
  """
  def enable(%Account{} = account, secret, code) do
    # The development bypass already lives inside `valid_code?/2` (any 6-digit number).
    # Opening another one here would let **any string** through, breaking
    # "it does not enable if the code is wrong".
    if valid_code?(secret, code) do
      codes = Enum.map(1..@backup_code_count, fn _ -> generate_backup_code() end)
      hashes = Enum.map(codes, &hash_backup_code/1)

      result =
        account
        |> Account.mfa_changeset(%{
          mfa_secret: secret,
          mfa_enabled: true,
          mfa_enabled_at: DateTime.utc_now(:second),
          mfa_backup_hashes: hashes
        })
        |> Repo.update()

      with {:ok, updated} <- result, do: {:ok, updated, codes}
    else
      {:error, :invalid_code}
    end
  end

  @doc "Disables MFA. Only after verifying the current code."
  def disable(%Account{} = account, code) do
    if verify(account, code) == :ok do
      account
      |> Account.mfa_changeset(%{
        mfa_secret: nil,
        mfa_enabled: false,
        mfa_enabled_at: nil,
        mfa_backup_hashes: []
      })
      |> Repo.update()
    else
      {:error, :invalid_code}
    end
  end

  @doc """
  Verifies a code at login. Accepts a TOTP or a backup code.

  A backup code is **consumed after a single use.**
  """
  # **Accounts that never enabled MFA do not pass.**
  #
  # This used to return `:ok`. But login sends admins to the code screen
  # **unconditionally**, so an admin who had not enabled MFA could enter any
  # number and pass — pretending to have two-factor auth while actually being
  # protected by nothing but a password.
  #
  # An account that never enabled MFA has no means of verifying a code. If it
  # cannot be verified, that is a rejection, not a pass. That account should go
  # to the **enrollment screen**, not the code screen
  # (`SessionController.enroll/2`).
  def verify(%Account{mfa_enabled: false}, _code), do: {:error, :not_enrolled}

  def verify(%Account{} = account, code) when is_binary(code) do
    cond do
      valid_code?(account.mfa_secret, code) -> :ok
      true -> consume_backup_code(account, code)
    end
  end

  def verify(_account, _code), do: {:error, :invalid_code}

  @doc """
  Is two-factor authentication **mandatory** for this account?

  **System admins are mandatory, no exceptions.** If one admin account is breached,
  the entire system's settings, API keys, and every account go with it. A single
  password cannot protect that.

  It is not required of regular users — ask people to install an authenticator app
  just to view meeting notes and most of them leave.

  This is a different question from `mfa_enabled`. An admin who has not enabled it
  yet is **still subject to the mandate**, which is why setup is enforced before
  entering the admin screen.
  """
  def required?(%Account{is_admin: true}), do: true
  def required?(_account), do: false

  @doc "Can this account enter the admin screen right now? Blocked if it is mandatory but not yet enabled."
  def satisfied?(%Account{} = account) do
    not required?(account) or account.mfa_enabled
  end

  @doc "Number of backup codes remaining."
  def backup_codes_left(%Account{mfa_backup_hashes: hashes}), do: length(hashes)

  # ── Backup codes ─────────────────────────────────────────

  # Confusing characters are excluded so it is easy for people to transcribe
  @alphabet ~c"ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

  defp generate_backup_code do
    1..10
    |> Enum.map(fn _ -> Enum.random(@alphabet) end)
    |> List.to_string()
    |> String.replace(~r/(.{5})(?=.)/, "\\1-")
  end

  defp hash_backup_code(code) do
    :sha256
    |> :crypto.hash(normalize_backup_code(code))
    |> Base.encode16(case: :lower)
  end

  defp normalize_backup_code(code) do
    code |> to_string() |> String.upcase() |> String.replace(~r/[^A-Z0-9]/, "")
  end

  defp consume_backup_code(%Account{} = account, code) do
    hash = hash_backup_code(code)

    if hash in account.mfa_backup_hashes do
      remaining = List.delete(account.mfa_backup_hashes, hash)

      account
      |> Account.mfa_changeset(%{mfa_backup_hashes: remaining})
      |> Repo.update()

      Logger.warning("[MFA] #{account.email} used a backup code. #{length(remaining)} codes remaining")

      :ok
    else
      {:error, :invalid_code}
    end
  end
end
