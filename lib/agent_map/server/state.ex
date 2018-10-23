defmodule AgentMap.Server.State do
  @moduledoc false

  alias AgentMap.Worker

  ##
  ## BOXING
  ##

  @typedoc "Value or no value."
  @type box :: {:value, term} | nil

  defguard is_box(b) when is_nil(b) or (is_tuple(b) and elem(b, 0) == :value)

  def box(v), do: {:value, v}

  def unbox(nil), do: nil
  def unbox({:value, v}), do: v

  def un(box), do: unbox(box)

  @type worker :: pid

  @typedoc "Maximum get-tasks can be used per key."
  @type max_p :: pos_integer | :infinity

  @typedoc "Number of get-tasks is spawned."
  @type p :: pos_integer

  @type key :: term

  @type pack :: worker | {box, {p, max_p}} | compressed_pack

  @typedoc """
  Compressed pack is:

    * {box, p} :: {box, {p, default max_p}}
    * {:value, term} :: {{:value, term}, {0, default max_p}}
  """
  @type compressed_pack :: {box, p} | {:value, term}

  @typedoc "Map with values."
  @type state :: %{required(key) => pack}

  def put(state, key, {_b, {_p, _mp}} = pack) do
    case pack do
      {nil, {0, nil}} ->
        Map.delete(state, key)

      {b, {0, nil}} ->
        Map.put(state, key, b)

      {b, {p, nil}} ->
        Map.put(state, key, {b, p})

      _ ->
        Map.put(state, key, pack)
    end
  end

  def get(state, key) do
    case state[key] do
      {b, {_p, _max_p}} = pack when is_box(b) ->
        pack

      {b, p} when is_box(b) ->
        {b, {p, nil}}

      b when is_box(b) ->
        {b, {0, nil}}

      worker ->
        worker
    end
  end

  def fetch(state, key) do
    box =
      case get(state, key) do
        {box, {_, _}} ->
          box

        w ->
          Worker.dict(w)[:value]
      end

    case box do
      {:value, v} ->
        {:ok, v}

      nil ->
        :error
    end
  end

  def spawn_worker(state, key) do
    case get(state, key) do
      {_box, _p_info} = pack ->
        ref = make_ref()
        server = self()

        worker =
          spawn_link(fn ->
            Worker.loop({ref, server}, key, pack)
          end)

        receive do
          {^ref, :ok} ->
            :continue
        end

        Map.put(state, key, worker)

      _worker ->
        state
    end
  end

  def take(state, keys) do
    packs = Enum.map(keys, &{&1, fetch(state, &1)}) |> IO.inspect()

    for {k, {:ok, v}} <- packs, into: %{}, do: {k, v}
  end

  #
  # %{a: {{:value, v}, _}, b: {nil, _}, c: {:pid, w}}
  # =>
  # {%{a: v}, %{c: w}}
  def separate(state, keys) do
    Enum.reduce(keys, {%{}, %{}}, fn key, {map, workers} ->
      case get(state, key) do
        {{:value, v}, _} ->
          {Map.put(map, key, v), workers}

        {nil, _} ->
          {map, workers}

        w ->
          {map, Map.put(workers, key, w)}
      end
    end)
  end
end
