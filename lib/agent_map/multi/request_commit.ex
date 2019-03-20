defmodule AgentMap.Multi.Req.Commit do
  @moduledoc false

  @type key :: AgentMap.key()
  @type value :: AgentMap.value()

  ##
  ## This struct is used to commit multi-key changes.
  ##
  @typedoc """
  Fields:

    * upd: a map with a new values;
    * drop: keys that will be dropped;
    * from: replying to.
  """
  @type t :: %__MODULE__{
          upd: %{required(key) => value},
          drop: [key],
          from: pid
        }

  defstruct [
    :from,
    upd: %{},
    drop: []
  ]

  ##
  ## HANDLE
  ##
  def handle(%{from: {pid, _ref}} = req, state) do
    handle(%{req | from: pid}, state)
  end

  def handle(%{from: pid} = req, state) do
    #
    #
    # DROP:
    #

    {state, keys} =
      Enum.reduce(req.drop, {state, []}, fn k, {{values, workers} = state, acc} ->
        if Map.has_key?(workers, k) do
          send(workers[k], %{act: :drop, key: k, !: {:avg, +1}, from: pid})

          {state, acc}
        else
          values = Map.delete(values, k)
          {{values, workers}, [k | acc]}
        end
      end)

    #
    # UPDATE:
    #

    {state, keys} =
      Enum.reduce(req.upd, {state, keys}, fn {k, new_v}, {{values, workers} = state, acc} ->
        if Map.has_key?(workers, k) do
          upd = fn v, value? ->
            if value? do
              {{k, {v}}, new_v}
            else
              {{k, nil}, new_v}
            end
          end

          send(workers[k], %{act: :get_upd, key: k, fun: upd, !: {:avg, +1}, from: pid})

          {state, acc}
        else
          values = Map.put(values, k, new_v)
          {{values, workers}, [k | acc]}
        end
      end)

    # keys that ↓ were processed on server
    {:reply, keys, state}
  end
end
