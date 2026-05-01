defmodule LoroEx.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source_url "https://github.com/bmalum/loro_ex"

  def project do
    [
      app: :loro_ex,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      name: "LoroEx",
      source_url: @source_url,
      docs: docs(),
      rustler_crates: rustler_crates(),
      aliases: aliases(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_core_path: "priv/plts",
        plt_local_path: "priv/plts"
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      # Runtime
      {:rustler, "~> 0.37"},
      # Optional: use rustler_precompiled once we publish signed NIF artifacts.
      # {:rustler_precompiled, "~> 0.8"},

      # Dev / test
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: :test}
    ]
  end

  defp rustler_crates do
    [
      loro_nif: [
        path: "native/loro_nif",
        mode: if(Mix.env() == :prod, do: :release, else: :debug),
        # Route through rustup so we get the pinned rustc from
        # rust-toolchain.toml rather than whatever system cargo is on PATH.
        # Override with CARGO_MODE=system if you want to use the system cargo
        # (e.g. in CI images where rustup isn't installed).
        cargo:
          if(System.get_env("CARGO_MODE") == "system",
            do: :system,
            else: {:rustup, "stable"}
          )
      ]
    ]
  end

  defp description do
    "Elixir binding for the Loro CRDT library via a Rustler NIF."
  end

  defp package do
    [
      files: ~w(lib native/loro_nif/src native/loro_nif/Cargo.toml
               .formatter.exs mix.exs README.md LICENSE CHANGELOG.md),
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "LoroEx",
      extras: ["README.md", "CHANGELOG.md"],
      source_ref: "v#{@version}"
    ]
  end

  defp aliases do
    [
      "rust.fmt": ["cmd cargo fmt --manifest-path native/loro_nif/Cargo.toml"],
      "rust.check": [
        "cmd cargo fmt --manifest-path native/loro_nif/Cargo.toml -- --check",
        "cmd cargo clippy --manifest-path native/loro_nif/Cargo.toml -- -D warnings"
      ],
      lint: ["format --check-formatted", "credo --strict", "rust.check"]
    ]
  end
end
