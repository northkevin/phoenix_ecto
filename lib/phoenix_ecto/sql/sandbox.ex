defmodule Phoenix.Ecto.SQL.Sandbox do
  @moduledoc """
  A plug to allow concurrent, transactional acceptance tests with Ecto.Adapters.SQL.Sandbox.

  ## Example

  This plug should only be used during tests. First, set a flag to
  enable it in `config/test.exs`:

      config :your_app, sql_sandbox: true

  And use the flag to conditionally add the plug to `lib/your_app/endpoint.ex`:

      if Application.get_env(:your_app, :sql_sandbox) do
        plug Phoenix.Ecto.SQL.Sandbox
      end

  It's important that this is at the top of `endpoint.ex`, before any other plugs.

  Then, within an acceptance test, checkout a sandboxed connection as before.
  Use `metadata_for/2` helper to get the session metadata to that will allow access
  to the test's connection.
  Here's an example using [Hound](https://hex.pm/packages/hound):

      use Hound.Helpers

      setup do
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(YourApp.Repo)
        metadata = Phoenix.Ecto.SQL.Sandbox.metadata_for(YourApp.Repo, self())
        Hound.start_session(metadata: metadata)
      end

  ## Concurrent end-to-end tests with external clients

  Concurrent and transactional tests for external HTTP clients is supported,
  allowing for complete end-to-end tests. This is useful for cases such as
  JavaScript test suites for single page applications that exercise the
  Phoenix endpoint for end-to-end test setup and teardown. To enable this,
  you can expose a sandbox route on the `Phoenix.Ecto.SQL.Sandbox` plug by
  providing the `:at`, and `:repo` options. For example:

      plug Phoenix.Ecto.SQL.Sandbox,
        at: "/sandbox",
        repo: MyApp.Repo,
        timeout: 15_000 # the default

  This would expose a route at `"/sandbox"` for the given repo where
  external clients send POST requests to spawn a new sandbox session,
  and DELETE requests to stop an active sandbox session. By default,
  the external client is expected to pass up the `"user-agent"` header
  containing serialized sandbox metadata returned from the POST request,
  but this value may customized with the `:header` option.
  """

  import Plug.Conn
  alias Plug.Conn
  alias Phoenix.Ecto.SQL.SandboxSupervisor

  @doc """
  Spawns a sandbox session to checkout a connection for a remote client.

  ## Examples

      iex> {:ok, _owner_pid, metdata} = start_child(MyApp.Repo)
  """
  def start_child(repo, opts \\ []) do
    case Supervisor.start_child(SandboxSupervisor, [repo, self(), opts]) do
      {:ok, owner} ->
        metadata = metadata_for(repo, owner)
        {:ok, owner, metadata}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stops a sandbox session holding a connection for a remote client.

  ## Examples

      iex> {:ok, owner_pid, metadata} = start_child(MyApp.Repo)
      iex> :ok = stop(owner_pid)
  """
  def stop(owner) when is_pid(owner) do
    GenServer.call(owner, :checkin)
  end

  def init(opts \\ []) do
    session_opts = Keyword.take(opts, [:sandbox, :timeout])

    %{
      header: Keyword.get(opts, :header, "user-agent"),
      path: get_path_info(opts[:at]),
      repo: opts[:repo],
      sandbox: session_opts[:sandbox] || Ecto.Adapters.SQL.Sandbox,
      session_opts: session_opts
    }
  end

  defp get_path_info(nil), do: nil
  defp get_path_info(path), do: Plug.Router.Utils.split(path)

  def call(%Conn{method: "POST", path_info: path} = conn, %{path: path} = opts) do
    %{repo: repo, session_opts: session_opts} = opts

    Supervisor.which_children(Phoenix.Ecto.SQL.SandboxSupervisor)
    |> IO.inspect(label: "I'm curious what children exist for SandboxSupervisor in the POST method: ")

    case length(active_sandbox_sessions()) do
      0 ->
        {:ok, _owner, metadata} = start_child(repo, session_opts)

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, encode_metadata(metadata))
        |> halt()
      _ ->
        msg = "Session has already been checked out, please stop it before checking a new one."
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, msg)
        |> halt()
    end
  end
  def call(%Conn{method: "DELETE", path_info: path} = conn, %{path: path} = opts) do
    case active_sandbox_sessions() do
      [{_id, child, _type, _modules}] ->
        child
        |> IO.inspect(label: "call - DELETE - search_for_sandbox_session - found owner")
      {} ->
        IO.puts("call - DELETE - search_for_sandbox_session - no owner found.")
    end
    case extract_metadata(conn, opts.header) do
      %{owner: owner} ->
        :ok = stop(owner)

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, "")
        |> halt()

      %{} ->
        conn
        |> send_resp(410, "")
        |> halt()
    end
  end

  def call(conn, %{header: header, sandbox: sandbox}) do
    _result =
      conn
      |> extract_metadata(header)
      |> IO.inspect(label: "extract_metadata for #{conn.method} #{conn.request_path}")
      |> allow_sandbox_access(sandbox)
      |> IO.inspect(label: "allow conn for #{conn.method} #{conn.request_path}")

    conn
  end

  defp active_sandbox_sessions() do
    Supervisor.which_children(Phoenix.Ecto.SQL.SandboxSupervisor)
  end

  defp extract_metadata(%Conn{} = conn, header) do
    conn
    |> get_req_header(header)
    |> List.first()
    |> decode_metadata()
  end

  @doc """
  Returns metadata to associate with the session
  to allow the endpoint to access the database connection checked
  out by the test process.
  """
  @spec metadata_for(Ecto.Repo.t | [Ecto.Repo.t], pid) :: map
  def metadata_for(repo_or_repos, pid) when is_pid(pid) do
    %{repo: repo_or_repos, owner: pid}
  end

  @doc """
  Encodes metadata generated by `metadata_for/2` for client response.
  """
  def encode_metadata(metadata) do
    encoded =
      {:v1, metadata}
      |> :erlang.term_to_binary()
      |> Base.url_encode64()

    "BeamMetadata (#{encoded})"
  end

  @doc """
  Decodes encoded metadata back into map generated from `metadata_for/2`.
  """
  def decode_metadata(encoded_meta) when is_binary(encoded_meta) do
    last_part = encoded_meta |> String.split("/") |> List.last()
    case Regex.run(~r/BeamMetadata \((.*?)\)/, last_part) do
      [_, metadata] -> parse_metadata(metadata)
      _             -> %{}
    end
  end
  def decode_metadata(_), do: %{}

  defp allow_sandbox_access(%{repo: repo, owner: owner}, sandbox) do
    Enum.each(List.wrap(repo), &sandbox.allow(&1, owner, self()))
  end
  defp allow_sandbox_access(_metadata, _sandbox), do: nil

  defp parse_metadata(encoded_metadata) do
    encoded_metadata
    |> Base.url_decode64!()
    |> :erlang.binary_to_term()
    |> case do
         {:v1, metadata} -> metadata
         _               -> %{}
       end
  end
end
