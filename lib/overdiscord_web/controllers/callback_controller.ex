defmodule Overdiscord.Web.CallbackController do
  use Overdiscord.Web, :controller

  import Meeseeks.CSS

  def forum(conn, %{
        "post" => %{
          "username" => username,
          "topic_slug" => topic_slug,
          "topic_id" => topic_id,
          "topic_title" => topic_title,
          "cooked" => cooked,
          "topic_posts_count" => topic_posts_count
        }
      }) do
    url =
      "https://forum.gregtech.overminddl1.com/t/#{topic_slug}/#{topic_id}/#{topic_posts_count}"

    body =
      cooked
      |> Meeseeks.parse()
      |> Meeseeks.one(css("body"))
      |> Meeseeks.text()
      |> String.replace("\n", " ")
      |> String.split_at(120)
      |> elem(0)

    msg = "New Post: #{topic_title}\n#{body}\n#{url}"

    # Overdiscord.EventPipe.inject({:system, "ForumEvent"}, %{msg: msg})

    IO.inspect(msg, label: :ForumEvent_Post)
    text(conn, "ok")
  end

  def forum(conn, params) do
    IO.inspect(params, label: :ForumEvent_Unhandled)
    text(conn, "unhandled")
  end
end
