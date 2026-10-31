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
# unreachable database fails the run instead of skipping them. ARCHON_BACKEND=postgres (see
# config/test.exs) always needs the database: the runtime runs on it.
backend = Archon.PostgresCase.backend()

database =
  case Archon.PostgresCase.setup_database() do
    :ok ->
      :ok

    {:error, reason} ->
      if backend == :postgres or
           System.get_env("ARCHON_REQUIRE_POSTGRES") not in [nil, "", "0"] do
        raise "Postgres is required (ARCHON_REQUIRE_POSTGRES or ARCHON_BACKEND) but unavailable: " <>
                reason
      end

      IO.puts("Skipping :postgres tests: #{reason}")
      :unavailable
  end

# The runtime starts here rather than with the application (config/test.exs), after the
# database is set up: on the Postgres backend its tree owns Archon.Repo, and the runtime schema
# is emptied before it starts.
Archon.PostgresCase.start_runtime(backend)

# Tests tagged `backend: :memory` or `backend: :postgres` hold only on that runtime backend.
other_backend = if backend == :postgres, do: :memory, else: :postgres
exclude = [backend: other_backend] ++ if(database == :ok, do: [], else: [:postgres])

ExUnit.start(exclude: exclude)
