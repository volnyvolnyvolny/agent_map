defmodule Test.Account do
  use AgentMap

  def start_link() do
    AgentMap.start_link([], name: __MODULE__)
  end

  def stop() do
    AgentMap.stop(__MODULE__)
  end

  @doc """
  Returns `{:ok, balance}` for account or `:error` if account
  is unknown.
  """
  def balance(account) do
    AgentMap.fetch(__MODULE__, account)
  end

  @doc """
  Withdraw. Returns `{:ok, new_amount}` or `:error`.
  """
  def withdraw(account, amount) do
    AgentMap.get_and_update(__MODULE__, account, fn
      # no such account
      nil ->
        # (!) using {:error, nil} will add {key, nil}
        {:error}

      balance when balance > amount ->
        {{:ok, balance - amount}, balance - amount}

      _ ->
        {:error}
    end)
  end

  @doc """
  Deposit. Returns `{:ok, new_amount}`.
  """
  def deposit(account, amount) do
    AgentMap.get_and_update(
      __MODULE__,
      account,
      fn b ->
        new_amount = b + amount
        {{:ok, new_amount}, new_amount}
      end,
      initial: 0
    )
  end

  @doc """
  Trasfer money. Returns `:ok` or `:error`.
  """
  def transfer(from, to, amount) do
    AgentMap.Multi.get_and_update(
      __MODULE__,
      [from, to],
      fn
        [nil, _] ->
          {:error}

        [_, nil] ->
          {:error}

        [b1, b2] when b1 >= amount ->
          {:ok, [b1 - amount, b2 + amount]}

        _ ->
          {:error}
      end
    )
  end

  @doc """
  Close account. Returns `:ok` if account exists or
  `:error` in other case.
  """
  def close(account) do
    if AgentMap.has_key?(__MODULE__, account) do
      AgentMap.delete(__MODULE__, account)
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
    AgentMap.get_and_update(__MODULE__, account, fn
      # set balance to 0, while returning :ok
      nil ->
        {:ok, 0}

      # return :error, do not change balance
      _ ->
        {:error}
    end)
  end
end
