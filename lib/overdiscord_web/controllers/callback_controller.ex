defmodule Overdiscord.Web.CallbackController do
  use Overdiscord.Web, :controller

  require Logger

  import Meeseeks.CSS

  alias Overdiscord.Storage

  @db :callback

  def forum(conn, %{
        "post" => %{
          "username" => _username,
          "topic_slug" => _topic_slug,
          "topic_id" => 191 = _topic_id,
          "topic_title" => _topic_title,
          "cooked" => _cooked,
          "topic_posts_count" => _topic_posts_count
        }
      }) do
    # url =
    #  "https://forum.gregtech.mechaenetia.com/t/#{topic_slug}/#{topic_id}/#{topic_posts_count}"

    # doc = Meeseeks.parse(cooked |> IO.inspect())

    # body =
    #  doc
    #  |> Meeseeks.one(css("body"))
    #  |> Meeseeks.text()

    # screenshot =
    #  case Meeseeks.one(doc, css("img")) do
    #    nil -> ""
    #    elem -> "Screenshot: #{Meeseeks.attr(elem, "src")}"
    #  end

    # body =
    #  case Meeseeks.all(doc, css("p")) do
    #    [_, _cap, change | _] = ps ->
    #      Enum.map(ps, fn p ->
    #        img = Meeseeks.one(p, css("img[alt='Screenshot']"))
    #        code = Meeseeks.one(p, css("code"))
    #        img = if(img, do: Meeseeks.attr(img, "src"))
    #        code = if(code, do: Meeseeks.tree(code))
    #
    #        case {img, code} do
    #          {nil, nil} -> Meeseeks.text(p)
    #          {img, nil} -> "Screenshot: #{img} #{Meeseeks.text(p)}"
    #          # TODO
    #          {nil, code} -> code
    #          {img, _code} -> "Screenshot: #{img} #{Meeseeks.text(p)}"
    #        end
    #      end)
    #      |> IO.inspect(label: :AllEntries)
    #
    #    _ ->
    #      "No body" |> IO.inspect(label: :NoCaptionChangelog)
    #  end

    # msg = "New Post: #{topic_title}\n#{body}\n#{screenshot}\n#{url}"

    # Overdiscord.EventPipe.inject({:system, "ForumEvent"}, %{msg: msg})

    text(conn, "ok")
  end

  def forum(conn, %{
        "post" => %{
          "username" => _username,
          "topic_slug" => topic_slug,
          "topic_id" => topic_id,
          "topic_title" => topic_title,
          "cooked" => cooked,
          "topic_posts_count" => topic_posts_count
        }
      }) do
    url =
      "https://forum.gregtech.mechaenetia.com/t/#{topic_slug}/#{topic_id}/#{topic_posts_count}"

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

  def send_event(name, msg) do
    msg = String.trim(msg)
    Overdiscord.EventPipe.inject({:system, name}, %{msg: msg, simple_msg: msg})
  end

  def send_event(name, msg, simple_msg) do
    msg = String.trim(msg)
    simple_msg = String.trim(simple_msg)
    Overdiscord.EventPipe.inject({:system, name}, %{msg: msg, simple_msg: simple_msg})
  end

  def send_irc_cmd(name, cmd) do
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
      #{pusher["full_name"]} pushed commits, see diff at: <<#{compare_url}>>
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

  def ci(
        conn,
        %{
          "commit" => commit,
          # "data" => %{"version" => version},
          "event" => _event,
          "head" => _head,
          "ref" => ref,
          "repository" => repository = "GregTech6/gregtech6",
          "workflow" => _workflow
        } = params
      ) do
    IO.inspect(%{req_headers: conn.req_headers, params: params})
    run_guid = :proplists.get_value("x-github-delivery", conn.req_headers)

    event_name = :proplists.get_value("x-github-event", conn.req_headers)

    IO.inspect({params, run_guid, event_name}, label: :CI_PARAMS)

    if conn.private.verified_signature do
      {short_commit, _} = String.split_at(commit, 8)
      name = "CI"
      title = "#{repository}/#{ref}/#{short_commit} "

      case ref do
        # Snapshot
        "refs/heads/master" ->
          name = name <> "-SNAPSHOT"

          case repository do
            "GregTech6/gregtech6" ->
              send_event(
                name,
                title <>
                  "New SNAPSHOT: https://gregtech.mechaenetia.com/secretdownloads/"
              )
          end

          case Storage.get(@db, :kv, {:last_commit_seen, repository}, nil) do
            nil ->
              url = "https://github.com/#{repository}/commit/#{commit}"
              send_event(name, "See commit at: <<#{url}>>")
              send_event(name, Overdiscord.SiteParser.get_summary_cached(url))

            # send_irc_cmd(name, url)

            %{last_commit: ^commit} ->
              url = "https://github.com/#{repository}/commit/#{commit}"
              send_event(name, "See commit at: <<#{url}>>")
              send_event(name, Overdiscord.SiteParser.get_summary_cached(url))

            # send_irc_cmd(name, url)

            %{last_commit: last_commit} ->
              url = "https://github.com/#{repository}/compare/#{last_commit}...#{commit}"
              send_event(name, "See diff at: <<#{url}>>")
              send_event(name, Overdiscord.SiteParser.get_summary_cached(url))
              # send_irc_cmd(title, url)
          end

          Storage.put(@db, :kv, {:last_commit_seen, repository}, %{last_commit: commit})

          text(conn, "ok")

        # Release
        "refs/tags/v" <> version ->
          name = name <> "-Release"

          send_event(
            name,
            title <>
              "New Release #{version}: https://gregtech.mechaenetia.com/downloads/gregtech_1.7.10/index.html#Downloads"
          )

          send_event(name, "?gt6 screenshot")
          send_event(name, "?gt6 changelog ##{version}")

          text(conn, "ok")

        # Unknown
        unknown_ref ->
          send_event(name, "Unknown ref type: #{inspect(ref)}")
          throw({:CI_UNKNOWN_REF, params, unknown_ref})
      end
    else
      conn
      |> put_status(:unauthorized)
      |> text("unauthenticated token")
    end
  end

  def ci(conn, params) do
    IO.inspect(params)
    conn |> put_status(500)
  end

  def concourse(
        conn,
        %{
          "ATC_EXTERNAL_URL" => _atc_external_url,
          "BUILD_ID" => _build_id,
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
                "New Release #{build_version}:  https://gregtech.mechaenetia.com/downloads/gregtech_1.7.10/index.html#Downloads"
              )

              send_event(title, "?gt6 screenshot")
              send_event(title, "?gt6 changelog ##{build_version}")

              # send_irc_cmd(title, "?screenshot")
              # send_irc_cmd(title, "?changelog ##{build_version}")

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
                    "See diff at: <<#{diff_url}>>\n#{commit_msgs}"
                end

              Storage.delete(@db, :kv, "GregTech-6/GT6")

              "New SNAPSHOT #{build_version}: https://gregtech.mechaenetia.com/secretdownloads/ \n#{
                msgs
              }"

            "SCREENSHOT" ->
              send_irc_cmd(title, "?screenshot")
              :undefined

            _ ->
              "Build #{build_name} of #{build_type} succeeded: https://gregtech.mechaenetia.com/secretdownloads/"
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
      |> text("unauthorized")
    end
  end

  def off_concourse(conn, params) do
    IO.inspect(params, label: :Concourse)

    conn
    # |> put_status(:not_implemented)
    |> text("unhandled")
  end

  def maven(conn, %{"action" => "regen", "paths" => paths, "token" => token} = params) do
    IO.inspect(params, label: :MavenCallback)
    token_hash = Base.encode16(:crypto.hash(:sha256, token))

    if token_hash == "9CFA303BDCDFFA72E341495C2ADEB61448E568E2058E8B9175748D520D79BE41" do
      Logger.info("Maven website regenerated: #{inspect(paths)}")

      event_if_maven_updated(
        url_content_of:
          "https://gregtech.overminddl1.com/com/gregoriust/gregtech/screenshots/LATEST.image.url",
        event: "?gt6 screenshot"
      )

      conn
      |> json(%{status: :success})

      # |> text("{'status': 'success'}")
    else
      conn
      |> put_status(:unauthorized)
      |> text("unauthorized")
    end
  end

  def maven(conn, params) do
    IO.inspect(params, label: :MavenCallbackUnmatched)
    text(conn, "unhandled")
  end

  def event_if_maven_updated(opts \\ []) do
    name = opts[:name] || "MAVEN"

    cond do
      opts[:url_content_of] ->
        opts[:url_content_of]
        |> HTTPoison.get!(follow_redirect: true)
        |> case do
          %{body: content, status_code: 200} ->
            {opts[:key] || opts[:url_content_of], String.trim(content)}

          res ->
            Logger.warn(
           	"event_if_maven_updated failed in url_content_of with opts `#{inspect opts}` with result: #{inspect res}`"
            )

            nil
        end
    end
    |> case do
      nil ->
        nil

      {key, value} ->
        case Storage.get(@db, :kv, {:maven, :updated, key}, nil) do
          ^value ->
            nil

          _old_value ->
            Storage.put(@db, :kv, {:maven, :updated, key}, value)
            {key, value, opts}
        end
    end
    |> case do
      nil ->
        Logger.info("event_if_maven_updated success but nothing to do: #[inspect opts}]")
        nil

      {_key, _value, opts} ->
        cond do
          opts[:event] ->
            case opts[:event] do
              msg when is_binary(msg) ->
                Overdiscord.EventPipe.inject({:system, name}, %{msg: msg, simple_msg: msg})
                Logger.info("event_if_maven_updated success for opts: #{inspect(opts)}")
                nil
            end
        end
    end
  end
end
