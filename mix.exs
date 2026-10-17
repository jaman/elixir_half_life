defmodule ElixirHalfLife.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/jaman/elixir_half_life"

  def project do
    [
      app: :elixir_half_life,
      version: @version,
      elixir: "~> 1.18",
      elixirc_options: [warnings_as_errors: true],
      start_permanent: Mix.env() == :prod,
      description: "Half-Life in Elixir, played in a terminal, on the Cauldron engine.",
      source_url: @source_url,
      package: package(),
      docs: docs(),
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp package do
    [
      licenses: ["GPL-2.0-or-later"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs .formatter.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end

  defp deps do
    [
      family(:quake_c, "~> 0.3.0", "../cauldron/quake_c", []),
      family(:quake_server, "~> 0.1.1", "../quake_server", []),
      family(:cauldron_3d, "~> 0.3.0", "../cauldron/cauldron_3d", []),
      family(:cauldron_3d_formats, "~> 0.3.0", "../cauldron/cauldron_3d_formats", []),
      family(:cauldron_2d, "~> 0.3.0", "../cauldron/cauldron_2d", []),
      family(:cauldron_2d_drafter, "~> 0.3.0", "../cauldron/cauldron_2d_drafter", []),
      family(:cauldron_gpu, "~> 0.3.0", "../cauldron/cauldron_gpu", []),
      family(:linocut, "~> 0.3.0", "../cauldron/linocut", override: true),
      family(:drafter, "~> 0.5.6", "../drafter", override: true),
      family(:french_curve, "~> 0.2.1", "../french_curve", override: true),
      family(:tuning_fork, "~> 0.1.13", "../tuning_fork/tuning_fork", override: true),
      family(:tuning_fork_speaker, "~> 0.1.13", "../tuning_fork/tuning_fork_speaker", []),
      family(:gamepad, "~> 0.1.0", "../gamepad", []),
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp family(app, requirement, path, opts) do
    if System.get_env("PLUMB_HEX") == nil and File.dir?(path),
      do: {app, [path: path] ++ opts},
      else: {app, requirement, Keyword.delete(opts, :override)}
  end
end
