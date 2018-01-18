defmodule MultiAgent.Server do
  @moduledoc false

  use GenServer

  # async: true
  def init( {funs, true}) do
    Enum.reduce_while( funs, {:ok, {%{}, %{}}}, fn {k,f}, {:ok, {map, %{}}} ->
      try do
        if Map.has_key?( map, k) do
          {:halt, {:error, {k, :already_exists}}}
        else
          {:cont, {:ok, {Map run( f, [])
        end
      rescue
        [BadFunctionError, BadArityError] -> {:halt, {:stop, {k, :cannot_execute}}}
        err -> {:halt, {:stop, err}}
      end

      {:ok, {, %{}}}acc ->
    end)

    IO.inspect( funs)
    _ = initial_call( funs)
    {:ok, {%{}, %{}}}
  end

  # async: false
  def init( {funs, false}) do
    Enum.map( )
    IO.inspect( funs)
    _ = initial_call( funs)
    {:ok, {%{}, %{}}}
  end


  defp initialize( key, ) do
  end

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

  defp initial_call( mfa) do
    _ = Process.put(:"$initial_call", get_initial_call( mfa))
    :ok
  end

  defp get_initial_call( fun) when is_function( fun, 0) do
    {:module, module} = :erlang.fun_info( fun, :module)
    {:name, name} = :erlang.fun_info( fun, :name)
    {module, name, 0}
  end

  defp get_initial_call({mod, fun, args}) do
    {mod, fun, length( args)}
  end


  def run({m, f, args}, state), do: apply m, f, state++[args]
  def run({f, args}, state), do: apply f, state++[args]
  def run( fun, state), do: apply( fun, state)
end
