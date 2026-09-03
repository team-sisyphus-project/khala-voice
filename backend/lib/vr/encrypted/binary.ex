defmodule VR.Encrypted.Binary do
  @moduledoc """
  Binary field type stored encrypted with Cloak.

      field :client_secret, VR.Encrypted.Binary, source: :client_secret_encrypted
  """
  use Cloak.Ecto.Binary, vault: VR.Vault
end
