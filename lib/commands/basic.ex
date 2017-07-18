defmodule Overdiscord.Commands.Basic do
  use Alchemy.Cogs
  alias Alchemy.{Client, Embed}
  import Embed

  @red_embed %Embed{color: 0xd44480}

  # Returns a nicely formatted uptime string
  def uptime do
    {time, _} = :erlang.statistics(:wall_clock)
    min = div(time, 1000 * 60)
    {hours, min} = {div(min, 60), rem(min, 60)}
    {days, hours} = {div(hours, 24), rem(hours, 24)}
    Stream.zip([min, hours, days], ["m", "h", "d"])
    |> Enum.reduce("", fn
      {0, _glyph}, acc -> acc
      {t, glyph}, acc -> " #{t}" <> glyph <> acc
    end)
  end

  def time_diff(time1, time2, unit \\ :milliseconds) do
    from =
      fn
        %NaiveDateTime{} = x -> x
        x -> NaiveDateTime.from_iso8601!(x)
      end
    {time1, time2} = {from.(time1), from.(time2)}
    NaiveDateTime.diff(time1, time2, unit)
  end

  Cogs.def ping do
    old = message.timestamp
    {:ok, message} = Cogs.say("pong!")
    time = time_diff(message.timestamp, old)
    Client.edit_message(message, message.content <> "\ntook #{time} ms")
  end

  Cogs.def stats do
    memories = :erlang.memory()
    processes = length(:erlang.processes())
    {{_, io_input}, {_, io_output}} = :erlang.statistics(:io)
    mem_format = fn
      mem, :kb -> "#{div(mem, 1000)} KB"
      mem, :mb -> "#{div(mem, 1_000_000)} MB"
    end
    info =[
      {"Uptime", uptime()},
      {"Processes", "#{processes}"},
      {"Total Memory", mem_format.(memories[:total], :mb)},
      {"IO Input", mem_format.(io_input, :mb)},
      {"Process Memory", mem_format.(memories[:processes], :mb)},
      {"Code Memory", mem_format.(memories[:code], :mb)},
      {"IO Output", mem_format.(io_output, :mb)},
      {"ETS Memory", mem_format.(memories[:ets], :kb)},
      {"Atom Memory", mem_format.(memories[:atom], :kb)},
    ]
    Enum.reduce(info, @red_embed, fn {name, value}, embed ->
      field(embed, name, value, inline: true)
    end)
    |> Embed.send()
  end
end
