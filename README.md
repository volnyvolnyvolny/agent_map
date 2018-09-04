# AgentMap

The `AgentMap` can be seen as a stateful `Map` that parallelize operations
made on different keys. Basically, it can be used as a cache, memoization,
computational framework and, sometimes, as a `GenServer` replacement.

Underneath it's a `GenServer` that holds a `Map`. When an `update/4`,
`update!/4`, `get_and_update/4` or `cast/4` is first called for a key, a
special temporary process called "worker" is spawned. All subsequent calls for
that key will be forwarded to the message queue of this worker. This process
respects the order of incoming new calls, executing them in a sequence, except
for the `get/4` calls, which are processed as a parallel `Task`s. For each
key, the degree of parallelization can be tweaked using the `max_processes/3`
function. The worker will die after about `10` ms of inactivity.

`AgentMap` supports transactions — operations on a group of keys. See
`AgentMap.Transaction`.

## Examples

Create and use it as an ordinary `Map`:

    iex> am = AgentMap.new(a: 42, b: 24)
    iex> am.a
    42
    iex> AgentMap.keys(am)
    [:a, :b]
    iex> am
    ...> |> AgentMap.update(:a, & &1 + 1)
    ...> |> AgentMap.update(:b, & &1 - 1)
    ...> |> AgentMap.take([:a, :b])
    %{a: 43, b: 23}

