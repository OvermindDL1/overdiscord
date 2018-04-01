defmodule Overdiscord.Hooks.Bridge do
  @moduledoc ~S"""
  """

  def forward(auth, event_data, to, opts \\ []) do
    #    IO.inspect({auth, event_data, to}, label: :FORWARD)

    Enum.map(to, fn
      {module, func, args} -> apply(module, func, [auth, event_data | args])
      _ -> nil
    end)

    nil
  end
end
