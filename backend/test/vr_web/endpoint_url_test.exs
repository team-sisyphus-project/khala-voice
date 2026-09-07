defmodule VRWeb.EndpointURLTest do
  @moduledoc """
  What the app *claims to be*, as opposed to what it listens on.

  `VR.RuntimeConfigTest` proves `config/runtime.exs` resolves `url: [scheme:,
  port:]` from the environment. This test joins that to the other end: it takes
  the config runtime.exs actually produces for a given environment and asks the
  running Endpoint what URLs it hands out — the Khala OAuth `redirect_uri`, the
  MCP metadata `resource`, and the invite link a user copies off the friends
  screen.

  Those three break loudly on a plain-HTTP preview. An `https://` link to an
  origin that only answers over HTTP is a dead link, and a `redirect_uri` that
  does not match the one registered with Khala is a rejected authorization.
  Pinning `url:` to https/443 — which is what this used to do — makes all three
  wrong at once while the app itself looks healthy.

  `async: false`: the Endpoint's config is swapped process-wide and restored in
  `on_exit`, and env vars are set process-wide while runtime.exs is read.
  """
  use VRWeb.ConnCase, async: false

  @runtime_exs Path.expand("../../config/runtime.exs", __DIR__)

  # What a release always has. Held constant so each case varies only the
  # public-URL variables it is actually about.
  @prod_required %{
    "DATABASE_URL" => "ecto://user:pass@localhost/vr_test",
    "SECRET_KEY_BASE" => String.duplicate("a", 64),
    "CLOAK_KEY" => Base.encode64(String.duplicate("k", 32))
  }

  # Cleared before every read so a value in the developer's own shell cannot
  # colour the result.
  @cleared ~w(PHX_HOST PHX_SCHEME PHX_URL_PORT PORT HTTPS_PORT DEV_BIND_ALL
              PHX_SERVER RELEASE_COMMAND)

  setup do
    original = Application.get_env(:vr, VRWeb.Endpoint)

    on_exit(fn ->
      Application.put_env(:vr, VRWeb.Endpoint, original)
      VRWeb.Endpoint.config_change([{VRWeb.Endpoint, original}], [])
    end)

    {:ok, original: original}
  end

  # Reads config/runtime.exs in :prod under the given environment and returns
  # the `url:` keyword it resolved to. This is the half that can regress — a
  # literal `scheme: "https"` back in runtime.exs fails every case below.
  defp resolve_url!(env) do
    env = Map.merge(@prod_required, env)
    names = Enum.uniq(@cleared ++ Map.keys(env))
    previous = Map.new(names, &{&1, System.get_env(&1)})

    try do
      Enum.each(@cleared, &System.delete_env/1)

      Enum.each(env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      @runtime_exs
      |> Config.Reader.read!(env: :prod)
      |> Keyword.fetch!(:vr)
      |> Keyword.fetch!(VRWeb.Endpoint)
      |> Keyword.fetch!(:url)
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end

  # Applies that config to the live Endpoint and re-warms its cached URL — the
  # same path an OTP config change takes at runtime.
  defp serve_as!(original, env) do
    changed = Keyword.put(original, :url, resolve_url!(env))
    Application.put_env(:vr, VRWeb.Endpoint, changed)
    VRWeb.Endpoint.config_change([{VRWeb.Endpoint, changed}], [])
    :ok
  end

  describe "a plain-HTTP preview (PHX_SCHEME=http)" do
    setup %{original: original} do
      serve_as!(original, %{"PHX_SCHEME" => "http", "PHX_HOST" => "preview.example.test"})
    end

    test "the base URL every consumer trims is http, with no port suffix" do
      # VRWeb.MCPAuth and VRWeb.API.KhalaController both call this and
      # String.trim_trailing("/") the result.
      assert VRWeb.Endpoint.url() == "http://preview.example.test"
    end

    test "the Khala OAuth callback is http — it must match what Khala registered" do
      assert url(~p"/khala/callback") == "http://preview.example.test/khala/callback"
    end

    test "the MCP resource metadata document points at http" do
      base = VRWeb.Endpoint.url() |> String.trim_trailing("/")

      assert base <> "/mcp" == "http://preview.example.test/mcp"
      assert base <> "/go/settings" == "http://preview.example.test/go/settings"
    end

    test "an invite link is http" do
      assert url(~p"/invite/abc123") == "http://preview.example.test/invite/abc123"
    end
  end

  describe "a plain-HTTP preview on a non-standard public port" do
    setup %{original: original} do
      serve_as!(original, %{
        "PHX_SCHEME" => "http",
        "PHX_HOST" => "preview.example.test",
        "PHX_URL_PORT" => "4000",
        # Listening on 4000 too — no proxy in front.
        "PORT" => "4000"
      })
    end

    test "the port is carried into every generated URL" do
      assert VRWeb.Endpoint.url() == "http://preview.example.test:4000"
      assert url(~p"/khala/callback") == "http://preview.example.test:4000/khala/callback"
    end
  end

  describe "the default deployment (neither variable set)" do
    setup %{original: original} do
      serve_as!(original, %{"PHX_HOST" => "voice.example.test"})
    end

    test "is unchanged — https, no port suffix" do
      assert VRWeb.Endpoint.url() == "https://voice.example.test"
      assert url(~p"/khala/callback") == "https://voice.example.test/khala/callback"
      assert url(~p"/invite/abc123") == "https://voice.example.test/invite/abc123"
    end

    test "the listen port does not leak into the public URL", %{original: original} do
      serve_as!(original, %{"PHX_HOST" => "voice.example.test", "PORT" => "4000"})

      assert VRWeb.Endpoint.url() == "https://voice.example.test"
    end
  end

  describe "the first screen over plain HTTP" do
    setup %{original: original} do
      serve_as!(original, %{"PHX_SCHEME" => "http", "PHX_HOST" => "preview.example.test"})
    end

    # `/` redirects to `/go/meetings`, which sends an unauthenticated visitor to
    # `/login`. None of those hops may upgrade the scheme: there is no
    # `force_ssl` in the pipeline, and this is what keeps it that way.
    test "GET / lands on a 200 login screen without ever leaving http", %{conn: conn} do
      first = get(conn, "/")
      assert redirected_to(first) == "/go/meetings"

      second = get(conn, "/go/meetings")
      assert redirected_to(second) == "/login"

      login = get(conn, "/login")
      assert response(login, 200)

      for hop <- [first, second] do
        location = hop |> get_resp_header("location") |> List.first()

        refute location =~ "https://",
               "a redirect upgraded the preview to https: #{location}"
      end
    end

    test "no response carries an HSTS header", %{conn: conn} do
      # An HSTS header served once over a preview hostname pins that host to
      # https in the browser for its whole max-age — outliving the preview.
      conn = get(conn, "/login")

      assert get_resp_header(conn, "strict-transport-security") == []
    end
  end
end
