defmodule PaxosKV.MixProject do
  use Mix.Project

  def project do
    [
      app: :paxos_kv,
      version: "0.6.0",
      elixir: "~> 1.17 or ~> 1.18 or ~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      docs: docs(),
      package: package(),
      deps: deps()
    ]
  end

  defp package do
    [
      description: "A distributed, cluster-wide key-value store implemented on the BEAM.",
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/bsanyi/paxos_kv"}
    ]
  end

  defp docs do
    [
      extras: ["README.md", "NOAI.md", "robots.txt", "AGENTS.md", "LICENSE"],
      main: "readme"
    ]
  end

  def application do
    [
      extra_applications: extra_apps(Mix.env()),
      mod: {PaxosKV.Application, []}
    ]
  end

  defp extra_apps(:dev), do: [:logger, :wx, :observer]
  defp extra_apps(_), do: [:logger]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:stream_data, "~> 1.0", only: :test},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: :dev, runtime: false}
    ]
  end
end
