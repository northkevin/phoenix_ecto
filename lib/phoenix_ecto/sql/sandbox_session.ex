defmodule Phoenix.Ecto.SQL.SandboxSession do
  @moduledoc false
  use GenServer

  @timeout 15_000
  @mode :auto

  def start_link(repo, client, opts) do
    GenServer.start_link(__MODULE__, [repo, client, opts], name: :phx_sandbox_session_owner)
    |> IO.inspect(label: "sandbox_session.ex - start_link - GenServer.start_link(__MODULE__, [repo, client, opts])")
  end

  def init([repo, client, opts]) do
    timeout = opts[:timeout] || @timeout
    sandbox = opts[:sandbox] || Ecto.Adapters.SQL.Sandbox
    mode = opts[:mode] || @mode
    # mode = opts[:mode] || @mode

    opts
    |> IO.inspect(label: "sandbox_session.ex - init - opts")

    case mode do
      :shared ->
        :ok = checkout_connection_shared(sandbox, repo, client)
        |> IO.inspect(label: "mode: shared")
      :auto ->
        :ok = checkout_connection(sandbox, repo, client)
        |> IO.inspect(label: "mode: auto")
      :manual ->
        :ok = checkout_connection(sandbox, repo, client)
        |> IO.inspect(label: "mode: manual")
      end
    # :ok = checkout_connection(sandbox, repo, client)
    Process.send_after(self(), :timeout, timeout)

    {:ok, %{repo: repo, client: client, sandbox: sandbox}}
  end

  def handle_call(:checkin, _from, state) do
    :ok = checkin_connection(state.sandbox, state.repo, state.client)
    {:stop, :shutdown, :ok, state}
  end

  def handle_info(:timeout, state) do
    :ok = checkin_connection(state.sandbox, state.repo, state.client)
    {:stop, :shutdown, state}
  end

  def handle_info({:allowed, repo}, state) do
    send(state.client, {:allowed, repo})
    {:noreply, state}
  end

  defp checkin_connection(sandbox, repo, client) do
    sandbox.checkin(repo, client: client)
  end

  defp checkout_connection(sandbox, repo, client) do
    sandbox.checkout(repo, client: client)
  end

  defp checkout_connection_shared(sandbox, repo, client) do
    sandbox.checkout(repo, client: client)
    |> IO.inspect(label: "sandbox_session.ex - checkout_connection_shared - sandbox.checkout(repo, client: client)")
    sandbox.mode(repo, {:shared, self()})
    |> IO.inspect(label: "sandbox_session.ex - checkout_connection_shared - sandbox.mode(repo, {:shared, self()})")
  end

  # defp checkout_connection_shared(sandbox, repo, client) do
  #   owner_process = Process.whereis(:db_owner_agent)
  #   if owner_process && Process.alive?(owner_process) do
  #   else
  #     {:ok, _pid} = Agent.start_link(&checkout_connection/0, name: :db_owner_agent)
  #   end
  #   # |> IO.inspect(label: "sandbox_session.ex - checkout_connection - sandbox.checkout(repo, client: client)")
  #   # {:shared, client}
  #   # |> IO.inspect(label: "sandbox_session.ex - checkout_connection - {:shared, client}")
  #   # sandbox.mode(repo, {:shared, client})
  #   # |> IO.inspect(label: "sandbox_session.ex - checkout_connection - sandbox.mode(repo, {:shared, client})")
  # end

  # defp set_sandbox_mode(sandbox, repo, mode, client) do
  #   when mode in [:auto, :manual]
  #   when elem(mode, 0) == :shared and is_pid(elem(mode, 1)) do
  #   {_repo_mod, name, opts} = Ecto.Registry.lookup(repo)
  # end
end
