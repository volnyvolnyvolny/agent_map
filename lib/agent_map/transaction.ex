defmodule AgentMap.Transaction do
  @moduledoc """
  This module contains functions for making transactional calls.
  """

  alias AgentMap.{Common, Req, CallbackError}

  import Common, only: [run: 2, to_ms: 1, reply: 2, extract: 2, handle_timeout_error: 2]
  import Req, only: [get_value: 2, timeout: 1]
  import System, only: [system_time: 0]

  require Logger

  @typedoc "The `AgentMap` name"
  @type name :: atom | {:global, term} | {:via, module, term}

  @typedoc "The `AgentMap` server (name, link, pid, …)"
  @type agentmap :: pid | {atom, node} | name | %AgentMap{}
  @type am :: agentmap

  @typedoc "The `AgentMap` key"
  @type key :: term

  @typedoc "The `AgentMap` value"
  @type value :: term

  ##
  ## HELPERS
  ##

  defp share(to: t) do
    k = Process.get(:"$key")
    v = Process.get(:"$value")
    send(t, {k, v})
  end

  defp accept() do
    receive do
      :drop ->
        :pop

      :id ->
        :id

      {:value, v} ->
        {:_, v}
    end
  end

  ##
  ## STAGES: prepair → collect → run → finalize
  ##

  defp worker?(key, state) do
    match?({:pid, _}, extract(key, state))
  end

  defp prepair(%{action: :get, !: true}, state) do
    # do nothing
    state
  end

  defp prepair(%{action: :get} = req, state) do
    {_, keys} = req.data

    s = self()

    fun = fn _ ->
      share(to: s)
    end

    req = %{req | timeout: :infinity}

    for key <- keys, worker?(key, state) do
      Req.handle(%{req | data: {key, fun}}, state)
    end

    state
  end

  defp prepair(%{action: :get_and_update} = req, state) do
    {_, keys} = req.data

    s = self()

    fun = fn _ ->
      share(to: s)
      accept()
    end

    req = %{req | timeout: :infinity}

    Enum.reduce(keys, state, fn key, state ->
      Req.handle(%{req | data: {key, fun}}, state)
    end)
  end

  defp collect(%{action: :get, !: true} = req, state) do
    {_, keys} = req.data

    for key <- keys do
      {key, get_value(key, state)}
    end
  end

  defp collect(req, state) do
    {_, keys} = req.data

    known =
      for key <- keys, not worker?(key, state), into: %{} do
        {key, get_value(key, state)}
      end

    passed = to_ms(system_time() - req.inserted_at)

    if timeout(req) > passed do
      unknown = keys -- Map.keys(known)
      _collect(known, unknown, timeout(req) - passed)
    else
      {:error, :expired}
    end
  end

  defp _collect(known, [], _), do: {:ok, known}

  defp _collect(known, unknown, timeout) do
    now = system_time()

    receive do
      {key, value} ->
        passed = to_ms(system_time() - now)
        timeout = timeout - passed

        known =
          case value do
            {:value, v} ->
              %{known | key => v}

            nil ->
              known
          end

        _collect(known, unknown -- [key], timeout)
    after
      timeout ->
        {:error, :expired}
    end
  end

  defp broadcast(keys, msg, state) do
    for key <- keys do
      {:pid, worker} = extract(key, state)
      send(worker, msg)
    end
  end

  defp commit(%{action: :get}, _, _, _), do: :nothing

  defp commit(%{action: :get_and_update} = req, values, result, state) do
    {_, keys} = req

    case result do
      :pop ->
        broadcast(keys, :drop, state)
        {:ok, values}

      :id ->
        broadcast(keys, :id, state)
        {:ok, values}

      {get, :id} ->
        broadcast(keys, :id, state)
        {:ok, get}

      {get, :drop} ->
        broadcast(keys, :id, state)
        {:ok, get}

      {get, values} when length(values) == length(keys) ->
        for {key, value} <- Enum.zip(keys, values) do
          {:pid, worker} = extract(key, state)
          send(worker, value)
        end

        {:ok, get}

      {_, values} ->
        {:error, {:update, values}}

      {get} ->
        broadcast(keys, :id, state)
        {:ok, get}

      lst when is_list(lst) and length(lst) == length(keys) ->
        get =
          for {key, ret} <- Enum.zip(keys, lst) do
            get = get_value(key, state)

            case ret do
              {get, v} ->
                {:pid, worker} = extract(key, state)
                send(worker, v)
                get

              {get} ->
                {:pid, worker} = extract(key, state)
                send(worker, :id)
                get

              :id ->
                {:pid, worker} = extract(key, state)
                send(worker, :id)
                get

              :pop ->
                {:pid, worker} = extract(key, state)
                send(worker, :drop)
                get
            end
          end

        {:ok, {:get, get}}

      _err ->
        {:error, {:callback, result}}
    end
  end

  ##
  ## MULTIPLE KEY HANDLERS
  ##

  ##
  ## (prepair) → (collect)
  ## → (Common.run) in a separate Task
  ## → (commit) → (Common.reply)
  ##

  @doc false
  def handle(req, state) do
    {_, keys} = req.data

    Task.start_link(fn ->
      state = prepair(req, state)

      case collect(req, state) do
        {:ok, known} ->
          Task.async(fn ->
            Process.put(:"$map", known)
            Process.put(:"$keys", keys)
            values = Enum.map(keys, &known[&1])

            with {:ok, result} <- run(req, values),
                 {:ok, get} <- commit(req, values, result, state) do
              reply(req.from, get)
            else
              {:error, {:callback, result}} ->
                raise CallbackError, got: result

              {:error, {:update, values}} ->
                raise CallbackError, len: length(values)

              {:error, :expired} ->
                handle_timeout_error(req, keys)

                for key <- keys do
                  {:pid, worker} = extract(key, state)
                  send(worker, :id)
                end
            end
          end)

        {:error, :expired} ->
          handle_timeout_error(req, keys)
      end

      {:noreply, state}
    end)
  end

  ##
  ## PUBLIC PART
  ##

  @doc """
  Computes `fun`, using `keys` values in agentmap as an argument.

  The function `fun` is sent to the `agentmap` which invokes callback, passing
  the value associated with `keys` (or `nil`s). The result of the invocation is
  returned from this function. This call will be executed in a separate `Task`
  after all the related values will be known. That mean that if any of the
  `keys` has a callbacks awaiting invocation, this call will wait until all of
  them will be executed (that does not prevent new callbacks to arrive).

  For ex.:

      get(Account, &Enum.sum/1, [:Alice, :Bob])

  returns sum of Alice and Bob balances in one operation.

  This calls are not counted in a number of processes allowed to run in parallel
  (see `AgentMap.max_processes/3`).

  ## Options

    * `!: true` — (`boolean`, `false`) if given, `fun` will be executed
    immediately, passing current values as an argument.

    To achieve the same affect, but on the client side, use the following:

        for key <- keys do
          case AgentMap.fetch(agentmap, key) do
            {:ok, value} ->
              value

            :error ->
              nil
          end
        end
        |> fun.()

    * `timeout: {:drop, pos_integer}` — to throw out a call from queue upon the
      occurence of a timeout. See [timeout section](#module-timeout);

    * `timeout: {:break, pos_integer}` — to throw out from queue or cancel a
      running call upon the occurence of a timeout. See [timeout
      section](#module-timeout);

    * `:timeout` — (`pos_integer | :infinity`, `5000`).

  ## Special process dictionary keys

  For a single-key calls one can use `:"$key"` and `:"$value"` dictionary keys.

      iex> import AgentMap
      iex> am = AgentMap.new(k: nil)
      iex> get(am, k, fn _ -> Process.get(:"$key") end)
      :k
      iex> get(am, k, fn nil -> Process.get(:"$value") end)
      {:value, nil}
      iex> get(am, f, fn nil -> Process.get(:"$value") end)
      nil

  For a transactions, one can use `:"$keys"` and `:"$map"` keys.

      iex> am = AgentMap.new(a: nil, b: 42)
      iex> AgentMap.get(am, fn _ ->
      ...>   Process.get(:"$keys")
      ...> end, [:a, :b, :c])
      [:a, :b, :c]
      iex> AgentMap.get(am, fn [nil, 42, nil] ->
      ...>   Process.get(:"$map")
      ...> end, keys)
      %{a: nil, b: 42}

  ## Examples

      iex> import AgentMap
      iex> am = AgentMap.new()
      iex> get(am, :Alice, & &1)
      nil
      iex> put(am, :Alice, 42)
      iex> get(am, :Alice, & &1+1)
      43
      #
      # Transactions.
      iex> put(am, :Bob, 43)
      iex> get(am, &Enum.sum/1, [:Alice, :Bob])
      85
      # Order matters.
      iex> get(am, {&Enum.reduce/3, [0, &-/2]}, [:Alice, :Bob])
      1
      iex> get(am, {&Enum.reduce/3, [0, &-/2]}, [:Bob, :Alice])
      -1

   "Priority" calls:

      iex> import AgentMap
      iex> import :timer
      iex> am = AgentMap.new(key: 42)
      iex> cast(am, :key, fn _ -> sleep(100); 43 end)
      iex> get(am, :key, & &1, !: true)
      42
      iex> am.key # the same
      42
      iex> get(am, :key, & &1)
      43
      iex> get(am, :key, & &1, !: true)
      43
  """
  @spec get(am, [key], ([value] -> get), keyword) :: get when get: var
  def get(agentmap, keys, fun, opts) when is_function(fun, 1) and is_list(keys) do
    req = %Req{action: :get, data: {fun, keys}}
    AgentMap._call(agentmap, req, opts)
  end

  @doc """
  Updates `agentmap` and returns some value.

  The function `fun` is sent to the `agentmap` which invokes callback passing
  the values associated with given `keys` (or `nil`s for the keys that are
  missing). The result of the invocation is returned from this function.

  This function expects to take a list of `keys` and transactional `fun`:

      get_and_update(agentmap, fun, [key1, key2, …], opts)

  where `fun` expected to take a list of values.

  Compare two calls:

      get_and_update(account, [:Alice, :Bob], fn [a,b] -> {:swapped, [b,a]} end)

  — the first one swapes Alice and Bob balances and returns `:swapped`, while
  the second one returns current Alice balance and deposits `1000000` dollars to
  it.

  Transaction `fun` can return:

    * a list with values `[{"get" value, new value} | {"get" value} | :id |
      :pop]`. This returns a list of "get" values. For ex.:

          iex> am = AgentMap.new(a: 1, b: 2, c: 3)
          iex> AgentMap.get_and_update(am, fn _ ->
          ...>   [{:get, :newvalue}, {:get}, :pop, :id]
          ...> end, [:a, :b, :c, :d])
          [:get, :get, nil, 3]
          iex> AgentMap.take(am, [:a, :b, :c, :d])
          %{a: 2, b: 2}

    * a tuple `{"get" value, [new value] | :id | :drop}`. For ex.:

          iex> import AgentMap
          iex> am = AgentMap.new(a: 1, b: 2, c: 3)
          iex> get_and_update(am, fn _ ->
          ...>   {:get, [4, 3, 2, 1]}
          ...> end, [:a, :b, :c, :d])
          :get
          iex> take(am, [:a, :b, :c, :d])
          %{a: 4, b: 3, c: 2, d: 1}
          iex> get_and_update(am, fn _ ->
          ...>   {:get, :id}
          ...> end, [:a, :b, :c, :d])
          :get
          iex> take(am, [:a, :b, :c, :d])
          %{a: 4, b: 3, c: 2, d: 1}
          iex> get_and_update(am, fn _ ->
          ...>   {:get, :drop}
          ...> end, [:b, :c])
          :get
          iex> keys(am)
          [:a, :d]

    * a one element tuple `{"get" value}`, that is the same as `{"get" value,
      :id}`;

    * `:id` to return values while not changing it;

    * `:pop` to return values while with given `keys` while removing them from
      `agentmap`'.

  For ex.:

      iex> %{alice: 42, bob: 24}
      ...> |> AgentMap.new()
      ...> |> get_and_update([:Alice, :Bob], fn [a, b] ->
      ...>      if a > 10 do
      ...>        a = a - 10
      ...>        b = b + 10
      ...>        [{a, a}, {b, b}] # [{get, new_state}]
      ...>      else
      ...>        {{:error, "Alice does not have 10$ to give to Bob!"}, [a, b]} # {get, [new_state]}
      ...>      end
      ...>    end)
      [32, 34]

  or:

      iex> alias AgentMap.Transaction, as: T
      iex> am = AgentMap.new(alice: 42, bob: 24)
      iex> T.get_and_update(am, [:Alice, :Bob], fn _ ->
      ...>   [:pop, :id]
      ...> end)
      [42, 24]
      iex> T.get(am, [:Alice, :Bob], & &1)
      [nil, 24]

  (!) State changing transactions (such as a `get_and_update`) will block
  execution for all the involving keys. For ex.:

      iex> import :timer
      iex> %{alice: 42, bob: 24, chris: 0}
      ...> |> AgentMap.new()
      ...> |> AgentMap.get_and_update(
      ...>      [:Alice, :Bob],
      ...>      &sleep(1000) && {:slept_well, &1}
      ...>    )
      :slept_well

  will block the possibility to `get_and_update`, `update`, `cast` and even
  non-priority `get` on `:Alice` and `:Bob` keys for 1 sec. Nonetheless values
  are always available for "priority" `get` calls. `chris` state is not blocked.

  Transactions are *Isolated* and *Durabled* (see, ACID model). *Atomicity* can
  be implemented inside callbacks and *Consistency* is out of question here as
  its the application level concept.

  ## Options

    * `!: true` — (`boolean`, `false`) to make [priority
      calls](#module-priority-calls-true). `key` could have an associated queue
      of callbacks, awaiting of execution. If such queue exists, "priority"
      version will add call to the begining of the queue (via "selective
      receive");

    * `timeout: {:drop, pos_integer}` — to throw out a call from queue upon the
      occurence of a timeout. See [timeout section](#module-timeout);

    * `timeout: {:break, pos_integer}` — to throw out from queue or cancel a
      running call upon the occurence of a timeout. See [timeout
      section](#module-timeout);

    * `:timeout` — (`pos_integer | :infinity`, `5000`).

  ## Examples

      iex> alias AgentMap.Transaction, as: T
      iex> import AgentMap
      iex> am = AgentMap.new(uno: 22, dos: 24)
      iex> T.get_and_update(am, [:uno, :dos], fn [u, d] ->
      ...>   [{u, d}, {d, u}]
      ...> end)
      [22, 24]
      iex> T.get(am, [:uno, :dos], & &1)
      [24, 22]
      #
      iex> T.get_and_update(am, [:dos], fn _ -> :pop end)
      [22]
      iex> has_key?(am, :dos)
      false
      #
      iex> T.get_and_update(am, [:dos], fn _ -> {:get} end)
      :get
      iex> has_key?(am, :dos)
      false
      #
      iex> put(am, :tres, 42)
      iex> put(am, :cuatro, 44)
      iex> T.get_and_update(am, [:uno, :dos, :tres, :cuatro], fn _ ->
      ...>   [:id, {nil, :_}, {:_, nil}, :pop]
      ...> end)
      [24, nil, :_, 44]
      iex> T.get(am, [:uno, :dos, :tres, :cuatro], & &1)
      [24, :_, nil, nil]
  """

  @typedoc """
  Callback that is used for a transactional call.
  """
  @type cb_t(get) ::
          ([value] ->
             {get}
             | {get, [value] | :drop | :id}
             | [{any} | {any, value} | :pop | :id]
             | :pop
             | :id)
  @spec get_and_update(am, [key], cb_t(get), keyword) :: get | [value]
        when get: var
  def get_and_update(agentmap, keys, fun, opts) when is_function(fun, 1) and is_list(keys) do
    unless keys == Enum.uniq(keys) do
      raise """
            expected uniq keys for `update`, `get_and_update` and
            `cast` transactions. Got: #{inspect(keys)}. Please
            check #{inspect(keys -- Enum.uniq(keys))} keys.
            """
            |> String.replace("\n", " ")
    end

    req = %Req{action: :get_and_update, data: {fun, keys}}
    AgentMap._call(agentmap, req, opts)
  end

  @doc """
  Updates the `keys` of `agentmap` with the given `fun` in one go.

  After `fun` is executed, returns unchanged `agentmap` argument to support
  piping.

  This call is no more than a syntax sugar for

      get_and_update(am, keys, &{am, fun.(&1)}, opts)

  Transactional `fun` can return:

    * a list of new values;
    * `:id` — instructs to leave values as they are;
    * `:drop`.

  ## Options

  The same as for `get_and_update/4`.

  ## Examples

      update(account, fn [a,b] -> [b,a] end, [:Alice, :Bob])

  swapes balances of Alice and Bob.

  More:

      iex> alias AgentMap.Transaction, as: T
      iex> import AgentMap
      iex> am = new(a: 42, b: 24, c: 33, d: 51)
      iex> T.get(am, [:a, :b, :c, :d], & &1)
      [42, 24, 33, 51]
      iex> am
      ...> |> T.update([:a, :b], &Enum.reverse/1)
      ...> |> T.get([:a, :b, :c, :d], & &1)
      [24, 42, 33, 51]
      iex> am
      ...> |> T.update([:a, :b], fn _ -> :drop end)
      ...> |> keys()
      [:c, :d]
      iex> am
      ...> |> T.update([:c], fn _ -> :drop end)
      ...> |> update(:d, fn _ -> :drop end)
      ...> |> T.get([:c, :d], & &1)
      [nil, :drop]
  """
  @spec update(am, ([value] -> [value] | :drop | :id), [key], keyword) :: am
  def update(agentmap, keys, fun, opts \\ [!: false, timeout: 5000])
      when is_function(fun, 1) and is_list(keys) do
    req = %Req{action: :get_and_update, data: {fun, keys}}
    AgentMap._call(agentmap, req, opts)
  end

  @doc """
  Performs `cast` transactional call ("fire and forget"). Works the same as
  corresponding `update/4`, but uses `GenServer.cast/2`.

  Immediately returns `agentmap` argument unchanged to support piping.

  The options are the same as for `get_and_update/4`, except for the `timeout:
  pos_integer`.
  """
  @spec cast(am, ([value] -> [value]), [key], keyword) :: am
  @spec cast(am, ([value] -> :drop | :id), [key], keyword) :: am
  def cast(agentmap, keys, fun, opts \\ [!: false]) when is_function(fun, 1) and is_list(keys) do
    req = %Req{action: :get_and_update, data: {fun, keys}}
    AgentMap._call(agentmap, req, opts)
  end
end
