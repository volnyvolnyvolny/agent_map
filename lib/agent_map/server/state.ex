defmodule AgentMap.Server.State do
  @moduledoc false

  alias AgentMap.Worker

  @typedoc "Value or not."
  @type value? :: {:v, term} | nil

  def unbox(nil), do: nil
  def unbox({:v, v}), do: v

  @type worker :: pid

  @typedoc "Maximum number of get tasks can be used per key."
  @type max_p :: pos_integer | :infinity

  @typedoc "Number of get tasks is spawned at the moment."
  @type p :: pos_integer

  @type key :: term

  @type pack :: worker | {value?, {p, max_p}} | compressed

  @typedoc """
  Compressed pack is:

    * {value?, p} :: {value?, {p, default max_p}}
    * {:v, term} :: {{:v, term}, {0, default max_p}}
  """
  @type compressed :: {value?, p} | {:v, term}

  @typedoc "Map with values."
  @type state :: %{required(key) => pack}

  def put_value(state, key, value, old)

  def put_value(state, key, value, {nil, info}) do
    Worker.inc(:size)
    put(state, key, {{:v, value}, info})
  end

  def put_value(state, key, value, {_old, info}) do
    put(state, key, {{:v, value}, info})
  end

  #

  def put(state, key, {nil, {0, nil}}) do
    Map.delete(state, key)
  end

  def put(state, key, {v, {0, nil}}) do
    Map.put(state, key, v)
  end

  def put(state, key, {v, {p, nil}}) do
    Map.put(state, key, {v, p})
  end

  def put(state, key, pack) do
    Map.put(state, key, pack)
  end

  #

  defguardp is_value(v)
            when is_nil(v) or (is_tuple(v) and elem(v, 0) == :v)

  def get(state, key) do
    case state[key] do
      {v?, {_p, _max_p}} = pack when is_value(v?) ->
        pack

      {v?, p} when is_value(v?) ->
        {v?, {p, nil}}

      v? when is_value(v?) ->
        {v?, {0, nil}}

      worker ->
        worker
    end
  end

  def fetch(state, key) do
    value? =
      case get(state, key) do
        {v?, {_, _}} ->
          v?

        w ->
          Worker.dict(w)[:value?]
      end

    case value? do
      {:v, v} ->
        {:ok, v}

      nil ->
        :error
    end
  end

  def spawn_worker(state, key) do
    case get(state, key) do
      {value?, _p_info} = pack ->
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

        unless value?, do: Worker.inc(:size)

        Map.put(state, key, worker)

      _worker ->
        state
    end
  end

  def take(state, keys) do
    packs = Enum.map(keys, &{&1, fetch(state, &1)})

    for {k, {:ok, v}} <- packs, into: %{}, do: {k, v}
  end

  #
  # %{a: {{:v, v}, _}, b: {nil, _}, c: {:pid, w}}
  # =>
  # {%{a: v}, %{c: w}}
  def separate(state, keys) do
    Enum.reduce(keys, {%{}, %{}}, fn key, {map, workers} ->
      case get(state, key) do
        {{:v, value}, _} ->
          {Map.put(map, key, value), workers}

        {nil, _} ->
          {map, workers}

        pid ->
          {map, Map.put(workers, key, pid)}
      end
    end)
  end

  def extract({:noreply, state}), do: state
  def extract({:reply, _get, state}), do: state
end
