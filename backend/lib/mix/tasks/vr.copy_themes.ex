defmodule Mix.Tasks.Vr.CopyThemes do
  @moduledoc """
  지연 로드용 테마 CSS 를 `priv/static/themes/` 로 복사한다.

  연필(66KB gzip)과 게임(10KB gzip)은 항상 싣기엔 무겁다.
  Tailwind 번들에 넣지 않고 사용자가 그 테마를 골랐을 때만 받는다.
  라이트·다크는 작아서 `app.css` 에 함께 들어간다.
  """
  @shortdoc "지연 로드 테마 CSS 를 정적 경로로 복사한다"

  use Mix.Task

  @lazy_themes ~w(pencil game)

  @impl Mix.Task
  def run(_args) do
    source = Path.expand("../../../assets/css/themes", __DIR__)
    dest = Path.expand("../../../priv/static/themes", __DIR__)

    File.mkdir_p!(dest)

    Enum.each(@lazy_themes, fn name ->
      from = Path.join(source, "#{name}.css")
      to = Path.join(dest, "#{name}.css")

      if File.exists?(from) do
        File.cp!(from, to)
      else
        Mix.shell().error("[themes] 원본을 찾지 못했습니다: #{from}")
      end
    end)

    :ok
  end
end
