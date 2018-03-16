# AgentMap

  `AgentMap` is a `GenServer` that holds `Map` and provides concurrent access
  via `Agent` API for operations made on different keys. Basically, it can be
  used as a cache, memoization and computational framework and, sometimes, as a
  `GenServer` replacement.

  `AgentMap` can be seen as a `Map`, each value of that is an `Agent`. When a
  callback that change state (see `update/3`, `get_and_update/3`, `cast/3` and
  derivatives) comes in, special temporary process (called "worker") is created.
  That process holds queue of callbacks for corresponding key. `AgentMap`
  respects order in which callbacks arrives and supports transactions —
  operations that simultaniously change group of values.

  Module API is in fact a copy of the `Agent`'s and `Map`'s modules. Special
  struct that allows to use `Enum` module and `[]` operator can be created via
  `new/1` function.

  ## Examples

  Let's create an accounting.

      defmodule Account do
        use AgentMap

        def start_link() do
          AgentMap.start_link name: __MODULE__
        end

        @doc """
        Returns `{:ok, balance}` for account or `:error` if account
        is unknown.
        """
        def balance(account), do: AgentMap.fetch __MODULE__, account

        @doc """
        Withdraw. Returns `{:ok, new_amount}` or `:error`.
        """
        def withdraw(account, amount) do
          AgentMap.get_and_update __MODULE__, account, fn
            nil ->     # no such account
              {:error} # (!) returning {:error, nil} would create key with nil value
            balance when balance > amount ->
              {{:ok, balance-amount}, balance-amount}
            _ ->
              {:error}
          end
        end

        @doc """
        Deposit. Returns `{:ok, new_amount}` or `:error`.
        """
        def deposit(account, amount) do
          AgentMap.get_and_update __MODULE__, account, fn
            nil ->
              {:error}
            balance ->
              {{:ok, balance+amount}, balance+amount}
          end
        end

        @doc """
        Trasfer money. Returns `:ok` or `:error`.
        """
        def transfer(from, to, amount) do
          AgentMap.get_and_update __MODULE__, fn # transaction call
            [nil, _] -> {:error}
            [_, nil] -> {:error}
            [b1, b2] when b1 >= amount ->
              {:ok, [b1-amount, b2+amount]}
            _ -> {:error}
          end, [from, to]
        end

        @doc """
        Close account. Returns `:ok` if account exists or
        `:error` in other case.
        """
        def close(account) do
          if AgentMap.has_key? __MODULE__, account do
            AgentMap.delete __MODULE__, account
            :ok
          else
            :error
          end
        end

        @doc """
        Open account. Returns `:error` if account exists or
        `:ok` in other case.
        """
        def open(account) do
          AgentMap.get_and_update __MODULE__, account, fn
            nil -> {:ok, 0} # set balance to 0, while returning :ok
            _   -> {:error} # return :error, do not change balance
          end
        end
      end

  Memoization example.

      defmodule Memo do
        use AgentMap

        def start_link() do
          AgentMap.start_link name: __MODULE__
        end

        def stop(), do: AgentMap.stop __MODULE__


        @doc """
        If `{task, arg}` key is known — return it, else, invoke given `fun` as
        a Task, writing result under `{task, arg}`.
        """
        def calc(task, arg, fun) do
          AgentMap.get_and_update __MODULE__, {task, arg}, fn
            nil ->
              res = fun.(arg)
              {res, res}
            _value ->
              :id # change nothing, return current value
          end
        end
      end

      defmodule Calc do
        def fib(0), do: 0
        def fib(1), do: 1
        def fib(n) when n >= 0 do
          Memo.calc(:fib, n, fn n -> fib(n-1)+fib(n-2) end)
        end
      end

  Similar to `Agent`, any changing state function given to the `AgentMap`
  effectively blocks execution of any other function **on the same key** until
  the request is fulfilled. So it's important to avoid use of expensive
  operations inside the agentmap. See corresponding `Agent` docs section.

  Finally note that `use AgentMap` defines a `child_spec/1` function, allowing
  the defined module to be put under a supervision tree. The generated
  `child_spec/1` can be customized with the following options:

    * `:id` - the child specification id, defauts to the current module
    * `:start` - how to start the child process (defaults to calling `__MODULE__.start_link/1`)
    * `:restart` - when the child should be restarted, defaults to `:permanent`
    * `:shutdown` - how to shut down the child

  For example:

      use AgentMap, restart: :transient, shutdown: 10_000

  See the `Supervisor` docs for more information.

  ## Name registration

  An agentmap is bound to the same name registration rules as GenServers. Read
  more about it in the `GenServer` documentation.

  ## A word on distributed agents/agentmaps

  See corresponding `Agent` module section.

  ## Hot code swapping

  A agentmap can have its code hot swapped live by simply passing a module,
  function, and arguments tuple to the update instruction. For example, imagine
  you have a agentmap named `:sample` and you want to convert all its inner
  states from a keyword list to a map. It can be done with the following
  instruction:

      {:update, :sample, {:advanced, {Enum, :into, [%{}]}}}

  The agentmap's states will be added to the given list of arguments
  (`[%{}]`) as the first argument.

  ## Using `Enum` module and `[]`-access operator

  `%AgentMap{}` is a special struct that contains pid of the `agentmap` process
  and for that `Enumerable` protocol is implemented. So, `Enum` should work as
  expected:

      iex> AgentMap.new() |> Enum.empty?()
      true
      iex> AgentMap.new(key: 42) |> Enum.empty?()
      false

  Similarly, `AgentMap` follows `Access` behaviour, so `[]` operator could be
  used:

      iex> AgentMap.new(a: 42, b: 24)[:a]
      42

  except of `put_in` operator.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `agent_map` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:agent_map, "~> 1.0.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/multi_agent](https://hexdocs.pm/multi_agent).

