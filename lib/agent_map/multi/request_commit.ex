defmodule AgentMap.Multi.Req.Commit do
  @moduledoc false

  alias AgentMap.{Req, Server}

  import Server, only: [extract_state: 1]

  @type key :: AgentMap.key()
  @type value :: AgentMap.value()

  ##
  ## This struct is used to commit multi-key changes.
  ##
  @typedoc """
  Fields:

    * initial: value for missing keys;
    * server: pid;
    * from: replying to;
    * !: priority to be used when collecting values;
    # * get: keys whose values are returned;
    * upd: a map with a new values;
    * drop: keys that will be dropped.
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

  def handle(req, state) do
    # DROP:

    pop = fn _ -> :pop end

    state =
      Enum.reduce(req.drop, state, fn k, state ->
        %Req{act: :upd, key: k, fun: pop, tiny: true, !: {:avg, +1}}
        |> Req.handle(state)
        |> extract_state()
      end)

    # UPDATE:

    state =
      Enum.reduce(req.upd, state, fn {k, new_value}, state ->
        upd = fn _ -> {:_ret, new_value} end

        %Req{act: :upd, key: k, fun: upd, tiny: true, !: {:avg, +1}}
        |> Req.handle(state)
        |> extract_state()
      end)

    {:noreply, state}
  end
end
