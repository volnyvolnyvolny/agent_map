defmodule AgentMap.Common do
  @moduledoc false

  import System, only: [system_time: 0, convert_time_unit: 3]

  require Logger

  def unbox_(nil), do: 5000
  def unbox_({_, timeout}), do: timeout
  def unbox_(timeout), do: timeout

  def dict(worker \\ self()) do
    Process.info(worker)[:dictionary]
  end

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

  def to_ms(time) do
    convert_time_unit(time, :milliseconds, :native)
  end

  defp expired?(%{timeout: {_, timeout}, inserted_at: t}) do
    system_time() >= t + to_ms(timeout)
  end

  defp expired?(_), do: false

  def run(%{fun: f, timeout: {:hard, timeout}} = req, args) do
    if expired?(req) do
      {:error, :expired}
    else
      dict = dict()

      task = Task.async(fn ->
        for {key, value} <- dict do
          Process.put(key, value)
        end

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
      {:ok, __MODULE__.apply(req.fun, args)}
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
