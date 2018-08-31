defmodule Overdiscord.Web.CallbackController do
  use Overdiscord.Web, :controller

  import Meeseeks.CSS

  def forum(conn, %{
        "post" => %{
          "username" => username,
          "topic_slug" => topic_slug,
          "topic_id" => 191 = topic_id,
          "topic_title" => topic_title,
          "cooked" => cooked,
          "topic_posts_count" => topic_posts_count
        }
      }) do
    url =
      "https://forum.gregtech.overminddl1.com/t/#{topic_slug}/#{topic_id}/#{topic_posts_count}"

    doc = Meeseeks.parse(cooked |> IO.inspect())

    body =
      doc
      |> Meeseeks.one(css("body"))
      |> Meeseeks.text()

    screenshot =
      case Meeseeks.one(doc, css("img")) do
        nil -> ""
        elem -> "Screenshot: #{Meeseeks.attr(elem, "src")}"
      end

    body =
      case Meeseeks.all(doc, css("p")) do
        [_, cap, change | _] = ps ->
          Enum.map(ps, fn p ->
            img = Meeseeks.one(p, css("img[alt='Screenshot']"))
            code = Meeseeks.one(p, css("code"))
            img = if(img, do: Meeseeks.attr(img, "src"))
            code = if(code, do: Meeseeks.tree(code))

            case {img, code} do
              {nil, nil} -> Meeseeks.text(p)
              {img, nil} -> "Screenshot: #{img} #{Meeseeks.text(p)}"
              # TODO
              {nil, code} -> code
              {img, code} -> "Screenshot: #{img} #{Meeseeks.text(p)}"
            end
          end)
          |> IO.inspect(label: :AllEntries)

        _ ->
          "No body" |> IO.inspect(label: :NoCaptionChangelog)
      end

    # msg = "New Post: #{topic_title}\n#{body}\n#{screenshot}\n#{url}"

    # Overdiscord.EventPipe.inject({:system, "ForumEvent"}, %{msg: msg})

    text(conn, "ok")
  end

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
