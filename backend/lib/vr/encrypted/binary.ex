defmodule VR.Encrypted.Binary do
  @moduledoc """
  Cloak으로 암호화되어 저장되는 바이너리 필드 타입.

      field :client_secret, VR.Encrypted.Binary, source: :client_secret_encrypted
  """
  use Cloak.Ecto.Binary, vault: VR.Vault
end
