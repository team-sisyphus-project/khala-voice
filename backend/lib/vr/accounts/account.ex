defmodule VR.Accounts.Account do
  @moduledoc """
  User account.

  ## Login methods

  - Email + password (always available)
  - Social login (only when the provider is enabled in the admin)

  Accounts registered via social login may have no `hashed_password`. Disabling that
  provider would then lock them out, so the admin goes through a confirmation step
  before turning it off.

  ## Deletion

  Not deleted immediately; `scheduled_deletion_at` is set to grant a grace period.
  Logging in within the grace period cancels it; once it passes, the `DeletionWorker` handles it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VR.IdGenerator

  @locales ~w(ko en ja es zh_CN zh_TW)

  @doc """
  Selectable transcription languages.

  **Must match the list on the frontend (`apps/web/src/lib/prefs.ts`).** If a value that
  exists on only one side gets saved, transcription fails entirely and credits are still spent.

  Chinese is `cmn-*`, not `zh-*` — that is how Google STT v2 codes it.
  """
  @transcribe_languages ~w(
    ko-KR en-US en-GB ja-JP cmn-Hans-CN cmn-Hant-TW es-ES fr-FR de-DE vi-VN
  )
  # Themes the user picks. Not a system admin setting.
  @themes ~w(light dark pencil-warm game)
  @deletion_grace_days 14

  @derive {Jason.Encoder,
           only: [
             :id,
             :email,
             :name,
             :locale,
             :transcribe_language,
             :country,
             :time_zone,
             :confirmed_at,
             :is_admin,
             :theme,
             :inserted_at
           ]}

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "accounts" do
    field :email, :string
    field :hashed_password, :string, redact: true
    field :name, :string
    field :confirmed_at, :utc_datetime

    # UI display language of the app. **Distinct from the transcription language (`transcribe_language`).**
    # The default for new accounts is English — the app ships English-first.
    field :locale, :string, default: "en"
    field :country, :string
    field :time_zone, :string

    # Social login
    field :is_social, :boolean, default: false
    field :social_provider, :string
    field :social_id, :string

    field :is_admin, :boolean, default: false

    # Temporary admin auto-created at install time. The normal procedure is to delete it after promoting a real user.
    field :is_bootstrap, :boolean, default: false

    # Per-user screen theme. Not a system admin setting.
    field :theme, :string, default: "light"
    # Default transcription language. **nil = automatic** (follows the browser language).
    # Distinct from the UI language (`locale`) — transcription uses STT codes (`cmn-Hans-CN`, etc.).
    field :transcribe_language, :string

    # Two-factor authentication — system admins only. Not exposed to regular users.
    field :mfa_secret, VR.Encrypted.Binary, source: :mfa_secret_encrypted, redact: true
    field :mfa_enabled, :boolean, default: false
    field :mfa_enabled_at, :utc_datetime
    field :mfa_backup_hashes, {:array, :string}, default: [], redact: true

    # Scheduled deletion
    field :deleted_at, :utc_datetime
    field :scheduled_deletion_at, :utc_datetime

    # Virtual fields
    field :password, :string, virtual: true, redact: true
    field :invite_code, :string, virtual: true

    timestamps(type: :utc_datetime)
  end

  def locales, do: @locales

  def transcribe_languages, do: @transcribe_languages
  def themes, do: @themes
  def deletion_grace_days, do: @deletion_grace_days

  @doc """
  Email + password registration.

  ## Options
  - `:hash_password` — if false, skips hashing (when only validating)
  """
  def registration_changeset(account, attrs, opts \\ []) do
    account
    |> cast(attrs, [:email, :password, :name, :locale, :country, :time_zone, :invite_code])
    |> put_id()
    |> validate_email()
    |> validate_password(opts)
    |> validate_name()
    |> validate_locale()
  end

  @doc "Social login registration. No password."
  def social_registration_changeset(account, attrs) do
    account
    |> cast(attrs, [:email, :name, :social_provider, :social_id, :locale, :country, :time_zone])
    |> put_id()
    |> put_change(:is_social, true)
    |> validate_required([:social_provider, :social_id])
    |> validate_email()
    |> validate_name()
    |> validate_locale()
    # The social provider has already verified the email
    |> put_change(:confirmed_at, DateTime.utc_now(:second))
  end

  @doc "Profile update."
  def profile_changeset(account, attrs) do
    account
    |> cast(attrs, [:name, :locale, :country, :time_zone, :theme, :transcribe_language])
    |> validate_inclusion(:transcribe_language, @transcribe_languages, message: "is not a supported language")
    |> validate_name()
    |> validate_locale()
    |> validate_inclusion(:theme, @themes, message: "is not a known theme")
  end

  @doc """
  Changes the default transcription language.

  `nil` means **automatic** — it follows the browser language. An empty string is also
  treated as automatic (when the form sends an empty value).
  """
  def transcribe_language_changeset(account, language) do
    normalized = if language in [nil, ""], do: nil, else: language

    account
    |> cast(%{transcribe_language: normalized}, [:transcribe_language])
    |> validate_inclusion(:transcribe_language, @transcribe_languages, message: "is not a supported language")
  end

  @doc "Changes only the theme. Used to save immediately without going through the profile form."
  def theme_changeset(account, theme) do
    account
    |> cast(%{theme: theme}, [:theme])
    |> validate_inclusion(:theme, @themes, message: "is not a known theme")
  end

  @doc """
  Changes only the UI display language. Used to save immediately without going through the profile form.

  **Distinct from the transcription language (`transcribe_language`)** — the UI language
  uses `locale` codes (`ko`, `en`, etc.).
  """
  def locale_changeset(account, locale) do
    account
    # empty_values: [] accepts empty strings as-is — at the API boundary an empty
    # value is explicitly rejected, not ignored as a no-op.
    |> cast(%{locale: locale}, [:locale], empty_values: [])
    |> validate_required([:locale])
    |> validate_locale()
  end

  @doc "MFA settings. Used only for system admins."
  def mfa_changeset(account, attrs) do
    cast(account, attrs, [:mfa_secret, :mfa_enabled, :mfa_enabled_at, :mfa_backup_hashes])
  end

  @doc "Password change or initial setup (including a social-only account adding a password)."
  def password_changeset(account, attrs, opts \\ []) do
    account
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_password(opts)
  end

  @doc "Email change."
  def email_changeset(account, attrs) do
    account
    |> cast(attrs, [:email])
    |> validate_email()
    |> case do
      %{changes: %{email: _}} = changeset -> changeset
      changeset -> add_error(changeset, :email, "is the same as before")
    end
  end

  @doc "Marks email confirmation as complete."
  def confirm_changeset(account) do
    change(account, confirmed_at: DateTime.utc_now(:second))
  end

  # ── Validation ───────────────────────────────────────────

  defp put_id(changeset) do
    case get_field(changeset, :id) do
      nil -> put_change(changeset, :id, IdGenerator.generate(:account))
      "" -> put_change(changeset, :id, IdGenerator.generate(:account))
      _ -> changeset
    end
  end

  defp validate_email(changeset) do
    changeset
    |> validate_required([:email])
    |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+\.[^@,;\s]+$/, message: "is not a valid email address")
    |> validate_length(:email, max: 160)
    |> unsafe_validate_unique(:email, VR.Repo)
    |> unique_constraint(:email)
  end

  defp validate_name(changeset) do
    changeset
    |> update_change(:name, &String.trim/1)
    |> validate_length(:name, min: 1, max: 80)
  end

  defp validate_locale(changeset) do
    validate_inclusion(changeset, :locale, @locales)
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 10, max: 72, message: "must be at least 10 characters")
    |> maybe_hash_password(opts)
  end

  defp maybe_hash_password(changeset, opts) do
    hash? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash? && password && changeset.valid? do
      changeset
      # bcrypt truncates anything beyond 72 bytes. Block it up front.
      |> validate_length(:password, max: 72, count: :bytes)
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  @doc """
  Password verification. Takes **the same amount of time** even when the account or
  password is missing. Prevents leaking account existence through response-time differences.
  """
  def valid_password?(%__MODULE__{hashed_password: hashed}, password)
      when is_binary(hashed) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hashed)
  end

  def valid_password?(_account, _password) do
    Bcrypt.no_user_verify()
    false
  end

  @doc "Can this account log in with a password? False for social-only accounts."
  def password_login?(%__MODULE__{hashed_password: hashed}), do: is_binary(hashed)
end
