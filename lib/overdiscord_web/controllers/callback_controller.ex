defmodule Overdiscord.Web.CallbackController do
  use Overdiscord.Web, :controller

  import Meeseeks.CSS

  alias Overdiscord.Storage

  @db :callback

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

  def gitea(conn, params) do
    # TODO:  Maybe support more secrets?
    secret_env = unquote(to_string(:os.getenv('WEBHOOK_GITEA_SECRET')))

    if params["secret"] === secret_env do
      gitea_handler(conn, List.first(get_req_header(conn, "x-gitea-event")), params)
    else
      ### TEMPORARY until gitea fixes their bug:  https://github.com/go-gitea/gitea/issues/4732
      case List.first(get_req_header(conn, "x-gitea-event")) do
        "issue_comment" = event ->
          gitea_handler(conn, event, params)

        _ ->
          IO.inspect(%{secret_env: secret_env, params: params},
            label: :GiteaEvent_Unhandled_Secret
          )

          conn
          |> put_status(:forbidden)
          |> text("unhandled_secret")
      end

      ### TEMPORARY end
      # IO.inspect(%{secret_env: secret_env, params: params}, label: :GiteaEvent_Unhandled_Secret)
      # conn
      # |> put_status(:forbidden)
      # |> text("unhandled_secret")
    end

    # :simple_msg
  end

  defp send_event(name, msg) do
    msg = String.trim(msg)
    Overdiscord.EventPipe.inject({:system, name}, %{msg: msg, simple_msg: msg})
  end

  defp send_cmd(name, cmd) do
    Overdiscord.EventPipe.inject({:system, name}, %{irc_cmd: cmd})
  end

  defp gitea_handler(conn, "push", %{
         "ref" => "refs/heads/master",
         "before" => before,
         "after" => after_,
         "compare_url" => compare_url,
         "commits" => commits = [_ | _],
         "repository" => repo,
         "pusher" => pusher
       }) do
    commit_msgs = Enum.map(commits, &"#{&1["author"]["name"]}: #{&1["message"]}")

    if repo["full_name"] == "GregTech-6/GT6" do
      prior =
        Storage.get(@db, :kv, repo["full_name"], %{
          before: before,
          after: after_,
          commit_msgs: []
        })

      updated_commit_msgs =
        (:lists.reverse(commit_msgs) ++ prior[:commit_msgs])
        |> Enum.map(&String.replace(&1, ~r|[\n\r]|, " "))
        |> Enum.filter(&(String.replace(&1, ~r|[\s\t]|, "") != ""))

      updated = %{
        prior
        | after: after_,
          commit_msgs: updated_commit_msgs
      }

      Storage.put(@db, :kv, repo["full_name"], updated)
    end

    commit_msgs = Enum.join(commit_msgs, "\n")

    msg =
      """
      #{pusher["full_name"]} pushed commits, see diff at: #{compare_url}
      #{commit_msgs}
      """
      |> String.trim()

    IO.puts("GIT:#{repo["full_name"]}: #{msg}")
    # send_event("GIT:#{repo["full_name"]}", msg)
    text(conn, "ok")
  end

  defp gitea_handler(conn, "OFF-issues", %{
         "action" => action,
         "issue" => issue,
         "repository" => repo
       })
       when action in ["opened", "closed"] do
    {body, _} = String.split_at(to_string(issue["body"]), 240)

    body =
      if action == "closed" do
        ""
      else
        "> " <> String.replace(body, "\n", "> ") <> "\n"
      end

    msg = """
    #{issue["user"]["username"]} #{action} an issue: #{issue["title"]}
    #{body}#{repo["html_url"]}/issues/#{issue["id"]}
    """

    send_event("GIT:#{repo["full_name"]}", msg)
    text(conn, "ok")
  end

  defp gitea_handler(conn, "OFF-pull_request", %{
         "action" => action,
         "pull_request" => pr,
         "repository" => repo,
         "sender" => sender
       })
       when action in ["opened", "closed"] do
    {body, _} = String.split_at(to_string(pr["body"]), 240)

    {body, action} =
      if action == "closed" do
        action =
          if pr['merged_by'] == nil do
            "#{sender["username"]} closed"
          else
            "#{pr["merged_by"]["username"]} merged"
          end

        {"", action}
      else
        {"> " <> String.replace(body, "\n", "> ") <> "\n", "#{pr["user"]["username"]} #{action}"}
      end

    msg = """
    #{action} a pull request to #{pr["base"]["label"]}: #{pr["title"]}
    #{body}#{pr["html_url"]}
    """

    send_event("GIT:#{repo["full_name"]}", msg)
    text(conn, "ok")
  end

  defp gitea_handler(conn, "OFF-issue_comment", %{
         "action" => action,
         "comment" => comment,
         "issue" => issue,
         "repository" => repo
       })
       when action in ["created"] do
    {body, _} = String.split_at(to_string(comment["body"]), 240)
    body = "> " <> String.replace(body, "\n", "> ")
    type = if(issue["pull_request"] == nil, do: "issue", else: "pull request")

    msg = """
    #{comment["user"]["username"]} left a comment on the #{issue["state"]} #{type} titled: #{
      issue["title"]
    }
    #{body}
    #{comment["html_url"]}
    """

    send_event("GIT:#{repo["full_name"]}", msg)
    text(conn, "ok")
  end

  defp gitea_handler(conn, event, params) do
    IO.inspect({event, params}, label: :GiteaEvent_Unhandled)

    conn
    |> put_status(:not_implemented)
    |> text("unhandled")
  end

  def concourse(
        conn,
        %{
          "ATC_EXTERNAL_URL" => _atc_external_url,
          "BUILD_ID" => build_id,
          "BUILD_JOB_NAME" => build_job_name,
          "BUILD_NAME" => build_name,
          "BUILD_PIPELINE_NAME" => build_pipeline_name,
          "BUILD_STATUS" => build_status,
          "BUILD_TEAM_NAME" => build_team_name,
          "BUILD_URL" => build_url,
          "BUILD_TYPE" => build_type,
          "BUILD_VERSION" => build_version,
          "TOKEN" => token
        } = params
      ) do
    token_hash = Base.encode16(:crypto.hash(:sha256, token))

    IO.inspect(params, label: :ConcourseWebhook_Params)

    if token_hash == "B212E7E563537303AE40BBAAB5D1C0534B3600410BF73F04C8CF12BB937AB441" do
      title = "CI:#{build_team_name}/#{build_pipeline_name}/#{build_job_name}"

      case build_status do
        "success" ->
          # TODO Detect both snapshot and latest version times to see which is more recent...
          case build_type do
            "RELEASE" ->
              send_event(
                title,
                "New Release #{build_version}:  https://gregtech.overminddl1.com/downloads/gregtech_1.7.10/index.html#Downloads"
              )

              send_cmd(title, "?screenshot")
              send_cmd(title, "?changelog")
              :undefined

            "SNAPSHOT" ->
              msgs =
                case Storage.get(@db, :kv, "GregTech-6/GT6", nil) do
                  nil ->
                    ""

                  %{before: before, after: after_, commit_msgs: commit_msgs} ->
                    diff_url =
                      "https://git.gregtech.overminddl1.com/GregTech-6/GT6/compare/#{before}...#{
                        after_
                      }"

                    commit_msgs = commit_msgs |> :lists.reverse() |> Enum.join("\n")
                    "See diff at: #{diff_url}\n#{commit_msgs}"
                end

              Storage.delete(@db, :kv, "GregTech-6/GT6")

              "New SNAPSHOT #{build_version}: https://gregtech.overminddl1.com/secretdownloads/\n#{
                msgs
              }"

            _ ->
              "Build #{build_name} of #{build_type} succeeded: https://gregtech.overminddl1.com/secretdownloads/"
          end
          |> case do
            msg when is_binary(msg) -> send_event(title, msg)
            _ -> :undefined
          end

        build_status ->
          msg = "**Build #{build_name} #{build_status}:** #{build_url}"
          send_event(title, msg)
      end

      text(conn, "ok")
    else
      conn
      |> put_status(:unauthorized)
      |> text("unauthenticated token")
    end
  end

  def off_concourse(conn, params) do
    IO.inspect(params, label: :Concourse)

    conn
    # |> put_status(:not_implemented)
    |> text("unhandled")
  end
end
