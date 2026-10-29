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
    write!(dir, "lib/a.ex", "a\n")
    write!(dir, "test/a_test.exs", "a\n")
    commit!(dir, "base")
    git!(dir, ["switch", "--quiet", "-c", "work"])
    :ok
  end

  test "test-gap passes when tests are only added", %{tmp_dir: dir} do
    write!(dir, "test/b_test.exs", "b\n")
    write!(dir, "test/a_test.exs", "a\nnew test\n")
    commit!(dir, "tests")

    assert {"", 0} = check(dir, "test-gap")
  end

  test "test-gap rejects emptying or rewriting an existing test", %{tmp_dir: dir} do
    write!(dir, "test/a_test.exs", "")
    commit!(dir, "emptied")

    assert {out, 1} = check(dir, "test-gap")
    assert out =~ "removed lines\ttest/a_test.exs"
  end

  test "an executable bit is rejected", %{tmp_dir: dir} do
    write!(dir, "test/b_test.exs", "b\n")
    File.chmod!(Path.join(dir, "test/b_test.exs"), 0o755)
    commit!(dir, "exec")

    assert {out, 1} = check(dir, "test-gap")
    assert out =~ "file mode 100755\ttest/b_test.exs"
  end

  test "protected records are matched without regard to case", %{tmp_dir: dir} do
    write!(dir, "docs/ADR/0099-fake.md", "x")
    write!(dir, "docs/Operations.md", "x")
    commit!(dir, "case")

    assert {out, 1} = check(dir, "daily-cleanup")
    assert out =~ "outside allowlist\tdocs/ADR/0099-fake.md"
    assert out =~ "outside allowlist\tdocs/Operations.md"
  end

  test "test-gap rejects product code and test deletions", %{tmp_dir: dir} do
    write!(dir, "lib/a.ex", "a\nmore\n")
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

  test "submodules are rejected even when git config hides them", %{tmp_dir: dir} do
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)
    git!(dir, ["update-index", "--add", "--cacheinfo", "160000,#{String.trim(sha)},test/sub"])
    git!(dir, ["commit", "--quiet", "-m", "gitlink"])
    git!(dir, ["config", "diff.ignoreSubmodules", "all"])

    assert {out, 1} = check(dir, "test-gap")
    assert out =~ "submodule\ttest/sub"
  end

  test "diff.relative in a subdirectory cannot hide changes elsewhere", %{tmp_dir: dir} do
    write!(dir, "mix.exs", "x\n")
    commit!(dir, "outside")
    git!(dir, ["config", "diff.relative", "true"])

    assert {out, 1} = check(Path.join(dir, "test"), "test-gap")
    assert out =~ "outside allowlist\tmix.exs"
  end

  test "non-ASCII paths are rejected because the filesystem may fold them", %{tmp_dir: dir} do
    write!(dir, "docs/operation\u017F.md", "x\n")
    commit!(dir, "long s")

    assert {out, 1} = check(dir, "daily-cleanup")
    assert out =~ "outside allowlist"
  end

  test "git metadata files are rejected anywhere", %{tmp_dir: dir} do
    write!(dir, "lib/.gitattributes", "*.ex -diff\n")
    write!(dir, "test/.gitignore", "x\n")
    commit!(dir, "attributes")

    assert {out, 1} = check(dir, "daily-cleanup")
    assert out =~ "outside allowlist\tlib/.gitattributes"
    assert out =~ "outside allowlist\ttest/.gitignore"
  end

  test "files with a NUL byte are binary for every worker", %{tmp_dir: dir} do
    write!(dir, "lib/blob.ex", <<"a", 0, "b">>)
    commit!(dir, "binary")

    assert {out, 1} = check(dir, "daily-cleanup")
    assert out =~ "binary\tlib/blob.ex"
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
