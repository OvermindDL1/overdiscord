defmodule Overdiscord.Web.GithubWebhookController do
  use Overdiscord.Web, :controller

  def handle(
        _conn,
        %{
          "action" => "created",
          "repository" => %{"html_url" => html_url},
          "issue" => %{"title" => title},
          "comment" => %{"url" => comment_url, "body" => comment_body}
        } = _data
      ) do
    msg =
      "Issue #{html_url} - #{title}\n#{
        comment_body |> String.split("\n") |> List.first() |> String.slice(0, 240)
      }"

    IO.puts("Webhook Issue Comment:\n#{msg}\n#{comment_url}")
  end

  def handle(_conn, nil = data) do
    IO.inspect(data, label: :UNHANDLED_WEBHOOK, pretty: true, limit: :infinity)
  end

  def webhook(conn, params) do
    handle(conn, Jason.decode!(params))
  end
end
