defmodule VR.Accounts.Notifier do
  @moduledoc """
  계정 관련 메일 발송.

  본문에는 **토큰이 담긴 링크만** 넣는다. 비밀번호나 다른 민감 정보를 메일에 쓰지 않는다.
  메일은 평문으로 저장·전달되는 경로가 많다.
  """

  import Swoosh.Email

  alias VR.Config
  alias VR.Mailer

  # 기본값을 두지 않는다. 주소를 모르면 메일에 넣을 링크가 없고,
  # 잘못된 링크를 보내는 것보다 보내지 않는 편이 낫다.
  defp base_url do
    case Config.fetch("app.base_url") do
      nil -> {:error, {:missing_config, "app.base_url"}}
      "" -> {:error, {:missing_config, "app.base_url"}}
      url -> {:ok, String.trim_trailing(url, "/")}
    end
  end

  defp deliver(to, subject, body) do
    with {:ok, from} <- from_address() do
      email =
        new()
        |> to(to)
        |> from({"KHALA VOICE", from})
        |> subject(subject)
        |> text_body(body)

      case Mailer.deliver(email) do
        {:ok, _} -> {:ok, email}
        error -> error
      end
    end
  end

  # 발송 도메인이 없으면 보내지 않는다. 아무 주소로나 보내면
  # 스팸 처리되거나 반송되고, 그 사실을 아무도 모른 채 지나간다.
  defp from_address do
    case Config.fetch("mail.domain") do
      nil -> {:error, {:missing_config, "mail.domain"}}
      "" -> {:error, {:missing_config, "mail.domain"}}
      domain -> {:ok, "noreply@#{domain}"}
    end
  end

  def deliver_confirmation(account, token) do
    with {:ok, base} <- base_url() do
      deliver(account.email, "[KHALA VOICE] 이메일 주소를 확인해 주세요", """

      안녕하세요#{name_suffix(account)},

      아래 링크를 열면 이메일 확인이 완료됩니다.

      #{base}/confirm/#{token}

      이 링크는 7일간 유효합니다.
      가입한 적이 없다면 이 메일을 무시하세요.
      """)
    end
  end

  def deliver_reset_password(account, token) do
    with {:ok, base} <- base_url() do
      deliver(account.email, "[KHALA VOICE] 비밀번호 재설정", """

      안녕하세요#{name_suffix(account)},

      아래 링크에서 비밀번호를 새로 설정할 수 있습니다.

      #{base}/reset-password/#{token}

      이 링크는 1시간 뒤 만료됩니다.
      요청한 적이 없다면 이 메일을 무시하세요. 비밀번호는 그대로 유지됩니다.
      """)
    end
  end

  def deliver_friend_invitation(email, inviter, token, message \\ nil) do
    with {:ok, base} <- base_url() do
      deliver(email, "[KHALA VOICE] #{inviter_name(inviter)}님이 친구로 초대했습니다", """

      #{inviter_name(inviter)}님이 KHALA VOICE에서 친구로 초대했습니다.
      #{if message, do: "\n남긴 말: #{message}\n", else: ""}
      아래 링크에서 수락할 수 있습니다.

      #{base}/invite/#{token}

      이 링크는 14일간 유효합니다.
      """)
    end
  end

  def deliver_password_setup_required(account, token, reason) do
    with {:ok, base} <- base_url() do
      deliver(account.email, "[KHALA VOICE] 비밀번호를 설정해 주세요", """

      안녕하세요#{name_suffix(account)},

      #{reason}

      아래 링크에서 비밀번호를 설정하면 이메일로 로그인할 수 있습니다.

      #{base}/reset-password/#{token}

      이 링크는 1시간 뒤 만료됩니다.
      """)
    end
  end

  defp name_suffix(%{name: nil}), do: ""
  defp name_suffix(%{name: ""}), do: ""
  defp name_suffix(%{name: name}), do: " #{name}님"

  defp inviter_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp inviter_name(%{email: email}), do: email
end
