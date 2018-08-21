defmodule AgentMap.Common do
  @moduledoc false

  import System, only: [system_time: 0, convert_time_unit: 3]

  require Logger

  ##
  ## BOXING
  ##

  def unbox(nil), do: nil
  def unbox({:value, value}), do: value

  ##
  ## STATE RELATED
  ##

  defp box(value, p, custom_max_p, max_p)

  defp box(value, 0, max_p, max_p), do: value
  defp box(value, p, max_p, max_p), do: {value, p}
  defp box(value, p, max_p, _), do: {value, {p, max_p}}

  defp pack(key, value, {p, custom_max_p}, {map, max_p}) do
    case box(value, p, custom_max_p, max_p) do
      nil ->
        {Map.delete(map, key), max_p}

      box ->
        {%{map | key => box}, max_p}
    end
  end

  def unpack(key, {map, max_p}) do
    case map[key] do
      {:pid, worker} ->
        {:pid, worker}

      {_value, {_p, _custom_max_p}} = box ->
        box

      {value, p} ->
        {value, {p, max_p}}

      value ->
        {value, {0, max_p}}
    end
  end

  ##
  ## TIME RELATED
  ##

  def to_ms(time) do
    convert_time_unit(time, :milliseconds, :native)
  end

  defp expired?(%{timeout: {_, timeout}, inserted_at: t}) do
    system_time() >= t + to_ms(timeout)
  end

  defp expired?(_), do: false

  ##
  ## APPLY AND RUN
  ##

  def safe_apply(fun, args) do
    {:ok, apply(fun, args)}
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

  def run(%{fun: f, timeout: {:break, timeout}} = req, arg) do
    if expired?(req) do
      {:error, :expired}
    else
      dict = dict()

      task = Task.async(fn ->
        # clone process dictionary:
        for {prop, value} <- dict do
          Process.put(prop, value)
        end

        f.(arg)
      end)

      case Task.yield(task, timeout) || Task.shutdown(task) do
        {:ok, _result} = res ->
          res

        nil ->
          {:error, :expired}
      end
    end
  end

  def run(%{fun: f} = req, arg) do
    if expired?(req) do
      {:error, :expired}
    else
      {:ok, f.(arg)}
    end
  end

  def reply(nil, msg), do: :ignore
  def reply(from, msg), do: GenServer.reply(from, msg)

  def run_and_reply(req, value) do
    case run(req, unbox(value)) do
      {:ok, result} ->
        reply(req.from, result)

      {:error, :expired} ->
        handle_timeout_error(req)
    end
  end

  def spawn_get(key, box, req, server \\ nil) do
    Task.start_link(fn ->
      Process.put(:"$key", key)
      Process.put(:"$value", box)

      run_and_reply(to_msg(req), box)

      server && send(server, %{info: :done})
    end)
  end

  ##
  ##
  ##

  def handle_timeout_error(req) do
    r = inspect(req)
    if get(:"$key") do
      k = inspect(get(:"$key"))
      Logger.error("Key #{k} timeout error while processing request #{r}.")
    else
      ks = inspect(get(:"$keys")
      Logger.error("Keys #{ks} timeout error while processing transaction request #{r}.")
    end
  end
end
