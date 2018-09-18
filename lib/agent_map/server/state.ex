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

  @typedoc "Map with values and default max_processes value."
  @type state :: {%{required(key) => pack}, max_p}

  defp compress({b, {0, max_p}}, max_p) when is_box(b), do: b
  defp compress({b, {p, max_p}}, max_p) when is_box(b), do: {b, p}
  defp compress(pack, _), do: pack

  defp decompress({b, {_, _}} = pack, _) when is_box(b), do: pack
  defp decompress({b, p}, max_p) when is_box(b), do: {b, {p, max_p}}
  defp decompress(b, max_p) when is_box(b), do: {b, {0, max_p}}

  def put({map, max_p} = _state, key, pack) do
    map =
      case decompress(pack, max_p) do
        {nil, {0, ^max_p}} ->
          Map.delete(map, key)

        pack ->
          pack = compress(pack, max_p)
          Map.put(map, key, pack)
      end

    {map, max_p}
  end

  def get({map, max_p} = _state, key) do
    case map[key] do
      w when is_pid(w) ->
        w

      pack ->
        decompress(pack, max_p)
    end
  end

  def fetch(state, key) do
    box =
      case get(state, key) do
        {box, {_, _}} ->
          box

        w ->
          Worker.dict(w)[:"$value"]
      end

    case box do
      {:value, v} ->
        {:ok, v}

      nil ->
        :error
    end
  end

  def spawn_worker({map, max_p} = state, key) do
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

        {Map.put(map, key, worker), max_p}

      _worker ->
        state
    end
  end

  def take(state, keys) do
    packs = Enum.map(keys, &{&1, fetch(state, &1)})

    for {k, {:ok, v}} <- packs, into: %{} do
      {k, v}
    end
  end

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
