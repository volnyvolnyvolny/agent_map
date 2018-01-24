defmodule MultiAgent.Analytic do
  @moduledoc false

  def loop( statistics) do
    # receive do
    #   {:task_done, key, process}
    #   {:new_task, process, }
    # end
    :timer.sleep(:infinity)
  end

  def empty_interval( analytic, process) do
    0
  end
end
