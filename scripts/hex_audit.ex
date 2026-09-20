defmodule Oskol.HexAudit do
  @moduledoc false

  @blocking_severities [:SEVERITY_HIGH, :SEVERITY_CRITICAL]

  def runtime_apps(deps) do
    deps
    |> Enum.filter(&(&1.top_level && shipped?(&1)))
    |> Enum.reduce(MapSet.new(), &collect_runtime_apps/2)
  end

  def runtime_packages(deps, lock) do
    runtime_apps = runtime_apps(deps)

    lock
    |> Enum.flat_map(fn {app, entry} ->
      if MapSet.member?(runtime_apps, app) do
        case Hex.Utils.lock(entry) do
          %{name: name, version: version, repo: repo} ->
            [%{app: app, name: name, version: version, repo: repo}]

          nil ->
            []
        end
      else
        []
      end
    end)
    |> Enum.sort_by(& &1.name)
  end

  def blocking_findings(packages, advisory_lookup) do
    packages
    |> Enum.flat_map(fn package ->
      package
      |> advisory_lookup.()
      |> Enum.filter(&blocking_advisory?/1)
      |> Enum.map(&Map.put(&1, :package, package))
    end)
    |> Enum.uniq_by(&canonical_id/1)
    |> Enum.sort_by(&{&1.package.name, canonical_id(&1)})
  end

  def blocking_advisory?(advisory) do
    advisory[:severity] in @blocking_severities or
      (is_number(advisory[:cvss_score]) and advisory[:cvss_score] >= 7.0)
  end

  def canonical_id(advisory) do
    ids = [advisory[:id] | List.wrap(advisory[:aliases])]
    Enum.find(ids, &String.starts_with?(&1, "CVE-")) || advisory[:id]
  end

  def registry_advisories(package, {:ok, {status, _headers, body}})
      when status in 200..299 do
    case Enum.find(body.releases, &(&1.version == package.version)) do
      nil ->
        {:error, "#{package.name} #{package.version} is absent from the signed Hex registry"}

      release ->
        advisories =
          release
          |> Map.get(:advisory_indexes, [])
          |> Enum.map(&Enum.at(body.advisories || [], &1))
          |> Enum.reject(&is_nil/1)

        {:ok, advisories}
    end
  end

  def registry_advisories(package, {:ok, {status, _headers, _body}}) do
    {:error, "signed Hex registry fetch for #{package.name} returned HTTP #{status}"}
  end

  def registry_advisories(package, {:error, reason}) do
    {:error, "signed Hex registry fetch for #{package.name} failed: #{inspect(reason)}"}
  end

  defp collect_runtime_apps(dep, apps) do
    if MapSet.member?(apps, dep.app) or not shipped?(dep) do
      apps
    else
      Enum.reduce(dep.deps, MapSet.put(apps, dep.app), &collect_runtime_apps/2)
    end
  end

  defp shipped?(dep) do
    prod_dependency?(dep.opts[:only]) and dep.opts[:runtime] != false and dep.opts[:app] != false
  end

  defp prod_dependency?(nil), do: true
  defp prod_dependency?(:prod), do: true
  defp prod_dependency?(environments) when is_list(environments), do: :prod in environments
  defp prod_dependency?(_environment), do: false
end
