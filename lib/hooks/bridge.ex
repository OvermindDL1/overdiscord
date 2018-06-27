defmodule Overdiscord.Hooks.Bridge do
  @moduledoc ~S"""
  """

  @doc ~S"""
  First additional argument (required) is a list of {m,f,a}'s to forward the call to
  """
  def forward(auth, event_data, to, _opts \\ []) do
    #    IO.inspect({auth, event_data, to}, label: :FORWARD)

    Enum.map(to, fn
      {module, func, args} -> apply(module, func, [auth, event_data | args])
      _ -> nil
    end)

    nil
  end
end
