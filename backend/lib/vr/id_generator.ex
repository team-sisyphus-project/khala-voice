defmodule VR.IdGenerator do
  @moduledoc """
  접두사가 붙은 식별자 생성.

  **출처: sisyphus** `lib/sisyphus/id_generator.ex` — 접두사 목록만 이 앱에 맞게 바꿨다.

      VR.IdGenerator.generate(:account)
      #=> "acct_k3m9x7q2p8w4n6r1t5y0"

  ## 왜 순차 정수를 쓰지 않는가

  - 로그·URL·오류 메시지만 봐도 무엇의 ID인지 바로 안다
  - 총 사용자 수나 생성 순서가 노출되지 않는다
  - ID를 하나 알아도 다른 ID를 추측할 수 없다

  ## 형식

      {접두사}_{base32 소문자 20자}

  12바이트(96비트) 난수를 패딩 없는 base32 소문자로 인코딩한다.
  영숫자만 나오므로 URL·파일명·로그 어디에 넣어도 안전하다.
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

  @doc "엔티티 타입에 맞는 새 ID를 만든다."
  @spec generate(atom()) :: String.t()
  def generate(type) when is_map_key(@prefixes, type) do
    "#{@prefixes[type]}_#{random_suffix()}"
  end

  @doc "타입의 접두사."
  @spec prefix(atom()) :: String.t()
  def prefix(type) when is_map_key(@prefixes, type), do: @prefixes[type]

  @doc "ID가 해당 타입의 것인지 확인한다."
  @spec valid?(String.t() | nil, atom()) :: boolean()
  def valid?(nil, _type), do: false

  def valid?(id, type) when is_binary(id) and is_map_key(@prefixes, type) do
    String.starts_with?(id, @prefixes[type] <> "_")
  end

  def valid?(_id, _type), do: false

  @doc "등록된 접두사 전체."
  def prefixes, do: @prefixes

  defp random_suffix do
    @random_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode32(case: :lower, padding: false)
  end
end
