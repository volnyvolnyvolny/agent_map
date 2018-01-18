defmodule MultiAgent.Server do
  @moduledoc false

  use GenServer

  # Common helpers for init
  defp prepair( funs) do
    keys = Keyword.keys funs
    case keys -- Enum.dedup( keys) do
      []  -> {:ok, funs}
      [k] -> {:error, {k, :already_exists}}
      ks  -> {:error, {ks, :already_exist}}
    end
  end


  defp frun( f) do
    try do
      {:ok, run( f)}
    rescue
      [BadFunctionError, BadArityError] -> {:error, :malformed}
      reason -> {:error, reason}
    end
  end

  # defp frun( funs, true, timeout) do
  #   keys = Keyword.keys( funs)

  #   Keyword.values( funs)
  #   |> Enum.map( & Task.async( fn -> frun(&1) end))
  #   |> Task.yield_many( timeout)
  #   |> Enum.map( fn {task, res} ->
  #        res || Task.shutdown( task, :brutal_kill)
  #      end)
  #   |> Enum.zip( keys)
  #   |> Enum.reduce_while( {:ok, %{}}, fn {res,k}, {:ok, map} ->
  #   |> Enum.map( fn {{:ok}, k} -> [{}]
  #      end)
  # end

  # defp frun( funs, false, _) do
  #   Enum.reduce_while( funs, {:ok, %{}}, fn {k,f}, {:ok, map} ->
  #     case frun( f) do
  #       {:ok, result}        -> {:cont, {:ok, Map.put( map, k, result)}}
  #       {:error, :malformed} -> {:halt, {:error, {k, :cannot_execute}}}
  #       {:error, reason}     -> {:halt, {:error, {k, reason}}}
  #     end
  #   end)
  # end

  # def init( {funs, async, timeout}) do
  #   with {:ok, funs} <- prepair( funs),
  #        {:ok, map} <- frun( funs, async) do

  #     {:ok, {map, %{}}}
  #   else
  #     {:error, err} -> {:stop, err}
  #   end
  # end


  def handle_call({:get, fun}, _from, state) do
    {:reply, run( fun, [state]), state}
  end

  def handle_call({:get_and_update, fun}, _from, state) do
    case run( fun, [state]) do
      {reply, state} -> {:reply, reply, state}
      other -> {:stop, {:bad_return_value, other}, state}
    end
  end

  def handle_call({:update, fun}, _from, state) do
    {:reply, :ok, run( fun, [state])}
  end

  def handle_call( msg, from, state) do
    super( msg, from, state)
  end

  def handle_cast({:cast, fun}, state) do
    {:noreply, run( fun, [state])}
  end

  def handle_cast( msg, state) do
    super( msg, state)
  end

  def code_change(_old, state, fun) do
    {:ok, run( fun, [state])}
  end


  def run( fun, state \\ [])

  def run({m, f, args}, state), do: apply m, f, state++[args]
  def run({f, args}, state), do: apply f, state++[args]
  def run( fun, state), do: apply( fun, state)
end
