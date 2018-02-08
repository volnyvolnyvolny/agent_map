defmodule MultiAgent.Callback do
  @moduledoc false

  @compile {:inline, parse: 1}

  def parse({:state, state}), do: state
  def parse( nil), do: nil


  def safe_run( f) do
    try do
      {:ok, run( f)}
    rescue
      [BadFunctionError, BadArityError] -> {:error, :cannot_call}
      exception -> {:error, {exception, :erlang.get_stacktrace()}}
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end
  end


  defguard is_fun( f, n) when is_function(f, n) or
                              is_function( elem(f, 0)) and is_list( elem(f, 1)) or
                              is_atom( elem(f, 0)) and is_atom( elem(f, 1)) and is_list( elem(f, 2))
  # is function given in form of anonymous fun, {fun,args} or
  # {Module, fun, args}? The second argument is the arity of result
  # function after arguments apply.
  def valid?( fun, arity \\ 0)
  def valid?({module, fun, args}, arity) when is_atom( module) do
    valid? {fun, args}, arity
  end
  def valid?({fun, args}, arity) when is_list( args) do
    valid? fun, length( args)+arity
  end
  def valid?( fun, arity), do: is_function fun, arity


  # Run `fun_arg`.
  def run( fun, state \\ [])

  def run( {m, f, args}, state), do: apply m, f, state++[args]
  def run( {f, args}, state), do: apply f, state++[args]
  def run( fun, state), do: apply( fun, state)


  defp decorate( key, {:ok, result}, {:ok, map}), do: {:ok, Map.put( map, key, result)}
  defp decorate( key, {:error, reason}, {:ok, _}), do: {:error, [{key, reason}]}
  defp decorate( key, {:error, reason}, {:error, errs}), do: {:error, errs++[{key, reason}]}
  defp decorate( _, {:ok, _}, errors), do: errors


  # run group of funs. Params are funs_with_ids and timeout
  def safe_run( funs, timeout) do
    Keyword.values( funs)
    |> Enum.map( &Task.async( fn -> safe_run(&1) end))
    |> Task.yield_many( timeout)
    |> Enum.map( fn {task, res} ->
         res || Task.shutdown( task, :brutal_kill)
       end)
    |> Enum.map( fn
         {:ok, result} -> result;
         nil -> {:error, :timeout};
         exit -> {:error, exit}
       end)
    |> Enum.zip( Keyword.keys( funs))
    |> Enum.reduce( {:ok, %{}}, fn {r, k}, acc ->
         decorate( k, r, acc)
       end)
  end
end
