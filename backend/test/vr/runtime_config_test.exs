defmodule VR.RuntimeConfigTest do
  @moduledoc """
  `config/runtime.exs` 의 포트 해석 규칙 회귀 테스트.

  이 테스트는 앱을 띄우지 않는다. `Config.Reader` 로 config 파일을 평가해서
  나온 키워드 트리를 본다. 즉 "Endpoint 가 실제로 그 포트에서 listen 하는가"가
  아니라 "설정이 그 값으로 해석되는가"를 검증한다.

  환경변수를 프로세스 전역으로 잠시 덮어쓰므로 `async: false`.
  """
  use ExUnit.Case, async: false

  @runtime_exs Path.expand("../../config/runtime.exs", __DIR__)

  # 프로덕션 분기가 요구하는 필수값. 포트와 무관하게 항상 채워 둔다.
  @prod_required %{
    "DATABASE_URL" => "ecto://user:pass@localhost/vr_test",
    "SECRET_KEY_BASE" => String.duplicate("a", 64),
    "CLOAK_KEY" => Base.encode64(String.duplicate("k", 32))
  }

  # 포트에 영향을 주는 변수는 매 케이스마다 명시적으로 비워서 시작한다.
  @port_vars ~w(PORT HTTPS_PORT DEV_BIND_ALL PHX_SERVER)

  defp with_env(overrides, fun) do
    vars = Map.keys(@prod_required) ++ @port_vars ++ Map.keys(overrides)
    original = Map.new(vars, &{&1, System.get_env(&1)})

    try do
      Enum.each(@port_vars, &System.delete_env/1)
      Enum.each(@prod_required, fn {k, v} -> System.put_env(k, v) end)

      Enum.each(overrides, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      fun.()
    after
      Enum.each(original, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end
  end

  defp read!(env), do: Config.Reader.read!(@runtime_exs, env: env)

  defp endpoint(env) do
    read!(env)
    |> Keyword.fetch!(:vr)
    |> Keyword.fetch!(VRWeb.Endpoint)
  end

  defp prod_http_port, do: endpoint(:prod) |> Keyword.fetch!(:http) |> Keyword.fetch!(:port)

  describe "prod / PORT 가 없거나 비어 있을 때" do
    test "PORT 없이도 raise 하지 않고 4000 으로 해석된다 (M1, M2)" do
      with_env(%{"PORT" => nil}, fn ->
        assert prod_http_port() == 4000
      end)
    end

    test "PORT='' 는 4000 (M3)" do
      with_env(%{"PORT" => ""}, fn ->
        assert prod_http_port() == 4000
      end)
    end

    test "PORT='   ' 는 4000 (M3)" do
      with_env(%{"PORT" => "   "}, fn ->
        assert prod_http_port() == 4000
      end)
    end
  end

  describe "prod / PORT 에 값이 주어졌을 때" do
    test "주입된 값이 기본값을 이긴다 (M4)" do
      with_env(%{"PORT" => "8080"}, fn ->
        assert prod_http_port() == 8080
      end)
    end

    test "앞뒤 공백과 개행은 무시한다 (M5)" do
      with_env(%{"PORT" => " 8080\n"}, fn ->
        assert prod_http_port() == 8080
      end)
    end

    test "0.0.0.0 바인딩은 그대로 유지된다" do
      with_env(%{"PORT" => "8080"}, fn ->
        assert endpoint(:prod) |> Keyword.fetch!(:http) |> Keyword.fetch!(:ip) == {0, 0, 0, 0}
      end)
    end
  end

  describe "prod / PORT 형식이 틀렸을 때" do
    # 비어 있는 것은 "안 정했다", 형식이 틀린 것은 "잘못 정했다".
    # 후자를 4000 으로 삼키면 배포는 뜬 것처럼 보이고 헬스체크만 실패한다.
    for bad <- ["abc", "8080a", "0", "99999", "-1", "tcp://host:8080", "80.5"] do
      test "PORT=#{inspect(bad)} 는 PORT 를 지목하며 멈춘다 (M10)" do
        with_env(%{"PORT" => unquote(bad)}, fn ->
          err = assert_raise RuntimeError, fn -> prod_http_port() end
          assert err.message =~ "PORT"
          assert err.message =~ unquote(bad)
        end)
      end
    end
  end

  describe "prod / 진짜 필수값" do
    test "SECRET_KEY_BASE 가 없으면 여전히 멈춘다 (M11)" do
      with_env(%{"SECRET_KEY_BASE" => nil, "PORT" => "8080"}, fn ->
        assert_raise RuntimeError, ~r/SECRET_KEY_BASE/, fn -> prod_http_port() end
      end)
    end

    test "DATABASE_URL 이 없으면 여전히 멈춘다 (M11)" do
      with_env(%{"DATABASE_URL" => nil, "PORT" => "8080"}, fn ->
        assert_raise RuntimeError, ~r/DATABASE_URL/, fn -> prod_http_port() end
      end)
    end
  end

  describe "dev" do
    defp dev_port(kind) do
      endpoint(:dev) |> Keyword.fetch!(kind) |> Keyword.fetch!(:port)
    end

    test "PORT 가 없으면 4000 (M6)" do
      with_env(%{"PORT" => nil}, fn -> assert dev_port(:http) == 4000 end)
    end

    test "PORT='' 여도 ArgumentError 없이 4000 (M6)" do
      # .env.example 을 그대로 복사하면 PORT= 로 빈 문자열이 올라온다.
      with_env(%{"PORT" => ""}, fn -> assert dev_port(:http) == 4000 end)
    end

    test "PORT 가 주어지면 그 값 (M6)" do
      with_env(%{"PORT" => "4100"}, fn -> assert dev_port(:http) == 4100 end)
    end

    test "DEV_BIND_ALL=true 이고 HTTPS_PORT 가 비어 있으면 4001 (M7)" do
      with_env(%{"DEV_BIND_ALL" => "true", "HTTPS_PORT" => ""}, fn ->
        assert dev_port(:https) == 4001
      end)
    end

    test "DEV_BIND_ALL=true + HTTPS_PORT 지정 (M7)" do
      with_env(%{"DEV_BIND_ALL" => "true", "HTTPS_PORT" => "4443"}, fn ->
        assert dev_port(:https) == 4443
      end)
    end

    test "DEV_BIND_ALL 이 꺼져 있으면 https 를 켜지 않는다" do
      with_env(%{"DEV_BIND_ALL" => nil, "HTTPS_PORT" => "4443"}, fn ->
        refute Keyword.has_key?(endpoint(:dev), :https)
      end)
    end
  end

  describe "회귀 방지 — 규칙이 한 곳에만 있는가" do
    @backend_root Path.expand("../..", __DIR__)
    @repo_root Path.expand("../../..", __DIR__)

    test "'environment variable PORT is missing' 가 남아 있지 않다 (M8)" do
      hits =
        Path.wildcard(Path.join(@backend_root, "config/*.exs"))
        |> Enum.filter(&(File.read!(&1) =~ "environment variable PORT is missing"))

      assert hits == []
    end

    test "PORT / HTTPS_PORT 를 언급하는 config 파일은 runtime.exs 뿐이다 (M12)" do
      referencing =
        Path.wildcard(Path.join(@backend_root, "config/*.exs"))
        |> Enum.filter(&(File.read!(&1) =~ ~r/"(PORT|HTTPS_PORT)"/))
        |> Enum.map(&Path.basename/1)

      assert referencing == ["runtime.exs"]
    end

    test "포트 파싱 함수는 runtime.exs 안에 하나만 정의된다 (M12)" do
      source = File.read!(Path.join(@backend_root, "config/runtime.exs"))
      assert length(Regex.scan(~r/port_from_env\s*=\s*fn/, source)) == 1
    end

    test "Dockerfile 이 runtime.exs 가 필요로 하는 config 파일을 모두 COPY 한다 (M9)" do
      # 규칙을 별도 config 파일로 빼면 릴리즈에 실려 가지 않아 부팅에서 터진다.
      # runtime.exs 가 다른 파일을 읽기 시작하면 이 테스트가 먼저 알려준다.
      refute File.read!(Path.join(@backend_root, "config/runtime.exs")) =~
               ~r/Code\.(eval|require)_file/

      assert File.read!(Path.join(@repo_root, "Dockerfile")) =~ "config/runtime.exs config/"
    end
  end
end
