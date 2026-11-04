defmodule Archon.Scripts.WorkerScopeTest do
  use ExUnit.Case, async: true

  # The scope check guards which worker PRs may auto-merge (docs/operations.md, ADR 0029). Every case
  # the earlier scripts/worker_path_check.sh pinned is kept here against archon's real scope file, so
  # the switch to the Taeguk checker cannot let through what the script rejected.
  @checker Path.expand("../../.taeguk/tools/check_worker_scope.py", __DIR__)
  @scope Path.expand("../../.taeguk/worker-scope.toml", __DIR__)
  @config ".taeguk/worker-scope.toml"

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    git!(dir, ["init", "--quiet", "--initial-branch=main"])
    git!(dir, ["config", "user.email", "test@example.com"])
    git!(dir, ["config", "user.name", "test"])
    write!(dir, @config, File.read!(@scope))
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

    assert {%{"status" => "PASS", "rejected" => [], "changed" => 2}, 0} = check(dir, "test-gap")
  end

  test "test-gap rejects emptying or rewriting an existing test", %{tmp_dir: dir} do
    write!(dir, "test/a_test.exs", "")
    commit!(dir, "emptied")

    assert {out, 1} = check(dir, "test-gap")
    assert rejected(out) == %{"test/a_test.exs" => "removed lines"}
  end

  test "an executable bit is rejected", %{tmp_dir: dir} do
    write!(dir, "test/b_test.exs", "b\n")
    File.chmod!(Path.join(dir, "test/b_test.exs"), 0o755)
    commit!(dir, "exec")

    assert {out, 1} = check(dir, "test-gap")
    assert rejected(out) == %{"test/b_test.exs" => "not a regular file (mode 100755)"}
  end

  test "protected records are matched without regard to case", %{tmp_dir: dir} do
    write!(dir, "docs/ADR/0099-fake.md", "x")
    write!(dir, "docs/Operations.md", "x")
    commit!(dir, "case")

    assert {out, 1} = check(dir, "daily-cleanup")

    assert rejected(out) == %{
             "docs/ADR/0099-fake.md" => "protected path",
             "docs/Operations.md" => "protected path"
           }
  end

  test "test-gap rejects product code and test deletions", %{tmp_dir: dir} do
    write!(dir, "lib/a.ex", "a\nmore\n")
    File.rm!(Path.join(dir, "test/a_test.exs"))
    commit!(dir, "mixed")

    assert {out, 1} = check(dir, "test-gap")

    assert rejected(out) == %{
             "lib/a.ex" => "not a test path",
             "test/a_test.exs" => "test-gap does not delete files"
           }
  end

  test "a path that only looks like test/ after trimming is rejected", %{tmp_dir: dir} do
    write!(dir, " test/outside.exs", "x")
    commit!(dir, "padded")

    assert {out, 1} = check(dir, "test-gap")
    assert rejected(out) == %{" test/outside.exs" => "not a test path"}
  end

  test "symlinks are rejected even inside an allowed directory", %{tmp_dir: dir} do
    File.ln_s!("../mix.exs", Path.join(dir, "test/link.exs"))
    commit!(dir, "link")

    assert {out, 1} = check(dir, "test-gap")
    assert rejected(out) == %{"test/link.exs" => "not a regular file (mode 120000)"}
  end

  test "submodules are rejected even when git config hides them", %{tmp_dir: dir} do
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)
    git!(dir, ["update-index", "--add", "--cacheinfo", "160000,#{String.trim(sha)},test/sub"])
    git!(dir, ["commit", "--quiet", "-m", "gitlink"])
    git!(dir, ["config", "diff.ignoreSubmodules", "all"])

    assert {out, 1} = check(dir, "test-gap")
    assert rejected(out) == %{"test/sub" => "not a regular file (mode 160000)"}
  end

  test "diff.relative in a subdirectory cannot hide changes elsewhere", %{tmp_dir: dir} do
    write!(dir, "mix.exs", "x\n")
    commit!(dir, "outside")
    git!(dir, ["config", "diff.relative", "true"])

    assert {out, 1} = check(Path.join(dir, "test"), "test-gap")
    assert rejected(out) == %{"mix.exs" => "protected path"}
  end

  test "non-ASCII paths are rejected because the filesystem may fold them", %{tmp_dir: dir} do
    write!(dir, "docs/operationſ.md", "x\n")
    commit!(dir, "long s")

    assert {out, 1} = check(dir, "daily-cleanup")
    assert [%{"reason" => "non-ASCII or control character in path"}] = out["rejected"]
  end

  test "git metadata files are rejected anywhere", %{tmp_dir: dir} do
    write!(dir, "lib/.gitattributes", "*.ex -diff\n")
    write!(dir, "test/.gitignore", "x\n")
    commit!(dir, "attributes")

    assert {out, 1} = check(dir, "daily-cleanup")

    assert rejected(out) == %{
             "lib/.gitattributes" => "protected path",
             "test/.gitignore" => "protected path"
           }
  end

  test "files with a NUL byte are binary for every worker", %{tmp_dir: dir} do
    write!(dir, "lib/blob.ex", <<"a", 0, "b">>)
    commit!(dir, "binary")

    assert {out, 1} = check(dir, "daily-cleanup")
    assert rejected(out) == %{"lib/blob.ex" => "binary content"}
  end

  test "daily-cleanup allows lib, test and docs but not authority records", %{tmp_dir: dir} do
    write!(dir, "lib/a.ex", "changed")
    write!(dir, "docs/guide.md", "x")
    write!(dir, "docs/operations.md", "x")
    write!(dir, "docs/adr/0099-x.md", "x")
    write!(dir, "mix.exs", "x")
    commit!(dir, "cleanup")

    assert {out, 1} = check(dir, "daily-cleanup")

    assert rejected(out) == %{
             "docs/operations.md" => "protected path",
             "docs/adr/0099-x.md" => "protected path",
             "mix.exs" => "protected path"
           }
  end

  test "a git error fails the check instead of passing with empty output", %{tmp_dir: dir} do
    assert {%{"status" => "UNKNOWN", "error" => error}, 2} =
             check(dir, "test-gap", ["--base", "origin/missing"])

    assert error =~ "rev-parse"
  end

  test "an option-like or unknown revision is an error, not a pass", %{tmp_dir: dir} do
    write!(dir, "test/a_test.exs", "")
    commit!(dir, "emptied")

    assert {%{"status" => "UNKNOWN"}, 2} = check(dir, "test-gap", ["--base=--output=o"])

    assert {%{"status" => "UNKNOWN"}, 2} =
             check(dir, "test-gap", ["--head", "0000000000000000000000000000000000000000"])

    refute File.exists?(Path.join(dir, "o"))
  end

  test "binary content and odd modes are checked on the old side too", %{tmp_dir: dir} do
    write!(dir, "lib/blob.ex", <<"a", 0, "b">>)
    write!(dir, "lib/run.sh", "x\n")
    File.chmod!(Path.join(dir, "lib/run.sh"), 0o755)
    commit!(dir, "seed")
    git!(dir, ["branch", "-f", "seeded"])
    File.rm!(Path.join(dir, "lib/blob.ex"))
    File.chmod!(Path.join(dir, "lib/run.sh"), 0o644)
    commit!(dir, "drop")

    assert {out, 1} = check(dir, "daily-cleanup", ["--base", "seeded"])

    assert rejected(out) == %{
             "lib/blob.ex" => "binary content",
             "lib/run.sh" => "not a regular file (mode 100755)"
           }
  end

  test "a path that differs only in case from another path is rejected", %{tmp_dir: dir} do
    write!(dir, "test/test_helper.exs", "ExUnit.start()\n")
    commit!(dir, "helper")
    git!(dir, ["branch", "-f", "seeded"])
    blob = git_out!(dir, ["hash-object", "-w", "--stdin"], "ExUnit.start(exclude: [:test])\n")
    git!(dir, ["update-index", "--add", "--cacheinfo", "100644,#{blob},test/Test_helper.exs"])
    git!(dir, ["commit", "--quiet", "-m", "shadow"])

    assert {out, 1} = check(dir, "test-gap", ["--base", "seeded"])
    assert %{"test/test_helper.exs" => "case collision"} = rejected(out)
  end

  test "a case collision with a path main gained later is rejected", %{tmp_dir: dir} do
    git!(dir, ["switch", "--quiet", "main"])
    write!(dir, "test/Foo_test.exs", "main\n")
    commit!(dir, "main adds")
    git!(dir, ["switch", "--quiet", "work"])
    blob = git_out!(dir, ["hash-object", "-w", "--stdin"], "work\n")
    git!(dir, ["update-index", "--add", "--cacheinfo", "100644,#{blob},test/foo_test.exs"])
    git!(dir, ["commit", "--quiet", "-m", "work adds"])

    assert {out, 1} = check(dir, "test-gap")
    assert %{"test/foo_test.exs" => "case collision"} = rejected(out)
  end

  test "agent instruction files are rejected at any depth", %{tmp_dir: dir} do
    write!(dir, "test/CLAUDE.md", "x\n")
    write!(dir, "lib/AGENTS.override.md", "x\n")
    write!(dir, "docs/.claude/skills/x/SKILL.md", "x\n")
    commit!(dir, "instructions")

    assert {out, 1} = check(dir, "daily-cleanup")

    assert rejected(out) == %{
             "test/CLAUDE.md" => "protected path",
             "lib/AGENTS.override.md" => "protected path",
             "docs/.claude/skills/x/SKILL.md" => "protected path"
           }
  end

  test "extra arguments are a usage error", %{tmp_dir: dir} do
    assert {out, 2} = check_raw(dir, ["test-gap", "lib/a.ex"] ++ config())
    assert out =~ "usage:"
  end

  test "an unknown worker is a usage error", %{tmp_dir: dir} do
    assert {out, 2} = check_raw(dir, ["other"] ++ config())
    assert out =~ "usage:"
  end

  # Paths the script rejected only because they were outside its allowlist, now named so a later
  # scope edit that loosens one fails here.
  test "Taeguk copies, scope and suite files, CI and executed scripts stay out of reach", %{
    tmp_dir: dir
  } do
    paths = [
      ".taeguk/worker-scope.toml",
      ".taeguk/validation-suites.toml",
      ".taeguk/tools/check_worker_scope.py",
      ".taeguk/rules/index.md",
      ".github/workflows/ci.yml",
      "scripts/with_test_postgres.sh",
      "test/scripts/worker_scope_test.exs",
      "AGENTS.md",
      "mix.lock"
    ]

    Enum.each(paths, &write!(dir, &1, "x\n"))
    commit!(dir, "authority")

    for worker <- ["test-gap", "daily-cleanup"] do
      assert {out, 1} = check(dir, worker)
      assert rejected(out) == Map.new(paths, &{&1, "protected path"})
    end
  end

  test "config/, priv/ and README.md stay outside test-gap and config/, priv/ outside cleanup", %{
    tmp_dir: dir
  } do
    write!(dir, "config/x.exs", "x\n")
    write!(dir, "priv/contract/x.json", "x\n")
    write!(dir, "README.md", "x\n")
    commit!(dir, "elsewhere")

    assert {out, 1} = check(dir, "test-gap")

    assert rejected(out) == %{
             "config/x.exs" => "not a test path",
             "priv/contract/x.json" => "not a test path",
             "README.md" => "not a test path"
           }

    assert {out, 1} = check(dir, "daily-cleanup")

    assert rejected(out) == %{
             "config/x.exs" => "not a cleanup path",
             "priv/contract/x.json" => "not a cleanup path"
           }
  end

  test "the scope is read at the base commit, so a worker PR cannot widen it", %{tmp_dir: dir} do
    write!(
      dir,
      @config,
      String.replace(File.read!(@scope), ~s(allow = ["test/"]), ~s(allow = ["**"]))
    )

    write!(dir, "lib/a.ex", "a\nmore\n")
    commit!(dir, "widen")

    assert {out, 1} = check(dir, "test-gap")

    assert rejected(out) == %{
             ".taeguk/worker-scope.toml" => "protected path",
             "lib/a.ex" => "not a test path"
           }
  end

  defp check(dir, worker, args \\ []) do
    {out, status} = check_raw(dir, [worker, "--base", "main"] ++ args ++ config())
    {JSON.decode!(out), status}
  end

  defp check_raw(dir, args) do
    System.cmd("python3", ["-I", @checker | args], cd: dir, stderr_to_stdout: true)
  end

  defp config, do: ["--config", @config]

  defp rejected(%{"status" => "FAIL", "rejected" => rejected}) do
    Map.new(rejected, &{&1["path"], &1["reason"]})
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

  defp git_out!(dir, args, input) do
    path = Path.join(dir, ".stdin")
    File.write!(path, input)
    {out, 0} = System.cmd("sh", ["-c", "git " <> Enum.join(args, " ") <> " < .stdin"], cd: dir)
    File.rm!(path)
    String.trim(out)
  end

  defp git!(dir, args) do
    {_, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
  end
end
