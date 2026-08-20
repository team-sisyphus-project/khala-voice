defmodule VRWeb.OAuthController do
  @moduledoc """
  소셜 로그인 진입과 콜백.

  **꺼진 제공자는 404로 응답한다.** 어드민에서 끄면 라우트 자체가 없는 것처럼 보인다.
  """

  use VRWeb, :controller

  alias VR.Accounts
  alias VR.Auth.{OAuth, Providers}
  alias VRWeb.UserAuth

  require Logger

  def request(conn, %{"provider" => provider}) do
    with true <- OAuth.supported?(provider),
         config when not is_nil(config) <- Providers.get(provider),
         true <- config.active,
         true <- is_binary(config.resolved_redirect_uri) do
      state = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

      conn
      |> put_session(:oauth_state, state)
      |> put_session(:oauth_provider, provider)
      |> redirect(external: OAuth.authorize_url(provider, config, state))
    else
      _ -> not_found(conn)
    end
  end

  def callback(conn, %{"provider" => provider, "code" => code, "state" => state}) do
    expected = get_session(conn, :oauth_state)
    expected_provider = get_session(conn, :oauth_provider)

    conn = conn |> delete_session(:oauth_state) |> delete_session(:oauth_provider)

    cond do
      not OAuth.supported?(provider) ->
        not_found(conn)

      is_nil(expected) or not secure_compare(state, expected) or expected_provider != provider ->
        # state 불일치 = CSRF 시도이거나 세션 만료
        fail(conn, "인증 요청이 유효하지 않습니다. 다시 시도해 주세요.")

      true ->
        config = Providers.get(provider)

        if config && config.active do
          complete(conn, provider, config, code)
        else
          not_found(conn)
        end
    end
  end

  # 사용자가 제공자 화면에서 취소한 경우
  def callback(conn, %{"provider" => _provider}) do
    fail(conn, "소셜 로그인이 취소되었습니다")
  end

  defp complete(conn, provider, config, code) do
    case OAuth.fetch_profile(provider, config, code) do
      {:ok, %{provider_id: provider_id, email: email} = profile} when is_binary(email) ->
        case Accounts.find_or_create_social_account(provider, provider_id, %{
               email: email,
               name: profile[:name]
             }) do
          {:ok, account} ->
            Accounts.record_login_attempt(email, client_ip(conn), true)
            UserAuth.log_in_account(conn, account)

          {:error, changeset} ->
            Logger.warning("[OAuth] 계정 생성 실패: #{inspect(changeset.errors)}")
            fail(conn, "계정을 만들지 못했습니다. 이미 다른 방식으로 가입된 이메일일 수 있습니다.")
        end

      {:ok, _profile} ->
        # 이메일 없이는 계정을 식별할 수 없다
        fail(conn, "이메일 정보를 가져오지 못했습니다. 제공자에서 이메일 공개를 허용해 주세요.")

      {:error, reason} ->
        Logger.warning("[OAuth] 프로필 조회 실패: #{provider} #{inspect(reason)}")
        fail(conn, "소셜 로그인에 실패했습니다. 잠시 후 다시 시도해 주세요.")
    end
  end

  defp fail(conn, message) do
    conn |> put_flash(:error, message) |> redirect(to: ~p"/login")
  end

  defp not_found(conn) do
    conn |> put_status(:not_found) |> text("Not Found") |> halt()
  end

  # 타이밍 공격을 피해 상수 시간으로 비교한다
  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    byte_size(a) == byte_size(b) and :crypto.hash_equals(a, b)
  end

  defp secure_compare(_a, _b), do: false

  defp client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [value | _] -> value |> String.split(",") |> List.first() |> String.trim()
      [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
