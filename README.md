# AgentMap

`AgentMap` can be seen as a stateful `Map` that parallelize operations made on
different keys.

For instance, execution of this code:

```elixir
map =                                         #  am =
  %{a: 1, b: 1}                               #    %{a: 1, b: 1}
  |> Map.new()                                #    |> AgentMap.new()
  |> Map.update!(:a, &(sleep(10) && &1 + 1))  #    |> AgentMap.cast(:a, …)
  |> Map.update!(:b, &(sleep(10) && &1 + 1))  #    |> AgentMap.cast(:b, …)
                                              #
Map.get(map, :a) == 2                         #  AgentMap.get(am, :a) == 2
Map.get(map, :b) == 2                         #  AgentMap.get(am, :b) == 2
```

will take about `20` ms. While the following is twice as fast due to
parallelization:

```elixir
am =
  %{a: 1, b: 1}
  |> AgentMap.new()
  |> AgentMap.cast(:a, &(sleep(10) && &1 + 1))
  |> AgentMap.cast(:b, &(sleep(10) && &1 + 1))
                          
AgentMap.get(am, :a) == 2 
AgentMap.get(am, :b) == 2 
```

Basically, `AgentMap` can be used as a memoization, computational framework and,
sometimes, as an alternative to `GenServer`. `AgentMap` supports operations made
on a group of keys (["multi-key" calls](AgentMap.Multi.html)).

See [documentation](https://hexdocs.pm/agent_map) for the details.

## Examples

`AgentMap` can be started in an `Agent` manner:

```elixir
iex> {:ok, pid} = AgentMap.start_link()
iex> pid
...> |> AgentMap.put(:a, 1)
...> |> AgentMap.get(:a)
1
```

Or similarly to an ordinary `Map`:

```elixir
iex> am = AgentMap.new(a: 42, b: 24)
iex> AgentMap.get(am, :a)
42
iex> AgentMap.keys(am)
[:a, :b]
iex> am
...> |> AgentMap.update(:a, & &1 + 1)
...> |> AgentMap.update(:b, & &1 - 1)
...> |> AgentMap.take([:a, :b])
%{a: 43, b: 23}
```

Function `new/1` creates a special `%AgentMap{}` struct that is compatible with
`Enumerable` and `Collectable` protocols.

```elixir
iex> {:ok, pid} = AgentMap.start_link()
iex> am = AgentMap.new(pid)
...> Enum.empty?(am)
true
#
iex> Enum.into([a: 1, b: 2], am)
iex> AgentMap.take(am, [:a, :b])
...> %{a: 1, b: 2}
```

More complicated example involves memoization:

```elixir
defmodule Calc do
  def fib(0), do: 0
  def fib(1), do: 1
  def fib(n) when n >= 0 do
    unless GenServer.whereis(Calc) do
      AgentMap.start_link([], name: Calc)
      fib(n)
    else
      AgentMap.get_and_update(Calc, n, fn
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
```

Take a look at the
[test/memo.ex](https://github.com/zergera/agent_map/blob/master/test/memo.ex).

`AgentMap` provides a possibility to make multi-key calls (operations on
multiple keys). Let's see an accounting demo:

```elixir
defmodule Account do
  def start_link() do
    AgentMap.start_link([], name: __MODULE__)
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
      nil ->
        # no such account
        {:error}

      balance when balance > amount ->
        balance = balance - amount
        {{:ok, balance}, balance}

      _balance ->
        # Returns `:error`, while not changing value.
        {:error}
    end)
  end

  @doc """
  Deposits money. Returns `{:ok, new balance}`.
  """
  def deposit(account, amount) do
    AgentMap.get_and_update(__MODULE__, account, fn
      b ->
        {{:ok, b + amount}, b + amount}
    end, initial: 0)
  end

  @doc """
  Trasfers money. Returns `:ok` or `:error`.
  """
  def transfer(from, to, amount) do
    AgentMap.Multi.get_and_update(__MODULE__, [from, to], fn
      [nil, _] -> {:error}

      [_, nil] -> {:error}

      [b1, b2] when b1 >= amount ->
        {:ok, [b1 - amount, b2 + amount]}

      _ -> {:error}
    end)
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
```

## Installation

`AgentMap` requires Elixir `v1.8` Add `:agent_map`to your list of dependencies
in `mix.exs`:

```elixir
def deps do
    [{:agent_map, "~> 1.1"}]
end
```

## License

[MIT](https://github.com/zergera/agent_map/blob/dev/LICENSE).
