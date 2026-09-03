defmodule VR.Vault do
  @moduledoc """
  Cloak Vault — encryption/decryption of sensitive values stored in the DB.

  **Source: sisyphus** `lib/sisyphus/vault.ex` — verbatim.

  Uses AES-256-GCM; the key is read from the `CLOAK_KEY` environment variable.
  It must be a Base64-encoded 32-byte (256-bit) value.

      openssl rand -base64 32

  If the key is missing or malformed, **boot fails.** No default key is created.
  This app is published as open source, so a default key would itself be a
  vulnerability.

  You rarely use this directly. Using the `VR.Encrypted.Binary` type in an Ecto
  schema handles it automatically on store/load.

      field :api_key, VR.Encrypted.Binary, source: :api_key_encrypted
  """

  use Cloak.Vault, otp_app: :vr

  @impl GenServer
  def init(config) do
    config =
      Keyword.put(config, :ciphers,
        default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: decode_key!(), iv_length: 12}
      )

    {:ok, config}
  end

  defp decode_key! do
    case System.get_env("CLOAK_KEY") do
      nil ->
        raise """
        The CLOAK_KEY environment variable is missing.

        It is required to encrypt API keys stored in the DB. Generate one with:

            openssl rand -base64 32

        No default key is provided. This repo is public, so a default key would
        neutralize the encryption of every deployment.
        """

      value ->
        case Base.decode64(String.trim(value)) do
          {:ok, key} when byte_size(key) == 32 ->
            key

          {:ok, key} ->
            raise "CLOAK_KEY must be 32 bytes (currently #{byte_size(key)} bytes). " <>
                    "Regenerate it with: openssl rand -base64 32"

          :error ->
            raise "CLOAK_KEY is not valid Base64. Generate it with: openssl rand -base64 32"
        end
    end
  end
end
