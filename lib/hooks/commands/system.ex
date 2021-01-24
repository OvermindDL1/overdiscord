
defmodule Overdiscord.Hooks.Commands.System do
  require Logger

  alias Overdiscord.Storage
  alias Alchemy.Embed

  import Overdiscord.Hooks.CommandParser, only: [log: 1, log: 2]
  import Alchemy.Embed

  @red_embed %Embed{color: 0xD44480}

  def simple_cmd_def(func, description, args \\ 0) do
    %{
      description: description,
      args: args,
      strict: [],
      aliases: [],
      callback: {__MODULE__, func, []},
    }
  end

  def parser_def() do
    %{
      strict: [],
      aliases: [],
      args: 0,
      sub_parsers: %{
        "uptime" => %{
                    description: "Get this bot current uptime",
                    args: 0,
                    strict: [],
                    aliases: [],
                    callback: {__MODULE__, :handle_cmd_uptime, []},
    },
        "stats" => simple_cmd_def(:handle_cmd_stats, "Display this bot system statistics")
      }
    }
  end

  def uptime() do
    {time, _} = :erlang.statistics(:wall_clock)
    min = div(time, 1000 * 60)
    {hours, min} = {div(min, 60), rem(min, 60)}
    {days, hours} = {div(hours, 24), rem(hours, 24)}

    uptime = Stream.zip([min, hours, days], ["m", "h", "d"])
    |> Enum.reduce("", fn
      {0, _glyph}, acc -> acc
      {t, glyph}, acc -> " #{t}" <> glyph <> acc
    end)

    String.trim(uptime)
  end

  def handle_cmd_uptime(_arg) do
    "Uptime: #{uptime()}"
  end

  def handle_cmd_stats(_arg) do
    memories = :erlang.memory()
    processes = Integer.to_string(length(:erlang.processes()))
    {{_, io_input}, {_, io_output}} = :erlang.statistics(:io)
    uptime = uptime()

    mem_format = fn
      mem, :kb -> "#{div(mem, 1000)} KB"
      mem, :mb -> "#{div(mem, 1_000_000)} MB"
    end

    total_memory = mem_format.(memories[:total], :mb)
    io_input = mem_format.(io_input, :mb)
    process_memory = mem_format.(memories[:processes], :mb)
    code_memory = mem_format.(memories[:code], :mb)
    io_output = mem_format.(io_output, :mb)
    ets_memory = mem_format.(memories[:ets], :kb)
    atom_memory = mem_format.(memories[:atom], :kb)

    msg = [
      ["Uptime: ", uptime, "\n"],
      ["Processes: ", processes, "\n"],
      ["Total Memory: ", total_memory, "\n"],
      ["IO Input: ", io_input, "\n"],
      ["Process Memory: ", process_memory, "\n"],
      ["Code Memory: ", code_memory, "\n"],
      ["IO Output: ", io_output, "\n"],
      ["ETS Memory: ", ets_memory, "\n"],
      ["Atom Memory: ", atom_memory, "\n"],
    ]

    msg_discord = [
      {"Uptime", uptime},
      {"Processes", processes},
      {"Total Memory", total_memory},
      {"IO Input", io_input},
      {"Process Memory", process_memory},
      {"Code Memory", code_memory},
      {"IO Output", io_output},
      {"ETS Memory", ets_memory},
      {"Atom Memory", atom_memory},
    ] |> Enum.reduce(@red_embed, fn {name, value}, embed ->
      field(embed, name, value, inline: true)
    end)

    %{msg: to_string(msg), msg_discord: msg_discord, reply?: true}
  end
end
