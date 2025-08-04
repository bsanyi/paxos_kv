defmodule PaxosKV.MixProject do
  use Mix.Project

  def project do
    [
      app: :paxos_kv,
      version: "0.2.1",
      elixir: "~> 1.17 or ~> 1.18 or ~> 1.19",
      start_permanent: Mix.env() == :prod,
      package: package(),
      deps: deps()
    ]
  end

  defp package() do
    [
      description: "A distributed, cluster-wide key-value store implemented on the BEAM.",
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/bsanyi/paxos_kv"}
    ]
  end

  def application do
    [
      extra_applications: extra_apps(Mix.env()),
      mod: {PaxosKV.Application, []}
    ]
  end

  defp extra_apps(:dev), do: [:logger, :runtime_tools, :wx, :observer]
  defp extra_apps(_), do: [:logger]

  defp deps do
    [
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end
end
