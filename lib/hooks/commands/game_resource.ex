defmodule Overdiscord.Hooks.Commands.GameResource do
  def parser_def() do
    %{
      strict: [
        verbose: :count,
      ],
      aliases: [
        v: :verbose,
      ],
      callback: {__MODULE__, :handle_cmd, []},
      sub_parsers: %{
        "stats" => %{
          strict: [
            all: :boolean,
          ],
        },
      },
    }
  end

  def handle_cmd(cmd_path, args, params, unhandled_params) do
    IO.inspect({cmd_path, args, params, unhandled_params}, label: :handle_cmd)
  end
end
