defmodule Overdiscord.Hooks.Commands.System do
  require Logger

  # alias Overdiscord.Storage
  alias Alchemy.Embed

  # import Overdiscord.Hooks.CommandParser, only: [log: 1, log: 2]
  import Alchemy.Embed

  @red_embed %Embed{color: 0xD44480}

  def simple_cmd_def(func, description, args \\ 0) do
    %{
      help: %{nil => description},
      args: args,
      strict: [],
      aliases: [],
      callback: {__MODULE__, func, []}
    }
  end

  def parser_def() do
    %{
      strict: [],
      aliases: [],
      args: 0,
      help: %{nil => "Commands related to the bot system itself"},
      sub_parsers: %{
        "uptime" => simple_cmd_def(:handle_cmd_uptime, "See this bot current uptime"),
        "stats" => simple_cmd_def(:handle_cmd_stats, "Display this bot system statistics"),
        "restart" => simple_cmd_def(:handle_cmd_restart, "Restart the bot VM"),
        "reboot" => simple_cmd_def(:handle_cmd_reboot, "Reboot the bot system"),
        "shutdown" =>
          simple_cmd_def(
            :handle_cmd_shutdown,
            "Shutdown the bot, should be restarted automatically 'soon', refreshes environment"
          )
      }
    }
  end

  def handle_cmd_restart(%{auth: auth} = arg) do
    if auth.permissions.({:cmd, arg}) do
      spawn(fn ->
        Process.sleep(1000)
        :init.restart()
      end)

      "Restarting this bot in 1 second..."
    else
      "You do not have access to restart this bot"
    end
  end

  def handle_cmd_reboot(%{auth: auth} = arg) do
    if auth.permissions.({:cmd, arg}) do
      spawn(fn ->
        Process.sleep(1000)
        :init.reboot()
      end)

      "Rebooting this bot in 1 second..."
    else
      "You do not have access to reboot this bot"
    end
  end

  def handle_cmd_shutdown(%{auth: auth} = arg) do
    if auth.permissions.({:cmd, arg}) do
      spawn(fn ->
        Process.sleep(1000)
        :init.stop()
      end)

      "Shutting down this bot in 1 second..."
    else
      "You do not have access to shut down this bot"
    end
  end

  def uptime() do
    {time, _} = :erlang.statistics(:wall_clock)
    min = div(time, 1000 * 60)
    {hours, min} = {div(min, 60), rem(min, 60)}
    {days, hours} = {div(hours, 24), rem(hours, 24)}

    uptime =
      Stream.zip([min, hours, days], ["m", "h", "d"])
      |> Enum.reduce("", fn
        {0, _glyph}, acc -> acc
        {t, glyph}, acc -> " #{t}" <> glyph <> acc
      end)

    case String.trim(uptime) do
      "" -> "<1m"
      uptime -> uptime
    end
  end

  def handle_cmd_uptime(_arg) do
    "Uptime: #{uptime()}"
  end

  def handle_cmd_stats(_arg) do
    memories = :erlang.memory()
    processes = Integer.to_string(length(:erlang.processes()))
    {{_, io_input}, {_, io_output}} = :erlang.statistics(:io)
    uptime = uptime()

    disk_space =
      :disksup.get_disk_data()
      |> Enum.map(fn {id, kbyte, capperc} ->
        {List.to_string(id), kbyte, capperc}
      end)
      |> Enum.filter(fn {id, _kbyte, _capperc} ->
        not String.contains?(id, ["/snap/", "/docker/", "/dev", "/run", "/sys", "/boot"])
      end)
      |> Enum.map(fn {id, kbyte, capperc} ->
        capperc = 100 - capperc
        total = :erlang.float_to_binary(kbyte / 1_000_000, decimals: 3)
        # capperc is 0 to 100 as a percentage, it's not a float
        free = :erlang.float_to_binary(kbyte * capperc / (100 * 1_000_000), decimals: 3)
        "* `#{id}` #{free} GB free / #{total} GB total (#{capperc}% free)\n"
      end)

    mem_format = fn
      mem, :kb -> "#{div(mem, 1000)} KB"
      mem, :mb -> "#{div(mem, 1_000_000)} MB"
    end

    total_used_memory = mem_format.(memories[:total], :mb)
    io_input = mem_format.(io_input, :mb)
    process_memory = mem_format.(memories[:processes], :mb)
    code_memory = mem_format.(memories[:code], :mb)
    io_output = mem_format.(io_output, :mb)
    ets_memory = mem_format.(memories[:ets], :kb)
    atom_memory = mem_format.(memories[:atom], :kb)

    msg = [
      ["Uptime: ", uptime, "\n"],
      ["Processes: ", processes, "\n"],
      ["Total Used Memory: ", total_used_memory, "\n"],
      ["IO Input: ", io_input, "\n"],
      ["Process Memory: ", process_memory, "\n"],
      ["Code Memory: ", code_memory, "\n"],
      ["IO Output: ", io_output, "\n"],
      ["ETS Memory: ", ets_memory, "\n"],
      ["Atom Memory: ", atom_memory, "\n"],
      ["Disk Space:\n", disk_space]
    ]

    msg_discord =
      [
        {"Uptime", uptime},
        {"Processes", processes},
        {"Total Memory", total_used_memory},
        {"IO Input", io_input},
        {"Process Memory", process_memory},
        {"Code Memory", code_memory},
        {"IO Output", io_output},
        {"ETS Memory", ets_memory},
        {"Atom Memory", atom_memory},
        {"Disk Space", disk_space}
      ]
      |> Enum.reduce(@red_embed, fn {name, value}, embed ->
        field(embed, name, value, inline: true)
      end)

    %{msg: to_string(msg) |> String.trim(), msg_discord: msg_discord, reply?: true}
  end
end
