defmodule Phoenix.Ecto.SQL.SandboxSupervisor do
  @moduledoc false
  @name DAKING_OF_POOL
  use Supervisor

  def start_link do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    supervise([
      worker(Phoenix.Ecto.SQL.SandboxSession, [], [name: @name, restart: :temporary])
    ], strategy: :simple_one_for_one)
  end

  # def init(_) do
  #   case length(Supervisor.which_children(Phoenix.Ecto.SQL.SandboxSupervisor)) do
  #     0 ->
  #       supervise([
  #         worker(Phoenix.Ecto.SQL.SandboxSession, [], [name: @name, restart: :temporary])
  #       ], strategy: :simple_one_for_one)
  #     _ ->
  #       IO.puts("Session has already been checked out, please stop it before checking a new one.")
  #   end
  # end


end
