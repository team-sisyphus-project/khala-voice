defmodule VR.Accounts.Notifier do
  @moduledoc """
  Account-related email delivery.

  The body contains **only links carrying a token.** Passwords and other sensitive
  information are never written into emails. Email is often stored and relayed in plain text.
  """

  import Swoosh.Email

  alias VR.Config
  alias VR.Mailer

  # No default value. Without the address there is no link to put in the email,
  # and sending nothing is better than sending a broken link.
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

  # If there is no sending domain, do not send. Sending from an arbitrary address
  # gets flagged as spam or bounced, and nobody ever finds out.
  defp from_address do
    case Config.fetch("mail.domain") do
      nil -> {:error, {:missing_config, "mail.domain"}}
      "" -> {:error, {:missing_config, "mail.domain"}}
      domain -> {:ok, "noreply@#{domain}"}
    end
  end

  def deliver_confirmation(account, token) do
    with {:ok, base} <- base_url() do
      deliver(account.email, "[KHALA VOICE] Please confirm your email address", """

      Hello#{name_suffix(account)},

      Open the link below to complete your email confirmation.

      #{base}/confirm/#{token}

      This link is valid for 7 days.
      If you did not sign up, please ignore this email.
      """)
    end
  end

  def deliver_reset_password(account, token) do
    with {:ok, base} <- base_url() do
      deliver(account.email, "[KHALA VOICE] Password reset", """

      Hello#{name_suffix(account)},

      You can set a new password at the link below.

      #{base}/reset-password/#{token}

      This link expires in 1 hour.
      If you did not request this, please ignore this email. Your password will remain unchanged.
      """)
    end
  end

  def deliver_friend_invitation(email, inviter, token, message \\ nil) do
    with {:ok, base} <- base_url() do
      deliver(email, "[KHALA VOICE] #{inviter_name(inviter)} invited you as a friend", """

      #{inviter_name(inviter)} has invited you as a friend on KHALA VOICE.
      #{if message, do: "\nMessage: #{message}\n", else: ""}
      You can accept at the link below.

      #{base}/invite/#{token}

      This link is valid for 14 days.
      """)
    end
  end

  def deliver_password_setup_required(account, token, reason) do
    with {:ok, base} <- base_url() do
      deliver(account.email, "[KHALA VOICE] Please set a password", """

      Hello#{name_suffix(account)},

      #{reason}

      Set a password at the link below and you will be able to log in with your email.

      #{base}/reset-password/#{token}

      This link expires in 1 hour.
      """)
    end
  end

  defp name_suffix(%{name: nil}), do: ""
  defp name_suffix(%{name: ""}), do: ""
  defp name_suffix(%{name: name}), do: " #{name}"

  defp inviter_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp inviter_name(%{email: email}), do: email
end
