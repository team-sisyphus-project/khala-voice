defmodule VR.Vault do
  @moduledoc """
  Cloak Vault — DB에 저장되는 민감 값의 암호화/복호화.

  **출처: sisyphus** `lib/sisyphus/vault.ex` — 그대로.

  AES-256-GCM을 사용하며 키는 `CLOAK_KEY` 환경변수에서 읽는다.
  Base64로 인코딩된 32바이트(256비트) 값이어야 한다.

      openssl rand -base64 32

  키가 없거나 형식이 틀리면 **부팅에 실패한다.** 기본 키를 만들지 않는다.
  이 앱은 오픈소스로 공개되므로, 기본 키가 존재하면 그 자체가 취약점이 된다.

  직접 쓸 일은 거의 없다. Ecto 스키마에서 `VR.Encrypted.Binary` 타입을 쓰면
  저장/로드 시 자동으로 처리된다.

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
        CLOAK_KEY 환경변수가 없습니다.

        DB에 저장되는 API 키를 암호화하는 데 필요합니다. 다음으로 생성하세요:

            openssl rand -base64 32

        기본 키는 제공하지 않습니다. 이 리포는 공개되므로 기본 키가 있으면
        모든 배포본의 암호화가 무력화됩니다.
        """

      value ->
        case Base.decode64(String.trim(value)) do
          {:ok, key} when byte_size(key) == 32 ->
            key

          {:ok, key} ->
            raise "CLOAK_KEY는 32바이트여야 합니다 (현재 #{byte_size(key)}바이트). " <>
                    "openssl rand -base64 32 로 다시 생성하세요."

          :error ->
            raise "CLOAK_KEY가 올바른 Base64가 아닙니다. openssl rand -base64 32 로 생성하세요."
        end
    end
  end
end
