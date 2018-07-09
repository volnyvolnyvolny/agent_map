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
    __MODULE__.apply(fun, args)

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

    t + timeout > system_time()
  end

  defp expired?(_), do: false

  defp _run(%{data: {_, f}} = req, args) do
    _run(%{req | fun: f}, args)
  end

  defp _run(%{fun: f} = req, args) do
    if req.safe? do
      safe_apply(f, args)
    else
      {:ok, __MODULE__.apply(f, args)}
    end
  end

  def run(%{timeout: {:hard, timeout}} = req, args) do
    if expired?(req) do
      task = Task.async(fn ->
        _run(req, args)
      end)

      case Task.yield(task, timeout) || Task.shutdown(task) do
        {:ok, _result} = res ->
          res

        nil ->
          {:error, :expired}
      end
    else
      {:error, :expired}
    end
  end

  def run(req, args) do
    if expired?(req) do
      _run(req, args)
    else
      {:error, :expired}
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

  def run_and_reply(req, value) do
    with {:ok, result} <- run(req, [value]) do
      reply(req.from, result)
    else
      {:error, :expired} ->
        k = Process.get(:"$key")
        Logger.error("Key #{inspect(k)} error while processing #{inspect(req)}. Request is expired.")

      {:error, reason} ->
        {pid, _} = req.from
        Process.exit(pid, reason)
    end
  end

  defguard is_fun(f, arity)
           when is_function(f, arity)
           or is_function(elem(f, 0), arity + length(elem(f, 1)))
           or (is_atom(elem(f, 0)) and is_atom(elem(f, 1)) and is_list(elem(f, 2)))
end
