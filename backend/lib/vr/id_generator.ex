defmodule VR.IdGenerator do
  @moduledoc """
  Prefixed identifier generation.

  **Source: sisyphus** `lib/sisyphus/id_generator.ex` — only the prefix list was
  adapted for this app.

      VR.IdGenerator.generate(:account)
      #=> "acct_k3m9x7q2p8w4n6r1t5y0"

  ## Why not sequential integers

  - A glance at logs, URLs, or error messages tells you what an ID belongs to
  - Total user counts and creation order are not exposed
  - Knowing one ID does not let you guess another

  ## Format

      {prefix}_{20 lowercase base32 chars}

  12 bytes (96 bits) of randomness encoded as unpadded lowercase base32.
  Alphanumeric only, so it is safe anywhere — URLs, filenames, logs.
  """

  @prefixes %{
    account: "acct",
    account_session: "sess",
    account_token: "atkn",
    invite_code: "invc",
    friend_invitation: "finv",
    friendship: "frnd",
    meeting: "meet",
    recording_session: "mrss",
    shared_link: "slnk",
    guest_session: "gses",
    push_subscription: "push",
    topic: "topc",
    label: "labl",
    plan: "plan",
    plan_revision: "prev",
    subscription: "subs",
    credit_lot: "clot",
    credit_ledger_entry: "cled",
    credit_conversion_setting: "ccnv",
    billing_audit_log: "balg",
    khala_connection: "khcn",
    mcp_token: "mcpt"
  }

  @random_bytes 12

  @doc "Generates a new ID for the entity type."
  @spec generate(atom()) :: String.t()
  def generate(type) when is_map_key(@prefixes, type) do
    "#{@prefixes[type]}_#{random_suffix()}"
  end

  @doc "The prefix for a type."
  @spec prefix(atom()) :: String.t()
  def prefix(type) when is_map_key(@prefixes, type), do: @prefixes[type]

  @doc "Checks whether an ID belongs to the given type."
  @spec valid?(String.t() | nil, atom()) :: boolean()
  def valid?(nil, _type), do: false

  def valid?(id, type) when is_binary(id) and is_map_key(@prefixes, type) do
    String.starts_with?(id, @prefixes[type] <> "_")
  end

  def valid?(_id, _type), do: false

  @doc "All registered prefixes."
  def prefixes, do: @prefixes

  defp random_suffix do
    @random_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode32(case: :lower, padding: false)
  end
end
