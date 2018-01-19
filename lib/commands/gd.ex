defmodule Overdiscord.Commands.GD do
  use Alchemy.Cogs
  alias Alchemy.{Client, Embed}
  import Meeseeks.CSS

  # @red_embed %Embed{color: 0xd44480}
  @blue_embed %Embed{color: 0x1f95c1}

  Cogs.group("gd")

  Cogs.def class classname do
    Client.trigger_typing(message.channel_id)
    classname = String.downcase(classname) # TODO: Split to detect methods and such
    url = "http://docs.godotengine.org/en/stable/classes/class_#{classname}.html"
    %{body: body, status_code: status_code} = HTTPoison.get!(url)
    if status_code === 200 do
      html = Meeseeks.one(body, css("##{classname}"))
      html_title = Meeseeks.one(html, css("h1"))
      title = Meeseeks.own_text(html_title)
      html_brief = Meeseeks.all(html, css("#brief-description>p"))
      brief = Enum.map(html_brief, &Meeseeks.text/1) |> Enum.join("\n")
      html_desc = Meeseeks.all(html, css("#description>p"))
      desc = Enum.map(html_desc, &Meeseeks.text/1) |> Enum.join("\n")
      msgo = "**#{title}**: #{brief}\n\n#{desc}"
      msg = String.slice(msgo, 0, 900)
      msg = if(byte_size(msg) != byte_size(msgo), do: msg<>"...", else: msg)
      msg = "#{msg}\n\n#{url}"
      Cogs.say(msg)
    else
      Cogs.say("Invalid Classname")
    end
  end

end
