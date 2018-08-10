defmodule AgentMap.Common do
  @moduledoc false

  import System, only: [system_time: 0, convert_time_unit: 3]

  require Logger

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
    {:ok, __MODULE__.apply(fun, args)}

  rescue
    BadFunctionError ->
      {:error, :badfun}

    BadArityError ->
      {:error, :badarity}

    exception ->
      {:error, exception}

  catch
    :exit, reason ->
      {:error, {:exit, reason}}
  end

  def reply({_pid, _tag} = to, what) do
    GenServer.reply(to, what)
  end

  def reply(nil, _), do: :nothing

  def reply(to, what) do
    send(to, what)
  end

  defp expired?(%{timeout: {_, timeout}, inserted_at: t}) do
    timeout =
      convert_time_unit(timeout, :milliseconds, :native)

    system_time() >= t + timeout
  end

  defp expired?(_), do: false

  # if req.safe? do
  #   safe_apply(f, args)
  # else
  #   {:ok, __MODULE__.apply(f, args)}
  # end

  def run(%{fun: f, timeout: {:hard, timeout}} = req, args) do
    if expired?(req) do
      {:error, :expired}
    else
      task = Task.async(fn ->
        __MODULE__.apply(f, args)
      end)

      case Task.yield(task, timeout) || Task.shutdown(task) do
        {:ok, _result} = res ->
          res

        nil ->
          {:error, :expired}
      end
    end
  end

  def run(req, args) do
    if expired?(req) do
      {:error, :expired}
    else
      {:ok, __MODULE__.apply(f, args)}
    end
  end

  # Run group of funs with a common timeout.
  def run_group(funs, timeout) when is_list(funs) do
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
