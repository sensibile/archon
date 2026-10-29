defmodule Archon.Scripts.WorkerPathCheckTest do
  use ExUnit.Case, async: true

  # The allowlist check guards which worker PRs may auto-merge (docs/operations.md), so every case
  # that once passed when it should not is pinned here: git errors, padded paths, symlinks.
  @script Path.expand("../../scripts/worker_path_check.sh", __DIR__)

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    git!(dir, ["init", "--quiet", "--initial-branch=main"])
    git!(dir, ["config", "user.email", "test@example.com"])
    git!(dir, ["config", "user.name", "test"])
    write!(dir, "lib/a.ex", "a")
    write!(dir, "test/a_test.exs", "a")
    commit!(dir, "base")
    git!(dir, ["switch", "--quiet", "-c", "work"])
    :ok
  end

  test "test-gap passes when only test files are added or changed", %{tmp_dir: dir} do
    write!(dir, "test/b_test.exs", "b")
    write!(dir, "test/a_test.exs", "changed")
    commit!(dir, "tests")

    assert {"", 0} = check(dir, "test-gap")
  end

  test "test-gap rejects product code and test deletions", %{tmp_dir: dir} do
    write!(dir, "lib/a.ex", "changed")
    File.rm!(Path.join(dir, "test/a_test.exs"))
    commit!(dir, "mixed")

    assert {out, 1} = check(dir, "test-gap")
    assert out =~ "outside allowlist\tlib/a.ex"
    assert out =~ "deletion\ttest/a_test.exs"
  end

  test "a path that only looks like test/ after trimming is rejected", %{tmp_dir: dir} do
    write!(dir, " test/outside.exs", "x")
    commit!(dir, "padded")

    assert {out, 1} = check(dir, "test-gap")
    assert out =~ "outside allowlist\t test/outside.exs"
  end

  test "symlinks are rejected even inside an allowed directory", %{tmp_dir: dir} do
    File.ln_s!("../mix.exs", Path.join(dir, "test/link.exs"))
    commit!(dir, "link")

    assert {out, 1} = check(dir, "test-gap")
    assert out =~ "symlink\ttest/link.exs"
  end

  test "daily-cleanup allows lib, test and docs but not authority records", %{tmp_dir: dir} do
    write!(dir, "lib/a.ex", "changed")
    write!(dir, "docs/guide.md", "x")
    write!(dir, "docs/operations.md", "x")
    write!(dir, "docs/adr/0099-x.md", "x")
    write!(dir, "mix.exs", "x")
    commit!(dir, "cleanup")

    assert {out, 1} = check(dir, "daily-cleanup")
    assert out =~ "outside allowlist\tdocs/operations.md"
    assert out =~ "outside allowlist\tdocs/adr/0099-x.md"
    assert out =~ "outside allowlist\tmix.exs"
    refute out =~ "lib/a.ex"
    refute out =~ "docs/guide.md"
  end

  test "a git error fails the check instead of passing with empty output", %{tmp_dir: dir} do
    assert {out, 2} = check(dir, "test-gap", ["origin/missing"])
    assert out =~ "git diff failed for origin/missing...HEAD"
  end

  test "an unknown worker is a usage error", %{tmp_dir: dir} do
    assert {out, 2} = check(dir, "other")
    assert out =~ "usage:"
  end

  defp check(dir, worker, args \\ ["main"]) do
    System.cmd(@script, [worker | args], cd: dir, stderr_to_stdout: true)
  end

  defp write!(dir, rel, content) do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp commit!(dir, message) do
    git!(dir, ["add", "--all"])
    git!(dir, ["commit", "--quiet", "-m", message])
  end

  defp git!(dir, args) do
    {_, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
  end
end
