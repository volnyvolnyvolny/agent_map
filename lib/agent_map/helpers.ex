defmodule AgentMap.Helpers do
  @moduledoc false

  def ok?({:ok, _}), do: true
  def ok?(_), do: false

  # Apply extra args to `fun`.
  def apply(fun, extra_args \\ [])

  def apply({m, f, a}, extra_args) do
    Kernel.apply(m, f, extra_args ++ a)
  end

  def apply({fun, args}, extra_args) do
    Kernel.apply(fun, extra_args ++ args)
  end

  def apply(fun, args) do
    Kernel.apply(fun, args)
  end


  def safe_apply(fun, args) do
    __MODULE__.apply(fun, args)
  rescue
    BadFunctionError ->
      {:error, :badfun}

    BadArityError ->
      {:error, :badarity}

    exception ->
      {:error, {exception, :erlang.get_stacktrace()}}

  catch
    :exit, reason ->
      {:error, {:exit, reason}}
  end


  # Run group of funs with a common timeout.
  def run(funs, timeout) when is_list(funs) do
    funs
    |> Enum.map(
      &Task.async(fn ->
        safe_apply(&1, [])
      end)
    )
    |> Task.yield_many(timeout)
    |> Enum.map(fn {task, res} ->
      res || Task.shutdown(task, :brutal_kill)
    end)
    |> Enum.map(fn
      {:ok, _result} = id ->
        id

      nil ->
        {:error, :timeout}

      {:exit, reason} ->
        {:error, reason}
    end)
  end


  defguard is_fun(f, arity)
           when is_function(f, arity)
           or is_function(elem(f, 0), arity + length(elem(f, 1)))
           or (is_atom(elem(f, 0)) and is_atom(elem(f, 1)) and is_list(elem(f, 2)))
end
