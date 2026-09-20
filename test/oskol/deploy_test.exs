defmodule Oskol.DeployTest do
  use ExUnit.Case, async: true

  @deploy Path.expand("../../bin/deploy", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "oskol-deploy-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    fake_fly = Path.join(dir, "fly")

    File.write!(fake_fly, """
    #!/usr/bin/env sh
    set -eu

    if [ "$1" = machines ] && [ "$2" = list ]; then
      printf 'machines\\n' >> "$FLY_CALLS_FILE"
      if [ -f "$FLY_DEPLOYED_FILE" ] && [ -s "$FLY_MACHINES_AFTER_FILE" ]; then
        cat "$FLY_MACHINES_AFTER_FILE"
      else
        cat "$FLY_MACHINES_FILE"
      fi
      exit 0
    fi

    if [ "$1" = deploy ]; then
      printf 'deploy %s\\n' "$*" >> "$FLY_CALLS_FILE"
      touch "$FLY_DEPLOYED_FILE"
      printf 'deployed\\n'
      exit 0
    fi

    exit 64
    """)

    File.chmod!(fake_fly, 0o755)

    on_exit(fn -> File.rm_rf!(dir) end)

    %{
      fake_fly: fake_fly,
      machines_file: Path.join(dir, "machines"),
      after_machines_file: Path.join(dir, "machines-after"),
      calls_file: Path.join(dir, "calls"),
      deployed_file: Path.join(dir, "deployed")
    }
  end

  test "refuses the supported deploy path unless Fly reports exactly one machine", %{
    fake_fly: fake_fly,
    machines_file: machines_file,
    after_machines_file: after_machines_file,
    deployed_file: deployed_file,
    calls_file: calls_file
  } do
    File.write!(machines_file, "first\nsecond\n")

    {output, status} =
      System.cmd(@deploy, [],
        env: [
          {"FLY_BIN", fake_fly},
          {"FLY_MACHINES_FILE", machines_file},
          {"FLY_MACHINES_AFTER_FILE", after_machines_file},
          {"FLY_DEPLOYED_FILE", deployed_file},
          {"FLY_CALLS_FILE", calls_file}
        ],
        stderr_to_stdout: true
      )

    assert status == 1
    assert output =~ "requires exactly one Fly machine (found 2)"
  end

  test "checks the machine count before and after deploying", %{
    fake_fly: fake_fly,
    machines_file: machines_file,
    after_machines_file: after_machines_file,
    deployed_file: deployed_file,
    calls_file: calls_file
  } do
    File.write!(machines_file, "only-machine\n")

    assert {"deployed\n", 0} =
             System.cmd(@deploy, [],
               env: [
                 {"FLY_BIN", fake_fly},
                 {"FLY_MACHINES_FILE", machines_file},
                 {"FLY_MACHINES_AFTER_FILE", after_machines_file},
                 {"FLY_DEPLOYED_FILE", deployed_file},
                 {"FLY_CALLS_FILE", calls_file}
               ],
               stderr_to_stdout: true
             )

    assert File.read!(calls_file) ==
             "machines\ndeploy deploy --remote-only --strategy immediate --app oskol\nmachines\n"
  end

  test "refuses a deploy that would leave two machines", %{
    fake_fly: fake_fly,
    machines_file: machines_file,
    after_machines_file: after_machines_file,
    deployed_file: deployed_file,
    calls_file: calls_file
  } do
    File.write!(machines_file, "old-machine\n")
    File.write!(after_machines_file, "old-machine\nnew-machine\n")

    {output, status} =
      System.cmd(@deploy, [],
        env: [
          {"FLY_BIN", fake_fly},
          {"FLY_MACHINES_FILE", machines_file},
          {"FLY_MACHINES_AFTER_FILE", after_machines_file},
          {"FLY_DEPLOYED_FILE", deployed_file},
          {"FLY_CALLS_FILE", calls_file}
        ],
        stderr_to_stdout: true
      )

    assert status == 1
    assert output =~ "requires exactly one Fly machine (found 2)"

    assert File.read!(calls_file) ==
             "machines\ndeploy deploy --remote-only --strategy immediate --app oskol\nmachines\n"
  end

  test "the release keeps administration but cannot discover peer nodes" do
    refute File.read!(Path.expand("../../lib/oskol/application.ex", __DIR__)) =~ "DNSCluster"
    refute File.read!(Path.expand("../../config/runtime.exs", __DIR__)) =~ "dns_cluster_query"
    refute File.read!(Path.expand("../../rel/env.sh.eex", __DIR__)) =~ "DNS_CLUSTER_QUERY"
    refute File.read!(Path.expand("../../mix.exs", __DIR__)) =~ "{:dns_cluster"
    assert File.read!(Path.expand("../../rel/env.sh.eex", __DIR__)) =~ "RELEASE_DISTRIBUTION"

    assert File.read!(Path.expand("../../fly.toml", __DIR__)) =~
             "[deploy]\n  # There is one local room owner. Stop it before its replacement starts so\n  # boot-time migrations and in-memory rooms can never overlap across builds.\n  strategy = 'immediate'"
  end
end
