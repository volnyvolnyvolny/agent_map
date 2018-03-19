defmodule AgentMap do
  @behaviour Access

  @enforce_keys [:link]
  defstruct @enforce_keys

  alias AgentMap.{Callback, Server, Req}

  import Callback, only: :macros

  @moduledoc """
  `AgentMap` is a `GenServer` that holds `Map` and provides concurrent access
  via `Agent` API for operations made on different keys. Basically, it can be
  used as a cache, memoization and computational framework or, sometimes, as a
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

        @doc \"""
        Returns `{:ok, balance}` for account or `:error` if account
        is unknown.
        \"""
        def balance(account), do: AgentMap.fetch __MODULE__, account

        @doc \"""
        Withdraw. Returns `{:ok, new_amount}` or `:error`.
        \"""
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

        @doc \"""
        Deposit. Returns `{:ok, new_amount}` or `:error`.
        \"""
        def deposit(account, amount) do
          AgentMap.get_and_update __MODULE__, account, fn
            nil ->
              {:error}
            balance ->
              {{:ok, balance+amount}, balance+amount}
          end
        end

        @doc \"""
        Trasfer money. Returns `:ok` or `:error`.
        \"""
        def transfer(from, to, amount) do
          AgentMap.get_and_update __MODULE__, fn # transaction call
            [nil, _] -> {:error}
            [_, nil] -> {:error}
            [b1, b2] when b1 >= amount ->
              {:ok, [b1-amount, b2+amount]}
            _ -> {:error}
          end, [from, to]
        end

        @doc \"""
        Close account. Returns `:ok` if account exists or
        `:error` in other case.
        \"""
        def close(account) do
          if AgentMap.has_key? __MODULE__, account do
            AgentMap.delete __MODULE__, account
            :ok
          else
            :error
          end
        end

        @doc \"""
        Open account. Returns `:error` if account exists or
        `:ok` in other case.
        \"""
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

        @doc \"""
        If `{task, arg}` key is known — return it, else, invoke given `fun` as
        a Task, writing result under `{task, arg}`.
        \"""
        def calc(task, arg, fun) do
          AgentMap.get_and_update __MODULE__, {task, arg}, fn
            nil ->
              res = fun.(arg)
              {res, res}

            _value ->
              # Change nothing, return current value.
              :id
          end
        end
      end

      defmodule Calc do
        def fib(0), do: 0
        def fib(1), do: 1

        def fib(n) when n >= 0 do
          Memo.calc(:fib, n, fn n -> fib(n - 1) + fib(n - 2) end)
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

  `AgentMap` can have its code hot swapped live by simply passing a module,
  function, and arguments tuple to the update instruction. For example, imagine
  you have an `AgentMap` named `:sample` and you want to convert all its inner
  values from a keyword list to a map. It can be done with the following
  instruction:

      {:update, :sample, {:advanced, {Enum, :into, [%{}]}}}

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
  """

  @typedoc "Return values of `start*` functions"
  @type on_start :: {:ok, pid} | {:error, {:already_started, pid} | term}

  @typedoc "The agentmap name"
  @type name :: atom | {:global, term} | {:via, module, term}

  @typedoc "The agentmap reference"
  @type agentmap :: pid | {atom, node} | name | %AgentMap{}
  @type a_map :: agentmap

  @typedoc "The agentmap key"
  @type key :: term

  @typedoc "The agentmap value"
  @type value :: term

  @typedoc "Anonymous function, `{fun, args}` or MFA triplet"
  @type a_fun(a, r) :: (a -> r) | {(... -> r), [a | any]} | {module, atom, [a | any]}

  @typedoc "Anonymous function with zero arity, pair `{fun/length(args), args}` or corresponding MFA tuple"
  @type a_fun(r) :: (() -> r) | {(... -> r), [any]} | {module, atom, [any]}

  @typedoc "Options for :get, :get_and_update, :update and :cast methods"
  @type options :: [!: boolean, timeout: timeout] | timeout

  @doc false
  def child_spec(funs_and_opts) do
    %{id: AgentMap, start: {AgentMap, :start_link, [funs_and_opts]}}
  end

  @doc false
  defmacro __using__(opts) do
    quote location: :keep, bind_quoted: [opts: opts] do
      @doc false
      def child_spec(funs_and_opts) do
        default = %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [funs_and_opts]}
        }

        Supervisor.child_spec(default, unquote(Macro.escape(opts)))
      end

      defoverridable child_spec: 1
    end
  end

  ## HELPERS ##

  defp pid(%__MODULE__{link: mag}), do: mag
  defp pid(mag), do: mag

  ## ##

  # common for start_link and start
  # separate funs from GenServer options
  defp separate(funs_and_opts) do
    {opts, funs} =
      funs_and_opts
      |> Enum.reverse()
      |> Enum.split_while(fn {k, _} ->
        k in [:name, :timeout, :debug, :spawn_opt]
      end)

    {Enum.reverse(funs), opts}
  end

  @doc """
  Returns a new empty `agentmap`.

  ## Examples

      iex> mag = AgentMap.new()
      iex> Enum.empty?(mag)
      true
  """
  @spec new :: agentmap
  def new, do: new(%{})

  @doc """
  Starts an `AgentMap` via `start_link/1` function. `new/1` returns `AgentMap`
  **struct** that contains pid of the `AgentMap`.

  As the only argument, states keyword can be provided or already started
  agentmap.

  ## Examples

      iex> mag = AgentMap.new(a: 42, b: 24)
      iex> mag[:a]
      42
      iex> AgentMap.keys(mag)
      [:a, :b]

      iex> {:ok, pid} = AgentMap.start_link()
      iex> mag = AgentMap.new(pid)
      iex> AgentMap.put(mag, :a, 1)
      iex> mag[:a]
      1
  """
  @spec new(Enumerable.t() | a_map) :: a_map
  def new(enumerable)

  def new(%__MODULE__{} = mag), do: mag
  def new(%_{} = struct), do: new(Map.new(struct))
  def new(list) when is_list(list), do: new(Map.new(list))

  def new(%{} = states) when is_map(states) do
    states =
      for {key, state} <- states do
        {key, fn -> state end}
      end

    {:ok, mag} = start_link(states)
    new(mag)
  end

  def new(mag), do: %__MODULE__{link: GenServer.whereis(mag)}

  @doc """
  Creates an agentmap from an `enumerable` via the given transformation
  function. Duplicated keys are removed; the latest one prevails.

  ## Examples

      iex> mag = AgentMap.new([:a, :b], fn x -> {x, x} end)
      iex> AgentMap.take(mag, [:a, :b])
      %{a: :a, b: :b}
  """
  @spec new(Enumerable.t(), (term -> {key, value})) :: a_map
  def new(enumerable, transform) do
    new(Map.new(enumerable, transform))
  end

  @doc """
  Starts an agentmap linked to the current process with the given function. This
  is often used to start the agentmap as a part of a supervision tree.

  The only argument is a keyword, elements of which is `GenServer.options` or
  pairs `{term, a_fun(any)}`, where `a_fun(any)` is a zero arity anonymous fun,
  pair `{fun, args}` or corresponding MFA-tuple.

  For each key, callback is executed as a separate `Task`.

  ## Options

  The `:name` option is used for registration as described in the module
  documentation.

  If the `:timeout` option is present, the agentmap is allowed to spend at most
  the given number of milliseconds on the whole process of initialization or it
  will be terminated and the start function will return `{:error, :timeout}`.

  If the `:debug` option is present, the corresponding function in the [`:sys`
  module](http://www.erlang.org/doc/man/sys.html) will be invoked.

  If the `:spawn_opt` option is present, its value will be passed as options to
  the underlying process as in `Process.spawn/4`.

  ## Return values

  If the server is successfully created and initialized, the function returns
  `{:ok, pid}`, where `pid` is the PID of the server. If a agentmap with the
  specified name already exists, the function returns `{:error,
  {:already_started, pid}}` with the PID of that process.

  If one of the callbacks fails, the function returns `{:error, [{key,
  init_error_reason}]}`, where `init_error_reason` is `:timeout`, `:badfun`,
  `:badarity` `:exists` or an arbitrary exception. Callback must be given in
  form of anonymous function, `{fun, args}` or MFA-tuple, or else `:badfun`
  would be returned. So you can write:

      iex> import AgentMap
      iex> {:ok,_pid} = start_link(key: fn -> Enum.empty? [:v] end)
      iex> {:ok,_} = start_link(k: {&Enum.empty?/1, [[:v]]})
      iex> {:ok,_} = start_link(k: {Enum, :empty?, [[:v]]})
      iex> {:ok,_} = start_link(k: {fn -> Enum.empty? [:v] end, []})
      iex> match?({:ok,_}, start_link(k: {& &1+1, [42]}))
      true

  But it's easy to get `{:error, :badfun}` or `{:error, :badarity}`:

      iex> AgentMap.start(key: 42)
      {:error, [key: :badfun]}
      iex> AgentMap.start(key: {fn -> Enum.empty? [] end, [:extraarg]})
      {:error, [key: :badarity]}
      # … and so on

  ## Examples

      iex> {:ok, pid} = AgentMap.start_link(key: fn -> 42 end)
      iex> AgentMap.get(pid, :key, & &1)
      42
      iex> AgentMap.get(pid, :nosuchkey, & &1)
      nil
  """
  @spec start_link([{key, a_fun(any)} | GenServer.option()]) :: on_start
  def start_link(funs_and_opts \\ [timeout: 5000]) do
    {funs, opts} = separate(funs_and_opts)
    timeout = opts[:timeout] || 5000
    # Turn off global timeout.
    opts = Keyword.put(opts, :timeout, :infinity)
    GenServer.start_link(Server, {funs, timeout}, opts)
  end

  @doc """
  Starts an `AgentMap` as unlinked process.

  See `start_link/2` for details.

  ## Examples

      iex> AgentMap.start(one: 42,
      ...>                two: fn -> :timer.sleep(150) end,
      ...>                three: fn -> :timer.sleep(:infinity) end,
      ...>                timeout: 100)
      {:error, [one: :badfun, two: :timeout, three: :timeout]}

      iex> AgentMap.start(one: :foo,
      ...>                one: :bar,
      ...>                three: fn -> :timer.sleep(:infinity) end,
      ...>                timeout: 100)
      {:error, [one: :exists]}

      iex> err = AgentMap.start(one: 76,
      ...>                      two: fn -> raise "oops" end)
      iex> {:error, [one: :badfun, two: {exception, _stacktrace}]} = err
      iex> exception
      %RuntimeError{message: "oops"}
  """
  @spec start([{key, a_fun(any)} | GenServer.option()]) :: on_start
  def start(funs_and_opts \\ [timeout: 5000]) do
    {funs, opts} = separate(funs_and_opts)
    timeout = opts[:timeout] || 5000
    # Turn off global timeout.
    opts = Keyword.put(opts, :timeout, :infinity)
    GenServer.start(Server, {funs, timeout}, opts)
  end

  defp call(agentmap, req, opts \\ 5000)

  defp call(agentmap, req, :infinity) do
    call(agentmap, req, timeout: :infinity)
  end

  defp call(agentmap, req, timeout) when is_integer(timeout) do
    call(agentmap, req, timeout: timeout)
  end

  defp call(agentmap, req, opts) do
    req = %{req | !: Keyword.get(opts, :!, false)}

    if req.action == :cast do
      GenServer.cast(pid(agentmap), req)
    else
      timeout = Keyword.get(opts, :timeout, 5000)
      GenServer.call(pid(agentmap), req, timeout)
    end
  end

  ##
  ## GET
  ##

  @doc """
  Takes value(s) for the given `key`(s) and invokes `fun`, passing values as the
  first argument and `nil`(s) for the values that are lost. If there are
  callbacks awaiting invocation, this call will be added to the end of the
  corresponding queues. Because the `get` calls do not change states —
  `agentmap` can and will be executed concurrently, in no more than
  `max_threads` (this could be tweaked per key, via `max_threads/2` call).

  As in the case of `update`, `get_and_update` and `cast` methods, `get` call
  has two forms:

    * single key: `get(agentmap, key, fun)`, where `fun` expected only one value
      to be passed;
    * and multiple keys (transactions): `get(agentmap, fun, [key1, key2, …])`,
      where `fun` expected to take a list of values.

  For example, compare two calls:

      AgentMap.get(Account, &Enum.sum/1, [:alice, :bob])
      AgentMap.get(Account, :alice, & &1)

  — the first one returns sum of Alice and Bob balances in one operation, while
  the second one returns amount of money Alice has.

  ## Options

  `timeout` is an integer greater than zero which specifies how many
  milliseconds are allowed before the `agentmap` executes the `fun` and returns
  the result value, or the atom `:infinity` to wait indefinitely. If no result
  is received within the specified time, the caller exits. By default it's equal
  to `5000` ms. This value could be given as `:timeout` option, or separately,
  so:

      AgentMap.get(agentmap, :key, fun)
      AgentMap.get(agentmap, :key, fun, 5000)
      AgentMap.get(agentmap, :key, fun, timeout: 5000)
      AgentMap.get(agentmap, :key, fun, timeout: 5000, !: false)

  means the same.

  The `:!` option is used to make "urgent" calls. Values could have an
  associated queue of callbacks, awaiting of execution. "Urgent" version allows
  to retrive value immediately at the moment of call. If this option is
  provided, `fun` will be always executed in a separate `Task`.

  ## Examples

      iex> mag = AgentMap.new()
      iex> AgentMap.get(mag, :alice, & &1)
      nil
      iex> AgentMap.put(mag, :alice, 42)
      iex> AgentMap.get(mag, :alice, & &1+1)
      43
      #
      # aggregate calls:
      #
      iex> AgentMap.put(mag, :bob, 43)
      iex> AgentMap.get(mag, &Enum.sum/1, [:alice, :bob])
      85
      # order matters:
      iex> AgentMap.get(mag, {&Enum.reduce/3, [0, &-/2]}, [:alice, :bob])
      1
      iex> AgentMap.get(mag, {&Enum.reduce/3, [0, &-/2]}, [:bob, :alice])
      -1

   "Urgent" calls:

      iex> mag = AgentMap.new(key: 42)
      iex> AgentMap.cast(mag, :key, fn _ ->
      ...>   :timer.sleep(100)
      ...>   43
      ...> end)
      iex> AgentMap.get(mag, :key, & &1, !: true)
      42
      iex> mag[:key] # the same
      42
      iex> AgentMap.get(mag, :key, & &1)
      43
      iex> AgentMap.get(mag, :key, & &1, !: true)
      43
  """
  @spec get(a_map, a_fun([value], a), [key], options) :: a when a: var
  @spec get(a_map, key, a_fun(value, a), options) :: a when a: var

  # 4
  def get(agentmap, key, fun, opts)
  def get(agentmap, fun, keys, opts)

  def get(agentmap, fun, keys, opts) when is_fun(fun, 1) and is_list(keys) do
    call(agentmap, %Req{action: :get, data: {fun, keys}}, opts)
  end

  def get(agentmap, key, fun, opts) when is_fun(fun, 1) do
    call(agentmap, %Req{action: :get, data: {key, fun}}, opts)
  end

  # 3
  def get(agentmap, key, default)

  def get(agentmap, fun, keys) when is_fun(fun, 1) and is_list(keys) do
    call(agentmap, %Req{action: :get, data: {fun, keys}})
  end

  def get(agentmap, key, fun) when is_fun(fun, 1) do
    call(agentmap, %Req{action: :get, data: {key, fun}})
  end

  #

  @spec get(a_map, key, d) :: value | d when d: var
  @spec get(a_map, key) :: value | nil

  def get(agentmap, key, default)

  def get(agentmap, key, default) do
    case fetch(agentmap, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  @doc """
  Gets the value for a specific `key` in `agentmap`.

  If `key` is present in `agentmap` with value `value`, then `value` is
  returned. Otherwise, `fun` is evaluated and its result is returned. This is
  useful if the default value is very expensive to calculate or generally
  difficult to setup and teardown again.

  ## Examples

      iex> mag = AgentMap.new(a: 1)
      iex> fun = fn ->
      ...>   # some expensive operation here
      ...>   13
      ...> end
      iex> AgentMap.get_lazy(mag, :a, fun)
      1
      iex> AgentMap.get_lazy(mag, :b, fun)
      13

  """
  @spec get_lazy(a_map, key, (() -> a)) :: value | a when a: var
  def get_lazy(agentmap, key, fun) do
    case fetch(agentmap, key) do
      {:ok, value} -> value
      :error -> fun.()
    end
  end

  @doc """
  `get/2` call immediately returns value for the given `key`. If there is no
  such `key`, `nil` is returned. It is a clone of `Map.get/3` function, so as
  the third argument, `default` value could be provided:

      iex> mag = AgentMap.new(a: 42)
      iex> AgentMap.get(mag, :a)
      42
      iex> AgentMap.get(mag, :b)
      nil
      iex> AgentMap.get(mag, :b, :error)
      :error

  so it is fully compatible with `Access` behaviour. See `Access.get/3`.
  """
  def get(agentmap, key), do: get(agentmap, key, nil)

  ##
  ## GET_AND_UPDATE
  ##

  @doc """
  Updates the `agentmap` value(s) with given `key`(s) and returns result of some
  calculation. The callback `fun` will be added to the the end of the queue for
  then given `key` (or to the begining, if `!: true` option is given). When
  invocation happens, `agentmap` takes value(s) for the given `key`(s) and
  invokes `fun`, passing values as the first argument and `nil`(s) for the
  values that are lost.

  As in the case of `get`, `update` and `cast` methods, `get_and_update` call
  has two forms:

    * single key: `get_and_update(agentmap, key, fun)`, where `fun` expected
      only one value to be passed;
    * and multiple keys (transactions): `get_and_update(agentmap, fun, [key1,
      key2, …])`, where `fun` expected to take a list of values.

  For example, compare two calls:

      AgentMap.get_and_update(Account, fn [a,b] -> {:swapped, [b,a]} end, [:alice, :bob])
      AgentMap.get_and_update(Account, :alice, & {&1, &1+1000000})

  — the first swapes balances of Alice and Bob balances, returning `:swapped`
  atom, while the second one returns current Alice balance and deposits 1000000
  dollars.

  Single key calls `fun` may return:

    * a two element tuple: `{"get" value, new value}`;
    * a one element tuple `{"get" value}`;
    * `:id` to return current value while not changing it;
    * `:pop`, similar to `Map.get_and_update/3` it returns value with given
      `key` and removes it from `agentmap`.

    * `{:chain, {key, fun}, new_value}` — to not return value, but initiate
      another `get_and_update/4` with given `key` and `fun` pair;
    * `{:chain, {fun, keys}, new_value}` — to not return value, but initiate
      transaction call `get_and_update/4` with given `fun` and `keys` pair.

  While in transaction (group/multiple keys) calls `fun` may return:

    * a two element tuple `{"get" value, [new values]}`;
    * a two element tuple `{"get" value, :drop}` — to remove values with given
      keys;
    * a two element tuple `{"get" value, :id}` — to return "get" value while not
      changin values;

    * a one element tuple `{"get" value}`, that is the same as `{"get" value,
      :id}`;

    * a list with values `[{"get" value} or {"get" value, new value} or :id or
      :pop]`. This returns a list of values as it was made a group of single key
      calls;

    * `:id` to return values while not changing it;
    * `:pop` to return values while with given `keys` while removing them from
      `agentmap`';

    * `{:chain, {key, fun}, new_value}` — to not return value, but initiate
      another `get_and_update/4` with given `key` and `fun` pair;
    * `{:chain, {fun, keys}, new_value}` — to not return value, but initiate
      transaction call `get_and_update/4` with given `fun` and `keys` pair.

  All lists returned by transaction call should have length equal to the number
  of keys given.

  For ex.:

      get_and_update(agentmap, fn [a, b] ->
        if a > 10 do
          a = a-10
          b = b+10
          [{a,a}, {b,b}] # [{get, new_state}]
        else
          {{:error, "Alice does not have 10$ to give to Bob!"}, [a,b]} # {get, [new_state]}
        end
      end, [:alice, :bob])

  or:

      iex> mag = AgentMap.new(alice: 42, bob: 24)
      iex> AgentMap.get_and_update(mag, fn _ -> [:pop, :id] end, [:alice, :bob])
      [42, 24]
      iex> AgentMap.get(mag, & &1, [:alice, :bob])
      [nil, 24]

  (!) State changing transaction (such as `get_and_update`) will block value the
  same way as a single key calls. For ex.:

      iex> AgentMap.new(alice: 42, bob: 24, chris: 0) |>
      ...> AgentMap.get_and_update(&:timer.sleep(1000) && {:slept_well, &1}, [:alice, :bob])
      :slept_well

  will block the possibility to `get_and_update`, `update`, `cast` and even
  non-urgent `get` on `:alice` and `:bob` keys for 1 sec. Nonetheless values are
  always available for "urgent" `get` calls and value under the key `:chris` is
  not blocked.

  Transactions are *Isolated* and *Durabled* (see, ACID model). *Atomicity* can
  be implemented inside callbacks and *Consistency* is out of question here as
  its the application level concept.

  ## Options

  `timeout` is an integer greater than zero which specifies how many
  milliseconds are allowed before the `agentmap` executes the `fun` and returns
  the result value, or the atom `:infinity` to wait indefinitely. If no result
  is received within the specified time, the caller exits. By default it's equal
  to `5000` ms. This value could be given as `:timeout` option, or separately,
  so:

      AgentMap.get_and_update(agentmap, :key, fun)
      AgentMap.get_and_update(agentmap, :key, fun, 5000)
      AgentMap.get_and_update(agentmap, :key, fun, timeout: 5000)
      AgentMap.get_and_update(agentmap, :key, fun, timeout: 5000, !: false)

  means the same.

  The `:!` option is used to make "urgent" calls. Values could have an
  associated queue of callbacks, awaiting of execution. If such queue exists,
  "urgent" version will add call to the begining of the queue (via "selective
  receive").

  Be aware that: (1) anonymous function, `{fun, args}` or MFA tuple can be
  passed as a callback; (2) every value has it's own FIFO queue of callbacks
  waiting to be executed and all the queues are processed concurrently; (3) no
  value changing calls (`get_and_update`, `update` or `cast`) could be executed
  in parallel on the same value. This can be done only for `get` calls (also,
  see `max_threads/3`).

  ## Examples

      iex> import AgentMap
      iex> mag = new(uno: 22)
      iex> get_and_update(mag, :uno, & {&1, &1 + 1})
      22
      iex> get(mag, :uno)
      23
      iex> get_and_update(mag, :uno, fn _ -> :pop end)
      23
      iex> has_key?(mag, :uno)
      false
      iex> get_and_update(mag, :uno, fn _ -> :id end)
      nil
      iex> has_key?(mag, :uno)
      false
      iex> get_and_update(mag, :uno, fn v -> {v,v} end)
      nil
      iex> has_key?(mag, :uno)
      true

  Transactions:

      iex> import AgentMap
      iex> mag = new(uno: 22, dos: 24)
      iex> get_and_update(mag, fn [u, d] ->
      ...>   [{u, d}, {d, u}]
      ...> end, [:uno, :dos])
      [22, 24]
      iex> get(mag, & &1, [:uno, :dos])
      [24, 22]
      #
      iex> get_and_update(mag, fn _ -> :pop end, [:dos])
      [22]
      iex> has_key?(mag, :dos)
      false
      #
      iex> get_and_update(mag, :dos, fn _ -> {:get} end)
      :get
      iex> has_key?(mag, :dos)
      false
      #
      iex> put(mag, :tres, 42)
      iex> put(mag, :cuatro, 44)
      iex> get_and_update(mag, fn _ ->
      ...>   [:id, {nil, :_}, {:_, nil}, :pop]
      ...> end, [:uno, :dos, :tres, :cuatro])
      [24, nil, :_, 44]
      iex> get(mag, & &1, [:uno, :dos, :tres, :cuatro])
      [24, :_, nil, nil]

  Chain calls (used rarely):

      iex> import AgentMap
      iex> mag = new(uno: 24, dos: 33, tres: 42)
      iex> call = {:dos, fn _ -> {:get, :dos} end}
      iex> get_and_update(mag, :uno, fn _ ->
      ...>   {:chain, call, :uno}
      ...> end)
      :get
      iex> get(mag, & &1, [:uno, :dos])
      [:uno, :dos]
      #
      # transaction chain calls:
      #
      iex> call = {fn _ -> {:get, [2,3]} end, [:dos, :tres]}
      iex> get_and_update(mag, :uno, fn _ ->
      ...>   {:chain, call, 1}
      ...> end)
      :get
      iex> get(mag, & &1, [:uno, :dos, :tres])
      [1, 2, 3]
      #
      iex> call = {:uno, fn _ -> {:get, :u} end}
      iex> get_and_update(mag, fn _ ->
      ...>   {:chain, call, [:d, :t]}
      ...> end, [:dos, :tres])
      :get
      iex> get(mag, & &1, [:uno, :dos, :tres])
      [:u, :d, :t]
  """
  # 4
  @type callback(a) ::
          a_fun(
            value,
            {a}
            | {a, value}
            | :pop
            | :id
            | {:chain, {key, callback(a)}, value}
            | {:chain, {callback_t(a), [key]}, value}
          )

  @type callback_t(a) ::
          a_fun(
            [value],
            {a}
            | {a, [value] | :drop | :id}
            | [{any} | {any, value} | :pop | :id]
            | :pop
            | :id
            | {:chain, {key, callback(a)}, value}
            | {:chain, {callback_t(a), [key]}, value}
          )

  @spec get_and_update(a_map, key, callback(a), options) :: a | value
        when a: var
  @spec get_and_update(a_map, callback_t(a), [key], options) :: a | [value]
        when a: var

  def get_and_update(agentmap, key, fun, opts \\ [])

  def get_and_update(agentmap, fun, keys, opts) when is_fun(fun, 1) and is_list(keys) do
    call(agentmap, %Req{action: :get_and_update, data: {fun, keys}}, opts)
  end

  def get_and_update(agentmap, key, fun, opts) when is_fun(fun, 1) do
    call(agentmap, %Req{action: :get_and_update, data: {key, fun}}, opts)
  end

  ##
  ## UPDATE
  ##

  @doc """
  Updates the `agentmap` value(s) with given `key`(s) and return `:ok`. The
  callback `fun` will be added to the the end of the queue for then given `key`
  (or to the begining, if `!: true` option is given). When invocation happens,
  `agentmap` takes value(s) for the given `key`(s) and invokes `fun`, passing
  values as the first argument and `nil`(s) for the values that are lost.

  As in the case of `get`, `get_and_update` and `cast` methods, `get_and_update`
  call has two forms:

    * single key: `update(agentmap, key, fun)`, where `fun` expected only one
      value to be passed;
    * and multiple keys (transactions): `update(agentmap, fun, [key1, key2,
      …])`, where `fun` expected to take a list of values.

  For example, compare two calls:

      AgentMap.update(Account, fn [a,b] -> [b,a] end, [:alice, :bob])
      AgentMap.update(Account, :alice, & &1+1000000)

  — the first swapes balances of Alice and Bob balances, while the second one
  deposits 1000000 dollars to Alices balance.

  Single key calls `fun` must return a new value, while transaction
  (group/multiple keys) call `fun` may return:

    * a list of new values that has a length equal to the number of keys given;
    * `:id` to not change values;
    * `:drop` to delete corresponding values from `agentmap`.

  For ex.:

      iex> mag = AgentMap.new(alice: 42, bob: 24, chris: 33, dunya: 51)
      iex> AgentMap.update(mag, &Enum.reverse/1, [:alice, :bob])
      :ok
      iex> AgentMap.get(mag, & &1, [:alice, :bob])
      [24, 42]
      iex> AgentMap.update(mag, fn _ -> :drop end, [:alice, :bob])
      iex> AgentMap.keys(mag)
      [:chris, :dunya]
      iex> AgentMap.update(mag, fn _ -> :drop end, [:chris])
      iex> AgentMap.update(mag, :dunya, fn _ -> :drop end)
      iex> AgentMap.get(mag, & &1, [:chris, :dunya])
      [nil, :drop]

  (!) State changing transaction (such as `get_and_update`) will block value the
  same way as a single key calls. For ex.:

      iex> AgentMap.new(alice: 42, bob: 24, chris: 0) |>
      ...> AgentMap.update(fn _ ->
      ...>   :timer.sleep(1000)
      ...>   :drop
      ...> end, [:alice, :bob])
      :ok

  will block the possibility to `get_and_update`, `update`, `cast` and even
  non-urgent `get` on `:alice` and `:bob` keys for 1 sec. Nonetheless values are
  always available for "urgent" `get` calls and value under the key `:chris` is
  not blocked.

  Transactions are *Isolated* and *Durabled* (see, ACID model). *Atomicity* can
  be implemented inside callbacks and *Consistency* is out of question here as
  its the application level concept.

  ## Options

  `timeout` is an integer greater than zero which specifies how many
  milliseconds are allowed before the `agentmap` executes the `fun` and returns
  the result value, or the atom `:infinity` to wait indefinitely. If no result
  is received within the specified time, the caller exits. By default it's equal
  to `5000` ms. This value could be given as `:timeout` option, or separately,
  so:[

      AgentMap.get_and_update(agentmap, :key, fun)
      AgentMap.get_and_update(agentmap, :key, fun, 5000)
      AgentMap.get_and_update(agentmap, :key, fun, timeout: 5000)
      AgentMap.get_and_update(agentmap, :key, fun, timeout: 5000, !: false)

  means the same.

  The `:!` option is used to make "urgent" calls. Values could have an
  associated queue of callbacks, awaiting of execution. If such queue exists,
  "urgent" version will add call to the begining of the queue (selective receive
  used).

  Be aware that: (1) this function always returns `:ok`; (2) anonymous function,
  `{fun, args}` or MFA tuple can be passed as a callback; (3) every value has
  it's own FIFO queue of callbacks waiting to be executed and all the queues are
  processed concurrently; (3) no value changing calls (`get_and_update`,
  `update` or `cast`) could be executed in parallel on the same value. This can
  be done only for `get` calls (also, see `max_threads/3`).

  Updates the `agentmap` value(s) with given `key`(s).

  Updates agentmap state with given key. The callback `fun` will be sent to
  the `agentmap`, which will add it to the execution queue for the given key
  state. Before the invocation, the agentmap state will be passed as the first
  argument. If `agentmap` has no state with such key, `nil` will be passed to
  `fun`. The return value of callback becomes the new state of the agentmap.

  ## Examples

      iex> {:ok, pid} = AgentMap.start_link(key: fn -> 42 end)
      iex> AgentMap.update(pid, :key, & &1+1)
      :ok
      iex> AgentMap.get(pid, :key, & &1)
      43
      #
      iex> AgentMap.update(pid, :otherkey, fn nil -> 42 end)
      :ok
      iex> AgentMap.get(pid, :otherkey, & &1)
      42


  Also, for compatibility with `Map` API (and `Map.update/4` fun),
  `update(agentmap, key, initial, fun)` call exists.

      iex> mag = AgentMap.new(a: 42)
      iex> AgentMap.update(mag, :a, :value, & &1+1)
      iex> AgentMap.update(mag, :b, :value, & &1+1)
      iex> AgentMap.take(mag, [:a,:b])
      %{a: 43, b: :value}
  """
  # 4
  @spec update(a_map, key, a_fun(value, value), options) :: :ok
  @spec update(a_map, a_fun([value], [value]), [key], options) :: :ok
  @spec update(a_map, a_fun([value], :drop | :id), [key], options) :: :ok
  def update(agentmap, key, fun, opts \\ [])

  def update(agentmap, fun, keys, opts) when is_fun(fun, 1) and is_list(keys) do
    call(agentmap, %Req{action: :update, data: {fun, keys}}, opts)
  end

  def update(agentmap, key, fun, opts) when is_fun(fun, 1) do
    call(agentmap, %Req{action: :update, data: {key, fun}}, opts)
  end

  def update(agentmap, key, initial, fun) when is_fun(fun, 1) do
    update(agentmap, key, fn
      value ->
        if value do
          Callback.run(fun, [value])
        else
          case Process.get(:'$value') do
            {:value, value} ->
              Callback.run(fun, [value])
            :no ->
              initial
          end
        end
    end)
  end

  ##
  ## CAST
  ##

  @doc """
  Perform `cast` ("fire and forget") `update/3`. Works the same as `update/4`
  but returns `:ok` immediately.
  """
  @spec cast(a_map, key, a_fun(value, value), options) :: :ok
  @spec cast(a_map, a_fun([value], [value]), [key], options) :: :ok
  @spec cast(a_map, a_fun([value], :drop | :id), [key], options) :: :ok
  def cast(agentmap, key, fun, opts \\ [])

  def cast(agentmap, fun, keys, opts) when is_fun(fun, 1) and is_list(keys) do
    call(agentmap, %Req{action: :cast, data: {fun, keys}}, opts)
  end

  def cast(agentmap, key, fun, opts) when is_fun(fun, 1) do
    call(agentmap, %Req{action: :cast, data: {key, fun}}, opts)
  end

  @doc """
  Sets the `:max_threads` value for the given `key`. Returns the old value.

  `agentmap` can execute `get` calls on the same key concurrently. `max_threads`
  option specifies number of threads per key used, minus one thread for the
  process holding the queue. By default five `get` calls on the same state could
  be executed, so

      iex> sleep100ms = fn _ ->
      ...>   :timer.sleep(100)
      ...> end
      iex> mag = AgentMap.new(key: 42)
      iex> for _ <- 1..4, do: spawn(fn ->
      ...>   AgentMap.get(mag, :key, sleep100ms)
      ...> end)
      iex> AgentMap.get(mag, :key, sleep100ms)
      :ok

  will be executed in around of 100 ms, not 500. Be aware, that this call:

      iex> sleep100ms = fn _ ->
      ...>   :timer.sleep(100)
      ...> end
      iex> mag = AgentMap.new(key: 42)
      iex> AgentMap.get(mag, :key, sleep100ms)
      iex> AgentMap.cast(mag, :key, sleep100ms)
      iex> AgentMap.cast(mag, :key, sleep100ms)
      :ok

  will be executed in around of 200 ms because `agentmap` can parallelize any
  sequence of `get/3` calls ending with `get_and_update/3`, `update/3` or
  `cast/3`.

  Use `max_threads: 1` to execute `get` calls in sequence.

  ## Examples

      iex> mag = AgentMap.new()
      iex> AgentMap.max_threads(mag, :a, 42)
      5
      iex> AgentMap.max_threads(mag, :a, :infinity)
      42
  """
  @spec max_threads(agentmap, key, pos_integer | :infinity) :: pos_integer | :infinity
  def max_threads(agentmap, key, value) do
    call(agentmap, %Req{action: :max_threads, data: {key, value}})
  end


  @doc """
  Fetches the value for a specific `key` in the given `agentmap`.

  If `agentmap` contains the given `key` with value value, then `{:ok, value}`
  is returned. If `map` doesn’t contain `key`, `:error` is returned.

  Examples

      iex> mag = AgentMap.new(a: 1)
      iex> AgentMap.fetch(mag, :a)
      {:ok, 1}
      iex> AgentMap.fetch(mag, :b)
      :error
  """
  @spec fetch(agentmap, key) :: {:ok, value} | :error
  def fetch(agentmap, key) do
    call(agentmap, %Req{action: :fetch, data: key})
  end

  @doc """
  Fetches the value for a specific `key` in the given `agentmap`, erroring out
  if `agentmap` doesn't contain `key`. If `agentmap` contains the given `key`,
  the corresponding value is returned. If `agentmap` doesn't contain `key`, a
  `KeyError` exception is raised.

  ## Examples

      iex> mag = AgentMap.new(a: 1)
      iex> AgentMap.fetch!(mag, :a)
      1
      iex> AgentMap.fetch!(mag, :b)
      ** (KeyError) key :b not found
  """
  @spec fetch!(agentmap, key) :: value | no_return
  def fetch!(agentmap, key) do
    case fetch(agentmap, key) do
      {:ok, value} -> value
      :error -> raise KeyError, key: key
    end
  end

  @doc """
  Returns whether the given `key` exists in the given `agentmap`.

  ## Examples

      iex> mag = AgentMap.new(a: 1)
      iex> AgentMap.has_key?(mag, :a)
      true
      iex> AgentMap.has_key?(mag, :b)
      false
  """
  @spec has_key?(agentmap, key) :: boolean
  def has_key?(agentmap, key) do
    match?({:ok, _}, fetch(agentmap, key))
  end

  @doc """
  Returns and removes the value associated with `key` in `agentmap`. If `key` is
  present in `agentmap` with value `value`, `{value, agentmap}` is returned
  where `agentmap` is the same agentmap. State with given `key` is returned from
  `agentmap`. If `key` is not present in `agentmap`, `{default, agentmap}` is
  returned.

  Pair with agentmap is returned for compatibility with Access protocol, as it
  have `Access.pop/2` callback.

  ## Examples

      iex> mag = AgentMap.new(a: 1)
      iex> AgentMap.pop(mag, :a)
      1
      iex> AgentMap.pop(mag, :a)
      nil
      iex> AgentMap.pop(mag, :b)
      nil
      iex> AgentMap.pop(mag, :b, :error)
      :error
      iex> Enum.empty?(mag)
      true
  """
  @spec pop(agentmap, key, any) :: value | any
  def pop(agentmap, key, default \\ nil) do
    call(agentmap, %Req{action: :pop, data: {key, default}})
  end

  @doc """
  Puts the given `value` under `key` in `agentmap`.

  ## Examples

      iex> mag = AgentMap.new(a: 1)
      iex> AgentMap.put(mag, :b, 2) |>
      ...> AgentMap.take([:a, :b])
      %{a: 1, b: 2}
      iex> AgentMap.put(mag, :a, 3) |>
      ...> AgentMap.take([:a, :b])
      %{a: 3, b: 2}
  """
  @spec put(agentmap, key, value) :: agentmap
  def put(agentmap, key, value) do
    GenServer.cast(pid(agentmap), %Req{action: :put, data: {key, value}})
    agentmap
  end

  @doc """
  Returns a `Map` with all the key-value pairs in `agentmap` where the key is in
  `keys`. If `keys` contains keys that are not in `agentmap`, they're simply
  ignored.

  ## Examples

      iex> AgentMap.new(a: 1, b: 2, c: 3) |>
      ...> AgentMap.take([:a, :c, :e])
      %{a: 1, c: 3}
  """
  @spec take(agentmap, Enumerable.t()) :: map
  def take(agentmap, keys) do
    call(agentmap, %Req{action: :take, data: keys})
  end

  @doc """
  Deletes the entry in `agentmap` for a specific `key`. Always returns
  `agentmap` to support piping.

  ## Options

  The `:!` option is used to make "urgent" delete call. Values could have an
  associated queue of callbacks, awaiting of execution. If such queue exists,
  "urgent" version will add call to the begining of the queue (selective receive
  used.

  ## Examples

      iex> mag = AgentMap.new(a: 1, b: 2)
      iex> AgentMap.delete(mag, :a) |>
      ...> AgentMap.take([:a, :b])
      %{b: 2}
      #
      iex> AgentMap.delete(mag, :a) |>
      ...> AgentMap.take([:a, :b])
      %{b: 2}
  """
  @spec delete(agentmap, key, !: boolean) :: agentmap
  def delete(agentmap, key, opts \\ [!: false]) do
    [!: urgent] = opts
    GenServer.cast(pid(agentmap), %Req{action: :delete, data: key, !: urgent})
    agentmap
  end

  @doc """
  Drops the given `keys` from `agentmap`. If `keys` contains keys that are not
  in `agentmap`, they're simply ignored.

  ## Options

  The `:!` option is used to make "urgent" drop call. Values could have an
  associated queue of callbacks, awaiting of execution. If such queue exists,
  "urgent" version will add call to the begining of the queue (selective receive
  used.

  ## Examples

      iex> AgentMap.new(a: 1, b: 2, c: 3) |>
      ...> AgentMap.drop([:b, :d]) |>
      ...> AgentMap.keys()
      [:a, :c]
  """
  @spec drop(agentmap, Enumerable.t(), !: boolean) :: agentmap
  def drop(agentmap, keys, opts \\ [!: false]) do
    [!: urgent] = opts
    GenServer.cast(pid(agentmap), %Req{action: :drop, data: keys, !: urgent})
    agentmap
  end

  @doc """
  Returns all keys from `agentmap`.

  ## Examples

      iex> AgentMap.new(a: 1, b: 2, c: 3) |>
      ...> AgentMap.keys()
      [:a, :b, :c]
  """
  @spec keys(agentmap) :: [key]
  def keys(agentmap) do
    call(agentmap, %Req{action: :keys})
  end

  @doc """
  Returns all values from `agentmap`.

  ## Examples

      iex> AgentMap.new(a: 1, b: 2, c: 3) |>
      ...> AgentMap.values()
      [1, 2, 3]
  """
  @spec values(agentmap) :: [value]
  def values(agentmap) do
    keys = keys(agentmap)
    map = take(agentmap, keys)
    Map.values(map)
  end

  @doc """
  Length of the queue for `key`.

  ## Examples

      iex> mag = AgentMap.new(a: 1, b: 2)
      iex> AgentMap.queue_len(mag, :a)
      0
      iex> AgentMap.cast(mag, :a, fn _ -> :timer.sleep(100) end)
      iex> AgentMap.cast(mag, :a, fn _ -> :timer.sleep(100) end)
      iex> AgentMap.queue_len(mag, :a)
      2
      iex> AgentMap.queue_len(mag, :b)
      0
  """
  @spec queue_len(agentmap, key) :: non_neg_integer
  def queue_len(agentmap, key) do
    call(agentmap, %Req{action: :queue_len, data: key})
  end

  @doc """
  Synchronously stops the `agentmap` with the given `reason`.

  It returns `:ok` if the `agentmap` terminates with the given reason. If the
  agentmap terminates with another reason, the call will exit.

  This function keeps OTP semantics regarding error reporting. If the reason is
  any other than `:normal`, `:shutdown` or `{:shutdown, _}`, an error report
  will be logged.

  ## Examples

      iex> {:ok, pid} = AgentMap.start_link()
      iex> AgentMap.stop(pid)
      :ok
  """
  @spec stop(agentmap, reason :: term, timeout) :: :ok
  def stop(agentmap, reason \\ :normal, timeout \\ :infinity) do
    GenServer.stop(pid(agentmap), reason, timeout)
  end
end
