defmodule AgentMap.Metadata do
  @moduledoc false

  def initialize(%{} = map) do
    keys = Map.keys(map)

    reserved = [:storage, :processes, :max_concurrency]

    case reserved -- (reserved -- keys) do
      [] ->
        {ETS, ETS.new(:metadata, read_concurrency: true)}

      wrong_keys ->
        {:error, "Keys #{inspect(wrong_keys)} cannot be provided"}
    end
  end

  def initialize(enum) do
    enum
    |> Map.new()
    |> initialize_meta()
  end
end
