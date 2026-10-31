defmodule Archon.MixProject do
  use Mix.Project

  def project do
    [
      app: :archon,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_targets: ["all"],
      make_clean: ["clean"],
      deps: deps(),
      aliases: aliases(),
      test_coverage: [summary: [threshold: 0]],
      dialyzer: [
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts",
        plt_add_apps: [:ex_unit],
        flags: [:error_handling, :extra_return, :missing_return, :underspecs]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Archon.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # The runtime and contract test schemas (ADR 0021, decision 1); a release runs
  # Archon.Release.migrate/0 instead.
  defp aliases do
    [
      "ecto.setup": [
        "ecto.create",
        ~s|run --no-start -e 'Archon.Release.migrate(["public", "archon_contract"])'|
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ecto_sql, "~> 3.14"},
      {:elixir_make, "~> 0.10.0", runtime: false},
      {:ex_json_schema, "~> 0.11.5", only: :test},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:postgrex, "~> 0.22.4"}
    ]
  end
end
