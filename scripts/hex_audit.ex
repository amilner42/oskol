defmodule Oskol.HexAudit do
  @moduledoc false

  @blocking_severities [:SEVERITY_HIGH, :SEVERITY_CRITICAL]
  @fetch_attempts 3

  def run! do
    unless Mix.env() == :prod do
      Mix.raise("Hex runtime audit must run with MIX_ENV=prod")
    end

    Hex.start()
    ensure_hex_advisories!()
    packages = runtime_packages(Mix.Dep.load_and_cache(), Mix.Dep.Lock.read())
    package_names = Enum.map_join(packages, ", ", & &1.name)

    Mix.shell().info(
      "Hex runtime advisory audit: checking #{length(packages)} shipped packages: #{package_names}"
    )

    advisories = fetch_advisories!(packages)

    findings =
      blocking_findings(packages, &Map.fetch!(advisories, package_key(&1)))

    if findings == [] do
      Mix.shell().info("Hex runtime advisory audit: clean (#{length(packages)} shipped packages)")
    else
      Enum.each(findings, &print_finding/1)
      Mix.raise("high/critical advisories found in shipped Hex dependencies")
    end
  end

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

  def runtime_apps(deps) do
    deps_by_app = Map.new(deps, &{&1.app, &1})

    roots =
      deps
      |> Enum.filter(&(&1.top_level && shipped?(&1)))
      |> Enum.map(& &1.app)

    collect_runtime_apps(roots, deps_by_app, MapSet.new())
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
    |> Enum.uniq_by(&{package_key(&1.package), canonical_id(&1)})
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
        advisory_indexes = Map.get(release, :advisory_indexes, [])
        advisories = Map.get(body, :advisories) || []

        if valid_advisory_indexes?(advisory_indexes, advisories) do
          {:ok, Enum.map(advisory_indexes, &Enum.at(advisories, &1))}
        else
          {:error,
           "#{package.name} #{package.version} has malformed advisory indexes in the signed Hex registry"}
        end
    end
  end

  def registry_advisories(package, {:ok, {status, _headers, _body}}) do
    {:error, "signed Hex registry fetch for #{package.name} returned HTTP #{status}"}
  end

  def registry_advisories(package, {:error, reason}) do
    {:error, "signed Hex registry fetch for #{package.name} failed: #{inspect(reason)}"}
  end

  defp fetch_package_advisories(package, fetcher) do
    case registry_advisories(package, fetch_record(package, fetcher, @fetch_attempts)) do
      {:ok, advisories} -> {:ok, package_key(package), advisories}
      {:error, message} -> {:error, message}
    end
  end

  defp fetch_record(package, fetcher, attempts) do
    result = fetcher.(package.repo, package.name, nil)

    if retryable_fetch?(result) and attempts > 1 do
      Process.sleep((@fetch_attempts - attempts + 1) * 100)
      fetch_record(package, fetcher, attempts - 1)
    else
      result
    end
  end

  defp retryable_fetch?({:error, _reason}), do: true
  defp retryable_fetch?({:ok, {status, _headers, _body}}), do: status == 429 or status >= 500

  defp valid_advisory_indexes?(indexes, advisories)
       when is_list(indexes) and is_list(advisories) do
    advisory_count = length(advisories)
    Enum.all?(indexes, &(is_integer(&1) and &1 >= 0 and &1 < advisory_count))
  end

  defp valid_advisory_indexes?(_indexes, _advisories), do: false

  defp package_key(package), do: {package.repo, package.name, package.version}

  defp print_finding(advisory) do
    package = advisory.package
    severity = advisory[:severity] |> to_string() |> String.replace_prefix("SEVERITY_", "")

    Mix.shell().error(
      "#{package.name} #{package.version}: #{canonical_id(advisory)} " <>
        "(#{severity}) #{advisory[:summary]} #{advisory[:html_url]}"
    )
  end

  defp ensure_hex_advisories! do
    unless function_exported?(Hex.Repo, :get_package, 3) do
      Mix.raise("Hex runtime audit requires Hex 2.5.1; run mix local.hex 2.5.1 --force")
    end
  end

  defp collect_runtime_apps([], _deps_by_app, apps), do: apps

  defp collect_runtime_apps([app | rest], deps_by_app, apps) do
    case Map.fetch(deps_by_app, app) do
      {:ok, dep} ->
        if MapSet.member?(apps, app) or not shipped?(dep) do
          collect_runtime_apps(rest, deps_by_app, apps)
        else
          children = Enum.map(dep.deps, & &1.app)
          collect_runtime_apps(children ++ rest, deps_by_app, MapSet.put(apps, app))
        end

      :error ->
        Mix.raise("runtime dependency #{app} is absent from Mix's loaded dependency graph")
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
