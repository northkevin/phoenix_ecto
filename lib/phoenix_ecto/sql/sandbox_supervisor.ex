defmodule Phoenix.Ecto.SQL.SandboxSupervisor do
  @moduledoc false
  @name DAKING_OF_DA_POOL
  use Supervisor

  def start_link do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    supervise([
      worker(Phoenix.Ecto.SQL.SandboxSession, [], [name: @name, restart: :temporary])
    ], strategy: :simple_one_for_one)
  end
end
