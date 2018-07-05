defmodule Overdiscord.Web.Account do
  import Plug.Conn
  import Phoenix.Controller
  #import Overdiscord.Web.Gettext

  @session_tag :authentication
  def session_tag(), do: @session_tag

  def authenticate(env, name) do
    # Console Auth!  This is unique.  ^.^
    spid = inspect(self())
    spid = binary_part(spid, 5, byte_size(spid) - 6)

    IO.puts(
      "\n\nCONSOLE AUTH: #{name}\n\tOverdiscord.Web.Account.console_authorize(pid(\"#{spid}\"))\n\n"
    )

    receive do
      :authenticate ->
        case env do
          %Plug.Conn{} = conn ->
            conn
            |> put_session(session_tag(), {:console, %{name: name}})

          _ ->
            env
        end
    after
      30000 ->
        env
    end
  end

  def console_authorize(pid) do
    send(pid, :authenticate)
  end

  def unauthenticate(%Plug.Conn{} = conn) do
    unauthenticate(get_authentication(conn))
    delete_session(conn, session_tag())
  end

  def unauthenticate({:console, %{name: name}} = env) do
    IO.puts("Logging out `#{name}` from the Web")
    broadcast_unauthenticate(env)
    env
  end

  defp broadcast_unauthenticate(env) do
    {:ok, name} = get_name(env)
    Overdiscord.Web.Endpoint.broadcast("user_socket:" <> name, "disconnect", %{})
    env
  end

  def get_authentication(nil), do: nil

  def get_authentication(%Plug.Conn{} = conn),
    do: get_authentication(Plug.Conn.get_session(conn, session_tag()))

  def get_authentication(%{assigns: %{__session: s}}), do: get_authentication(s[session_tag()])
  def get_authentication(%{assigns: %{@session_tag => auth}}), do: get_authentication(auth)
  def get_authentication({:console, %{}} = env), do: env

  def to_event_auth({:console, args}) do
    event_auth = {:web, args}
    {:ok, event_auth}
  end

  def to_event_auth(env), do: to_event_auth(get_authentication(env))

  def authenticated?({:console, %{name: _name}}) do
    true
  end

  def authenticated?(nil) do
    false
  end

  def authenticated?(env), do: authenticated?(get_authentication(env))

  def can?({:console, args}, _perms) do
    case args[:perms] do
      # TODO:  Add permissions...
      nil ->
        true
    end
  end

  def can?(env, perms), do: can?(get_authentication(env), perms)

  def get_name({:console, %{name: name}}) do
    {:ok, name}
  end

  def get_name(nil) do
    {:error, :unknown_environment}
  end

  def get_name(env), do: get_name(get_authentication(env))

  # Plugs

  defmodule Plugs do
    import Plug.Conn
    import Phoenix.Controller
    alias Overdiscord.Web.Account

    def plug_authenticated(conn, opts) do
      if Account.authenticated?(conn) do
        _roles = List.wrap(opts[:role])
        conn
      else
        conn
        |> put_status(:not_found)
        |> put_layout(false)
        |> put_view(Overdiscord.Web.ErrorView)
        |> render("404.html")
        |> halt()
      end
    end
  end
end
