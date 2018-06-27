defmodule Overdiscord.Web do
  @moduledoc """
    The entrypoint for defining your web interface, such
      as controllers, views, channels and so on.

    This can be used in your application as:

        use Overdiscord.Web, :controller
        use Overdiscord.Web, :view

    The definitions below will be executed for every view,
      controller, etc, so keep them short and clean, focused
        on imports, uses and aliases.

    Do NOT define functions inside the quoted expressions
      below. Instead, define any helper function in modules
        and import those modules here.
  """

  def controller do
    quote do
      use Phoenix.Controller, namespace: Overdiscord.Web

      import Plug.Conn
      import Overdiscord.Web.Gettext
      alias Overdiscord.Web.Router.Helpers, as: Routes
      alias Overdiscord.Web.Account, as: Account
      import Overdiscord.Web.Account.Plugs
    end
  end

  def commander do
    quote do
      use Phoenix.HTML
      alias Overdiscord.Web.Router.Helpers, as: Routes
      alias Overdiscord.Web.Account, as: Account
    end
  end

  def view do
    quote do
      use Phoenix.View,
        root: "lib/overdiscord_web/templates",
        namespace: Overdiscord.Web

      # Import convenience functions from controllers
      import Phoenix.Controller, only: [get_flash: 1, get_flash: 2, view_module: 1]

      # Use all HTML functionality (forms, tags, etc)
      use Phoenix.HTML

      import Overdiscord.Web.ErrorHelpers
      import Overdiscord.Web.Gettext
      alias Overdiscord.Web.Router.Helpers, as: Routes
      alias Overdiscord.Web.Account, as: Account
    end
  end

  def router do
    quote do
      use Phoenix.Router
      import Plug.Conn
      import Phoenix.Controller
      import Overdiscord.Web.Account.Plugs
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
      import Overdiscord.Web.Gettext
      alias OverDiscord.Web.Account, as: Account
    end
  end

  @doc """
    When used, dispatch to the appropriate controller/view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
