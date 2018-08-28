defmodule AgentMap.Common do
  @moduledoc false

  import System, only: [system_time: 0, convert_time_unit: 3]

  require Logger

  ##
  ## BOXING
  ##

  def unbox(nil), do: nil
  def unbox({:value, v}), do: v

  ##
  ## STATE RELATED
  ##

  defp compress(pack, max_p)

  defp compress({box, {0, max_p}}, max_p), do: box
  defp compress({box, {p, max_p}}, max_p), do: {box, p}
  defp compress(pack, _), do: pack

  def inject(key, pack, state) do
    {map, max_p} = state

    map =
      case compress(pack, max_p) do
        nil ->
          Map.delete(map, key)

        pack ->
          %{map | key => pack}
      end

    {map, max_p}
  end

  def extract(key, state) do
    {map, max_p} = state

    case map[key] do
      {:pid, _} = pack ->
        pack

      {_, {_, _}} = pack ->
        pack

      {box, p} ->
        {box, {p, max_p}}

      box ->
        {box, {0, max_p}}
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

  def run(%{fun: f, timeout: {:break, timeout}} = req, arg) do
    if expired?(req) do
      {:error, :expired}
    else
      k = Process.get(:"$key")
      b = Process.get(:"$value")

      task =
        Task.async(fn ->
          Process.put(:"$key", k)
          Process.put(:"$value", b)

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

  def run(%{data: {f, _}} = req, arg) when is_function(f, 1) do
    run(%{req | fun: f}, arg)
  end

  def run(%{data: {_, f}} = req, arg) do
    run(%{req | fun: f}, arg)
  end

  def reply(nil, _msg), do: :ignore
  def reply(from, msg), do: GenServer.reply(from, msg)

  def run_and_reply(req, value) do
    case run(req, unbox(value)) do
      {:ok, result} ->
        reply(req.from, result)

      {:error, :expired} ->
        handle_timeout_error(req)
    end
  end

  ##
  ##
  ##

  def handle_timeout_error(req) do
    r = inspect(req)
    k = Process.get(:"$key")
    Logger.error("Key #{k} timeout error while processing request #{r}.")
  end

  def handle_timeout_error(req, keys) do
    r = inspect(req)
    Logger.error("Keys #{keys} timeout error while processing transaction request #{r}.")
  end

  ##
  ## GET-REQUEST
  ##

  def spawn_get({key, box}, req, server \\ nil) do
    Task.start_link(fn ->
      Process.put(:"$key", key)
      Process.put(:"$value", box)

      run_and_reply(req, box)

      server && send(server, %{info: :done})
    end)
  end
end
