# ARCHON_JS_EXECUTABLE runs the script tests against another archon_js build, such as the
# sanitizer build in CI (see the Makefile). The pool started with the application is restarted
# to pick it up.
if executable = System.get_env("ARCHON_JS_EXECUTABLE") do
  Application.stop(:archon)
  Application.put_env(:archon, Archon.Script.Pool, executable: Path.expand(executable))
  {:ok, _apps} = Application.ensure_all_started(:archon)
end

# Postgres tests (`@moduletag :postgres`, ADR 0021 decision 9) run when the database in
# DATABASE_URL (or the local default) can be reached. CI sets ARCHON_REQUIRE_POSTGRES so that an
# unreachable database fails the run instead of skipping them.
exclude =
  case Archon.PostgresCase.setup_database() do
    :ok ->
      []

    {:error, reason} ->
      if System.get_env("ARCHON_REQUIRE_POSTGRES") not in [nil, "", "0"] do
        raise "ARCHON_REQUIRE_POSTGRES is set but Postgres is unavailable: #{reason}"
      end

      IO.puts("Skipping :postgres tests: #{reason}")
      [:postgres]
  end

ExUnit.start(exclude: exclude)
