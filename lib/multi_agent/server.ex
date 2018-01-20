defmodule MultiAgent.Server do
  @moduledoc false

  alias MultiAgent.Helpers

  use GenServer

  # Common helpers for init
  defp prepair( funs) do
    keys = Keyword.keys funs
    case keys -- Enum.dedup( keys) do
      []  -> {:ok, funs}
      ks  -> {:error, Enum.map( ks, & {&1, :already_exists})}
    end
  end


  def init( {funs, async, timeout}) do
    with {:ok, funs} <- prepair( funs),
         {:ok, map} <- Helpers.safe_run( funs, async, timeout-10) do

      {:ok, {map, %{}}}
    else
      {:error, err} -> {:stop, err}
    end
  end


  def handle_call({:get, fun}, _from, state) do
    {:reply, Helpers.run( fun, [state]), state}
  end

  def handle_call({:get_and_update, fun}, _from, state) do
    case Helpers.run( fun, [state]) do
      {reply, state} -> {:reply, reply, state}
      other -> {:stop, {:bad_return_value, other}, state}
    end
  end

  def handle_call({:update, fun}, _from, state) do
    {:reply, :ok, Helpers.run( fun, [state])}
  end

  def handle_call( msg, from, state) do
    super( msg, from, state)
  end

  def handle_cast({:cast, fun}, state) do
    {:noreply, Helpers.run( fun, [state])}
  end

  def handle_cast( msg, state) do
    super( msg, state)
  end

  def code_change(_old, state, fun) do
    {:ok, Helpers.run( fun, [state])}
  end

end
