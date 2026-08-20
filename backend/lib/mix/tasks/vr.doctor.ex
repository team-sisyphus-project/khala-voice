defmodule Mix.Tasks.Vr.Doctor do
  @moduledoc """
  개발 환경과 설정 상태를 점검한다.

      mix vr.doctor

  ## 왜 필요한가

  이 앱은 외부 의존이 많다 (FFmpeg · S3 · Google STT · LLM). 어느 하나가 빠져도
  그 기능만 조용히 죽는다. 무엇이 왜 안 되는지 한 화면에서 보여준다.

  운영 환경에서는 어드민 대시보드(`/_admin`)가 같은 내용을 보여준다.
  """
  @shortdoc "개발 환경과 설정을 점검한다"

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_args) do
    # 점검 결과만 보이게 한다. SQL 디버그 로그가 섞이면 읽을 수 없다.
    Logger.configure(level: :warning)

    Mix.shell().info("\n━━━ 시스템 도구 ━━━")
    binaries = check_binaries()

    Mix.shell().info("\n━━━ 데이터베이스 ━━━")
    check_database()

    Mix.shell().info("\n━━━ 필수 설정 ━━━")
    check_boot_config()

    Mix.shell().info("\n━━━ 기능별 준비 상태 ━━━")
    features = check_features()

    Mix.shell().info("\n━━━ 요약 ━━━")
    summarize(binaries, features)
  end

  # ── 시스템 도구 ──────────────────────────────────────────

  defp check_binaries do
    tools = [
      {"ffmpeg", "오디오 분할 · MP3 변환", :required, "brew install ffmpeg"},
      {"ffprobe", "오디오 길이 확인", :required, "brew install ffmpeg"},
      {"gitleaks", "커밋 시 시크릿 차단", :recommended, "brew install gitleaks"}
    ]

    Enum.map(tools, fn {bin, purpose, level, install} ->
      found = System.find_executable(bin)

      cond do
        found ->
          line(:ok, bin, purpose)
          {bin, true}

        level == :required ->
          line(:error, bin, "#{purpose} — 없으면 전사가 실패합니다")
          Mix.shell().info("       설치: #{install}")
          {bin, false}

        true ->
          line(:warn, bin, "#{purpose} — 설치를 권합니다")
          Mix.shell().info("       설치: #{install}")
          {bin, false}
      end
    end)
  end

  # ── DB ───────────────────────────────────────────────────

  defp check_database do
    case Ecto.Adapters.SQL.query(VR.Repo, "SELECT 1", []) do
      {:ok, _} ->
        line(:ok, "연결", "정상")
        check_migrations()
        check_extensions()

      {:error, reason} ->
        line(:error, "연결", "실패 — #{inspect(reason)}")
    end
  rescue
    e -> line(:error, "연결", "실패 — #{Exception.message(e)}")
  end

  defp check_migrations do
    pending = Ecto.Migrator.migrations(VR.Repo) |> Enum.filter(&(elem(&1, 0) == :down))

    if pending == [] do
      line(:ok, "마이그레이션", "모두 적용됨")
    else
      line(:error, "마이그레이션", "#{length(pending)}개 미적용 — mix ecto.migrate")
    end
  end

  defp check_extensions do
    for ext <- ~w(citext pg_trgm) do
      case Ecto.Adapters.SQL.query(
             VR.Repo,
             "SELECT 1 FROM pg_extension WHERE extname = $1",
             [ext]
           ) do
        {:ok, %{num_rows: 1}} -> line(:ok, ext, "설치됨")
        _ -> line(:error, ext, "없음 — 마이그레이션을 다시 실행하세요")
      end
    end
  end

  # ── 부팅 필수 설정 ───────────────────────────────────────

  defp check_boot_config do
    for {name, env} <- [
          {"DATABASE_URL", "DATABASE_URL"},
          {"SECRET_KEY_BASE", "SECRET_KEY_BASE"},
          {"CLOAK_KEY", "CLOAK_KEY"}
        ] do
      if System.get_env(env) in [nil, ""] do
        line(:error, name, "없음")
      else
        line(:ok, name, "설정됨")
      end
    end
  end

  # ── 기능별 ───────────────────────────────────────────────

  defp check_features do
    statuses = VR.Config.feature_status()

    # 전사와 같은 이유로 실제 판정을 쓴다 — 개발 모드면 키 없이도 동작한다.
    summary_ready = VR.Summarize.ready?()

    # 전사는 설정만이 아니라 FFmpeg·개발모드까지 본 실제 판정으로 덮는다.
    # 키가 다 있어도 FFmpeg 이 없으면 실패하고, 개발 모드면 키 없이도 동작한다.
    statuses =
      statuses
      |> Enum.map(fn
        %{feature: :transcription} = status ->
          cond do
            VR.Transcription.ready?() ->
              %{status | ready: true, missing: []}

            not VR.Transcription.Audio.available?() ->
              %{status | missing: status.missing ++ [%{label: "FFmpeg"}]}

            true ->
              status
          end

        status ->
          status
      end)
      |> Kernel.++([
        %{feature: :summary, ready: summary_ready, missing: llm_missing(summary_ready)}
      ])

    Enum.each(statuses, fn s ->
      label = feature_label(s.feature)

      if s.ready do
        line(:ok, label, "동작 중")
      else
        names = s.missing |> Enum.map(& &1.label) |> Enum.join(", ")
        line(:warn, label, "미설정 — 필요: #{names}")
      end
    end)

    social = VR.Auth.Providers.list_active()

    if social == [] do
      line(:info, "소셜 로그인", "없음 (이메일+비밀번호만 사용)")
    else
      line(:ok, "소셜 로그인", social |> Enum.map(& &1.display_name) |> Enum.join(", "))
    end

    statuses
  end

  defp llm_missing(true), do: []
  defp llm_missing(false), do: [%{label: "LLM API 키"}]

  defp feature_label(:storage), do: "녹음 업로드"
  defp feature_label(:transcription), do: "전사"
  defp feature_label(:summary), do: "AI 요약"
  defp feature_label(:mail), do: "메일 발송"
  defp feature_label(:push), do: "웹 푸시"
  defp feature_label(other), do: to_string(other)

  # ── 요약 ─────────────────────────────────────────────────

  defp summarize(binaries, features) do
    missing_bins = binaries |> Enum.reject(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))
    blocked = Enum.reject(features, & &1.ready)

    cond do
      missing_bins == [] and blocked == [] ->
        Mix.shell().info("  ✅ 전부 준비되었습니다.\n")

      true ->
        if missing_bins != [] do
          Mix.shell().info("  누락된 도구: #{Enum.join(missing_bins, ", ")}")
        end

        if blocked != [] do
          names = blocked |> Enum.map(&feature_label(&1.feature)) |> Enum.join(", ")
          Mix.shell().info("  미설정 기능: #{names}")
        end

        Mix.shell().info("""

          설정을 넣는 곳:
            로컬   .env                 (docs/00-setup-checklist.md 참고)
            운영   /_admin 어드민 화면   (DB에 암호화 저장, .env 보다 우선)
        """)
    end
  end

  # ── 출력 ─────────────────────────────────────────────────

  defp line(status, label, detail) do
    mark =
      case status do
        :ok -> "  ✅"
        :warn -> "  ⚠️ "
        :error -> "  ❌"
        :info -> "  ·  "
      end

    Mix.shell().info("#{mark} #{String.pad_trailing(label, 18)} #{detail}")
  end
end
