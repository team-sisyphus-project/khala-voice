defmodule VR.EnvExampleTest do
  @moduledoc """
  Guard: every environment variable read by `config/runtime.exs` must be listed
  in the repo-root `.env.example`, and the template carries **names only** —
  never values. A developer copying `.env.example` should be able to identify
  every required runtime value before running migrations or the server.
  """
  use ExUnit.Case, async: true

  @runtime_exs Path.expand("../../config/runtime.exs", __DIR__)
  @env_example Path.expand("../../../.env.example", __DIR__)

  # Env vars read via a literal name in non-comment lines of runtime.exs.
  # Dynamic reads (`System.get_env(key)` inside the .env loader,
  # `System.get_env(name)` inside port_from_env) have no literal name and are
  # intentionally not captured.
  defp vars_read_by_runtime do
    @runtime_exs
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "#"))
    |> Enum.join("\n")
    |> then(
      &Regex.scan(
        ~r/(?:System\.get_env|port_from_env\.)\(\s*"([A-Z][A-Z0-9_]*)"/,
        &1,
        capture: :all_but_first
      )
    )
    |> List.flatten()
    |> MapSet.new()
  end

  defp vars_listed_in_example do
    @env_example
    |> File.read!()
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^([A-Z][A-Z0-9_]*)=/, line, capture: :all_but_first) do
        [name] -> [name]
        nil -> []
      end
    end)
    |> MapSet.new()
  end

  test "every env var read in runtime.exs is listed in .env.example" do
    missing = MapSet.difference(vars_read_by_runtime(), vars_listed_in_example())

    assert MapSet.size(missing) == 0,
           "runtime.exs reads env vars missing from .env.example: " <>
             Enum.join(Enum.sort(missing), ", ")
  end

  test ".env.example carries names only — no values on variable lines" do
    offenders =
      @env_example
      |> File.read!()
      |> String.split("\n")
      # A variable line is valid as `NAME=` optionally followed by whitespace
      # and a comment. Anything non-space right after `=` is a committed value.
      |> Enum.filter(&Regex.match?(~r/^[A-Z][A-Z0-9_]*=[^#\s]/, &1))

    assert offenders == [],
           ".env.example must not contain values: #{inspect(offenders)}"
  end
end
