# ARCHON_JS_EXECUTABLE runs the script tests against another archon_js build, such as the
# sanitizer build in CI (see the Makefile). The pool started with the application is restarted
# to pick it up.
if executable = System.get_env("ARCHON_JS_EXECUTABLE") do
  Application.stop(:archon)
  Application.put_env(:archon, Archon.Script.Pool, executable: Path.expand(executable))
  {:ok, _apps} = Application.ensure_all_started(:archon)
end

ExUnit.start()
