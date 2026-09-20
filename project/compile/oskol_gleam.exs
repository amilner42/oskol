# mix_gleam 0.6.2's compile_package/2 invokes `gleam compile-package` and
# copies its output into Mix's app path. Gleam 1.13.0's compile-package command
# hard-codes Mode::Dev, so it reads src/, test/, and dev/ with no CLI or
# gleam.toml option to select a production source set:
#
# https://github.com/gleam-lang/mix_gleam/blob/v0.6.2/lib/mix/tasks/compile/gleam.ex
# https://github.com/gleam-lang/gleam/blob/v1.13.0/compiler-cli/src/compile_package.rs
#
# Mirror that small integration here, but give production an explicit package
# root containing only src/. Development and test still delegate to mix_gleam.
defmodule Mix.Tasks.Compile.OskolGleam do
  use Mix.Task.Compiler

  @gleam_version "1.13.0"

  @impl true
  def run(args) do
    result =
      if Mix.env() == :prod do
        compile_production()
        {:ok, []}
      else
        Mix.Tasks.Compile.Gleam.run(args)
      end

    remove_compiler_escript()
    result
  end

  defp compile_production do
    ensure_gleam_version!()

    project_root = File.cwd!()
    build_path = Mix.Project.build_path() |> Path.expand(project_root)
    package_root = Path.join(build_path, "gleam_package")
    output = Path.join(package_root, "build/dev/erlang/oskol")
    libraries = Path.join(build_path, "lib")

    # Recreate the package root so a renamed or deleted source cannot linger.
    File.rm_rf!(package_root)
    File.mkdir_p!(package_root)
    File.cp!(Path.join(project_root, "gleam.toml"), Path.join(package_root, "gleam.toml"))

    source = Path.join(project_root, "src")
    staged_source = Path.join(package_root, "src")

    if File.ln_s(source, staged_source) != :ok do
      File.cp_r!(source, staged_source)
    end

    File.mkdir_p!(libraries)
    Mix.shell().info("Compiling production Gleam source set (src/ only)")

    {compiler_output, status} =
      System.cmd(
        "gleam",
        [
          "compile-package",
          "--target",
          "erlang",
          "--no-beam",
          "--package",
          package_root,
          "--out",
          output,
          "--lib",
          libraries
        ],
        stderr_to_stdout: true
      )

    if compiler_output != "", do: Mix.shell().info(compiler_output)
    if status != 0, do: Mix.raise("production Gleam compilation failed")

    app_path = Mix.Project.app_path()
    File.mkdir_p!(app_path)

    output
    |> File.ls!()
    |> Enum.each(fn item ->
      source_item = Path.join(output, item)
      destination = Path.join(app_path, item)

      case File.lstat(source_item) do
        {:ok, %File.Stat{type: :symlink}} ->
          Mix.raise("unexpected symlink in production Gleam output: #{source_item}")

        _other ->
          File.rm_rf!(destination)
          File.cp_r!(source_item, destination)
      end
    end)
  end

  defp ensure_gleam_version! do
    case System.cmd("gleam", ["--version"], stderr_to_stdout: true) do
      {"gleam " <> version, 0} ->
        unless String.trim(version) == @gleam_version do
          Mix.raise(
            "production Gleam compiler expects #{@gleam_version}, got #{String.trim(version)}; " <>
              "revisit project/compile/oskol_gleam.exs before upgrading"
          )
        end

      {output, _status} ->
        Mix.raise("could not verify Gleam #{@gleam_version}: #{String.trim(output)}")
    end
  end

  # Gleam writes this helper beside generated Erlang. It is an escript source,
  # not an Erlang module, so Mix's Erlang compiler must never receive it.
  defp remove_compiler_escript do
    [
      "build/*/erlang/*/_gleam_artefacts/gleam@@compile.erl",
      "_build/prod/gleam_package/build/dev/erlang/*/_gleam_artefacts/gleam@@compile.erl"
    ]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.each(&File.rm/1)
  end
end