The special struct `%AgentMap{}` can be created via the `new/1` function. This
[allows](#module-enumerable-protocol-and-access-behaviour) to use the
`Enumerable` protocol and to take benefit from the `Access` behaviour.

Also, `AgentMap` can be started in an `Agent` manner:

    iex> {:ok, pid} = AgentMap.start_link()
    iex> pid
    ...> |> AgentMap.put(:a, 1)
    ...> |> AgentMap.get(:a)
    1
    iex> am = AgentMap.new(pid)
    iex> am.a
    1

More complicated example involves memoization:

    defmodule Calc do
      def fib(0), do: 0
      def fib(1), do: 1
      def fib(n) when n >= 0 do
        unless GenServer.whereis(__MODULE__) do
          AgentMap.start_link(name: __MODULE__)
          fib(n)
        else
          AgentMap.get_and_update(__MODULE__, n, fn
            nil ->
              # This calculation will be made in a separate
              # worker process.
              res = fib(n - 1) + fib(n - 2)
              # Return `res` and set it as a new value.
              {res, res}

            _value ->
              # Change nothing, return current value.
              :id
          end)
        end
      end
    end

Also, take a look at the `test/memo.ex`.

`AgentMap` provides possibility to make transactions (operations on multiple
keys). Let's see an accounting demo:

    defmodule Account do
      def start_link() do
        AgentMap.start_link(name: __MODULE__)
      end

      def stop() do
        AgentMap.stop(__MODULE__)
      end

      @doc """
      Returns `{:ok, balance}` or `:error` in case there is no
      such account.
      """
      def balance(account) do
        AgentMap.fetch(__MODULE__, account)
      end

      @doc """
      Withdraws money. Returns `{:ok, new_amount}` or `:error`.
      """
      def withdraw(account, amount) do
        AgentMap.get_and_update(__MODULE__, account, fn
          nil ->     # no such account
            {:error} # (!) refrain from returning `{:error, nil}`
                     # as it would create key with `nil` value

          balance when balance > amount ->
            balance = balance - amount
            {{:ok, balance}, balance}

          _balance ->
            # Returns `:error`, while not changing value.
            {:error}
        end)
      end

      @doc """
      Deposits money. Returns `{:ok, new_amount}` or `:error`.
      """
      def deposit(account, amount) do
        AgentMap.get_and_update(__MODULE__, account, fn
          nil ->
            {:error}

          balance ->
            balance = balance + amount
            {{:ok, balance}, balance}
        end)
      end

      @doc """
      Trasfers money. Returns `:ok` or `:error`.
      """
      def transfer(from, to, amount) do
        # Transaction call.
        AgentMap.get_and_update(__MODULE__, fn
          [nil, _] -> {:error}

          [_, nil] -> {:error}

          [b1, b2] when b1 >= amount ->
            {:ok, [b1 - amount, b2 + amount]}

          _ -> {:error}
        end, [from, to])
      end

      @doc """
      Closes account. Returns `:ok` or `:error`.
      """
      def close(account) do
        AgentMap.pop(__MODULE__, account) && :ok || :error
      end

      @doc """
      Opens account. Returns `:ok` or `:error`.
      """
      def open(account) do
        AgentMap.get_and_update(__MODULE__, account, fn
          nil ->
            # Sets balance to 0, while returning :ok.
            {:ok, 0}

          _balance ->
            # Returns :error, while not changing balance.
            {:error}
        end)
      end
    end

## `Enumerable` protocol and `Access` behaviour

`%AgentMap{}` is a special struct that holds the pid of an `agentmap` process.
`Enumerable` protocol is implemented for `%AgentMap{}`, so `Enum` should work
as expected:

    iex> %{answer: 42}
    ...> |> AgentMap.new()
    ...> |> Enum.empty?()
    false

Similary, `AgentMap` follows the `Access` behaviour:

    iex> am = AgentMap.new(a: 42, b: 24)
    iex> am.a
    42

(!) currently `put_in` operator does not work properly.

## Options

### Priority calls (`!: true`)

Most of the functions support `!: true` option to make out-of-turn
("priority") calls.

By default, on each key, no more than fifth `get/4` calls can be executed
simultaneously. If `update!/4`, `update/4`, `cast/4`, `get_and_update/4` or a
`6`-th `get/4` call came, a special worker process will be spawned that became
the holder of the execution queue. It's the FIFO queue, but [selective
receive](http://learnyousomeerlang.com/more-on-multiprocessing) is used to
provide the possibility for some callbacks to be executed in the order of
preference (out of turn).

For example:

    iex> import AgentMap
    iex> import :timer
    iex> am = AgentMap.new(state: :ready)
    iex> am
    ...> |> cast(:state, fn _ -> sleep(50); :steady end)
    ...> |> cast(:state, fn _ -> sleep(50); :stop end)
    ...> |> cast(:state, fn _ -> sleep(50); :go! end, !: true)
    :ok
    iex> fetch(am, :state)
    {:ok, :ready}
    # — current state.
    # Right now :steady is executed.
    #
    iex> queue_len(am, :state)
    2
    # [:go!, :stop]
    iex> queue_len(am, :state, !: true)
    1
    # [:go!]
    iex> [get(am, :state),
    ...>  get(am, :state, !: true),
    ...>  get(am, :state, & &1, !: true),
    ...>  am.state]
    [:ready, :ready, :ready, :ready]
    # As the fetch/2, returns current state immediatelly.
    #
    iex> get(am, :state, !: false)
    :steady
    # Now executes: :go!, queue: [:stop],
    # because `!: true` are out of turn.
    #
    iex> get(am, :state, !: false)
    :go!
    # Now executes: :stop, queue: [].
    iex> get(am, :state, !: false)
    :stop

Keep in mind that selective receive can lead to performance issues if the
message queue becomes too fat. So it was decided to disable selective receive
each time message queue of the worker process has more that `100` items. It
will be turned on again when message queue became empty.

### Timeout

Timeout is an integer greater than zero which specifies how many milliseconds
are allowed before the `agentmap` executes the `fun` and returns a result, or
an atom `:infinity` to wait indefinitely. If no result is received within the
specified time, the caller exits. By default it is set to the `5000 ms` = `5
sec`.

For example:

    get_and_update(agentmap, :key, fun)
    get_and_update(agentmap, :key, fun, 5000)
    get_and_update(agentmap, :key, fun, timeout: 5000)
    get_and_update(agentmap, :key, fun, timeout: 5000, !: false)

means the same.

If no result is received within the specified time, the caller exits, (!) but
the callback will remain in a queue!

    iex> import AgentMap
    iex> import :timer
    iex> Process.flag(:trap_exit, true)
    iex> am =
    ...>   AgentMap.new(key: 42)
    iex> am
    ...> |> cast(:key, fn v -> sleep(50); v - 9 end)
    ...> |> put(:key, 24, timeout: 10)
    iex> Process.info(self())[:message_queue_len]
    1
    # — 10 ms later, there was a timeout.
    #
    iex> get(am, :key)
    42
    # — cast call is still executed.
    iex> get(am, :key, !: false)
    24
    # — after 40 ms, cast/4 and put/4 calls are executed.

— to change this behaviour, provide `{:drop, timeout}` value. For instance, in
this call:

    iex> import AgentMap
    iex> import :timer
    iex> Process.flag(:trap_exit, true)
    iex> am =
    ...>   AgentMap.new(key: 42)
    iex> am
    ...> |> cast(:key, fn v -> sleep(50); v - 9 end)
    ...> |> put(:key, 24, timeout: {:drop, 10})
    ...> |> get(:key, !: false)
    33
    iex> Process.info(self())[:message_queue_len]
    1

`put/4` was never executed because it was dropped from queue, although,
`GenServer` exit signal will be send.

If timeout happen while callback is executed — it will not be interrupted. For
this case special `{:break, pos_integer}` option exist that instructs
`AgentMap` to wrap call in a `Task`:

    import :timer
    AgentMap.cast(
      agentmap,
      :key,
      fn _ -> sleep(:infinity) end,
      timeout: {:break, 6000}
    )

In this particular case the `fn _ -> sleep(:infinity) end` callback is wrapped
in a `Task` which has `6` sec before shutdown.

## Name registration

An agentmap is bound to the same name registration rules as `GenServers`, see
the `GenServer` documentation for details.

## Other

Finally, note that `use AgentMap` defines a `child_spec/1` function, allowing
the defined module to be put under a supervision tree. The generated
`child_spec/1` can be customized with the following options:

* `:id` - the child specification id, defauts to the current module;
* `:start` - how to start the child process (defaults to calling
  `__MODULE__.start_link/1`);
* `:restart` - when the child should be restarted, defaults to `:permanent`;
* `:shutdown` - how to shut down the child.

For example:

    use AgentMap, restart: :transient, shutdown: 10_000

See the `Supervisor` docs for more information.
