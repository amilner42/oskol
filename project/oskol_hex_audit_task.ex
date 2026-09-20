defmodule Mix.Tasks.Oskol.HexAudit do
  @shortdoc "Fails on high/critical advisories in shipped Hex dependencies"

  @moduledoc """
  Audits only the Hex packages reachable in the production runtime graph.

  Hex 2.5 added security advisories to its signed registry and exposes them
  through `mix hex.audit`. That task reads every entry in `mix.lock`, though,
  including compiler and test tools. This task fetches the same signed records
  live, failing instead of falling back to a stale cache, and limits the verdict
  to dependencies that can be included in the release.

  Run it as `MIX_ENV=prod mix oskol.hex_audit` before a release. High and
  critical findings fail the task. Lower severities remain visible through the
  stricter, whole-lock `mix hex.audit` command when investigating dependencies.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    unless Mix.env() == :prod do
      Mix.raise("oskol.hex_audit must run with MIX_ENV=prod")
    end

    Hex.start()
    ensure_hex_advisories!()
    Code.require_file("scripts/hex_audit.ex")
    packages = Oskol.HexAudit.runtime_packages(Mix.Dep.load_and_cache(), Mix.Dep.Lock.read())
    package_names = Enum.map_join(packages, ", ", & &1.name)

    Mix.shell().info(
      "Hex runtime advisory audit: checking #{length(packages)} shipped packages: #{package_names}"
    )

    advisories = fetch_advisories!(packages)

    findings =
      Oskol.HexAudit.blocking_findings(packages, &Map.fetch!(advisories, package_key(&1)))

    if findings == [] do
      Mix.shell().info("Hex runtime advisory audit: clean (#{length(packages)} shipped packages)")
    else
      Enum.each(findings, &print_finding/1)
      Mix.raise("high/critical advisories found in shipped Hex dependencies")
    end
  end

  @doc false
  def fetch_advisories!(packages, fetcher \\ &Hex.Repo.get_package/3) do
    packages
    |> Task.async_stream(&fetch_package_advisories(&1, fetcher),
      max_concurrency: 8,
      ordered: false,
      timeout: 60_000
    )
    |> Enum.reduce(%{}, fn
      {:ok, {:ok, key, advisories}}, acc ->
        Map.put(acc, key, advisories)

      {:ok, {:error, message}}, _acc ->
        Mix.raise(message)

      {:exit, reason}, _acc ->
        Mix.raise("signed Hex registry fetch failed: #{inspect(reason)}")
    end)
  end

  defp fetch_package_advisories(package, fetcher) do
    case Oskol.HexAudit.registry_advisories(
           package,
           fetcher.(package.repo, package.name, nil)
         ) do
      {:ok, advisories} -> {:ok, package_key(package), advisories}
      {:error, message} -> {:error, message}
    end
  end

  defp package_key(package), do: {package.repo, package.name, package.version}

  defp print_finding(advisory) do
    package = advisory.package
    severity = advisory[:severity] |> to_string() |> String.replace_prefix("SEVERITY_", "")

    Mix.shell().error(
      "#{package.name} #{package.version}: #{Oskol.HexAudit.canonical_id(advisory)} " <>
        "(#{severity}) #{advisory[:summary]} #{advisory[:html_url]}"
    )
  end

  defp ensure_hex_advisories! do
    unless function_exported?(Hex.Repo, :get_package, 3) do
      Mix.raise("oskol.hex_audit requires Hex 2.5.1; run mix local.hex 2.5.1 --force")
    end
  end
end
