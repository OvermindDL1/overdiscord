defmodule Overdiscord.SiteParser do
  import Meeseeks.CSS

  def get_summary_cache_init(url) do
    get_summary(url)
  end

  def get_summary_cached(url) do
    case Cachex.fetch(:summary_cache, url, &get_summary_cache_init/1) do
      {:ok, result} ->
        result

      {:loaded, result} ->
        result

      {:commit, result} ->
        result

      {:error, error} ->
        IO.inspect({:cache_error, :summary_cache, error})
        nil
    end
    |> case do
      "" -> nil
      result -> result
    end
  end

  def clear_cache() do
    Cachex.clear(:summary_cache)
  end

  def get_summary(url, opts \\ %{recursion_limit: 4})

  def get_summary(_url, %{recursion_limit: -1}) do
    "URL recursed HTTP 3xx status codes too many times (>4), this is a *bad* site setup and should be reported to the URL owner"
  end

  def get_summary(url, opts) do
    IO.inspect({url, opts})

    if String.contains?(url, [".zip", ".png", ".gif"]) do
      nil
    else
      %{body: body, status_code: status_code, headers: headers} =
        _response = HTTPoison.get!(url, [], follow_redirect: true, max_redirect: 10)

      case status_code do
        code when code >= 400 and code <= 499 ->
          # TODO:  Github returns a 4?? error code before the page fully exists, so check for github
          # specifically and return empty here otherwise the message, just returning empty for now
          # "Page does not exist"
          ""

        code when code >= 300 and code <= 399 ->
          IO.inspect(headers, label: :Headers)

          case :proplists.get_value("Location", headers) do
            :undefined ->
              "URL Redirects without a Location header"

            new_url ->
              get_summary(new_url, Map.put(opts, :recursion_limit, opts[:recursion_limit] - 1))
          end

        200 ->
          case url |> String.downcase() |> String.replace(~r|^https?://|, "") do
            "bash.org/" <> _ ->
              get_bash_summary(Meeseeks.parse(body), opts)

            "git.gregtech.overminddl1.com/" <> _ ->
              get_git(Meeseeks.parse(body), url, ".L", opts)

            "github.com/" <> _ ->
              get_git(Meeseeks.parse(body), url, "#LC", opts)

            _unknown ->
              case :proplists.get_value("Content-Type", headers) do
                :undefined ->
                  nil

                "image" <> _ ->
                  nil

                _ ->
                  get_general(Meeseeks.parse(body), opts)
              end
          end

        _ ->
          IO.inspect({:invalid_status_code, :get_summary, status_code})
          nil
      end
    end
  rescue
    e ->
      IO.puts("EXCEPTION: get_summary")
      IO.puts(Exception.format(:error, e, __STACKTRACE__))
      nil
  catch
    e ->
      IO.puts("THROWN: get_summary")
      IO.puts(Exception.format(:error, e, __STACKTRACE__))
      nil
  end

  defp get_general(doc, opts) do
    with nil <- get_summary_opengraph(doc, opts),
         nil <- get_summary_title_and_description(doc, opts),
         # nil <- get_summary_opengraph(doc, opts),                                                                      
         nil <- get_summary_first_paragraph(doc, opts),
         nil <- get_summary_title(doc, opts),
         do: nil
  end

  defp get_bash_summary(doc, _opts) do
    with(qt when qt != nil <- Meeseeks.one(doc, css(".qt"))) do
      qt
      |> Meeseeks.tree()
      |> case do
        {"p", [{"class", "qt"}], children} ->
          children
          |> Enum.map(fn
            str when is_binary(str) -> str
            _ -> ""
          end)
          |> :erlang.iolist_to_binary()

        _ ->
          nil
      end
    end
  end

  defp get_git(doc, url, l, opts) do
    uri = URI.parse(url)
    title = get_general(doc, opts)

    lines =
      Regex.run(~r/(\d+)-?L?(\d*)/, to_string(uri.fragment), capture: :all_but_first)
      |> List.wrap()
      |> Enum.map(&Integer.parse/1)
      |> case do
        [] ->
          ""

        [{line, ""}, :error] ->
          doc
          |> Meeseeks.one(css(l <> "#{line}"))
          |> Meeseeks.text()

        [{first, ""}, {last, ""}] ->
          cond do
            first > last -> nil
            first + 7 <= last -> first..(first + 8)
            true -> first..last
          end
          |> case do
            nil ->
              ""

            range ->
              doc
              |> Meeseeks.all(css(l <> Enum.join(range, "," <> l)))
              |> Enum.map(&Meeseeks.text/1)
              |> Enum.join("\n")
          end
      end

    "#{title}\n#{lines}"
  end

  defp get_summary_opengraph(doc, _opts) do
    title = Meeseeks.one(doc, css("meta[property='og:title']"))
    description = title && Meeseeks.one(doc, css("meta[property='og:description']"))

    cond do
      title == nil ->
        nil

      description == nil ->
        get_first_line_trimmed(Meeseeks.attr(title, "content"))

      true ->
        title =
          title
          |> Meeseeks.attr("content")
          |> get_first_line_trimmed()

        description =
          description
          |> Meeseeks.attr("content")
          |> get_first_line_trimmed()

        cond do
          title == description -> title
          description == nil -> title
          title == nil -> nil
          true -> "#{title} : #{description}"
        end
    end
  end

  defp get_summary_title(doc, _opts) do
    with(
      te when te != nil <- Meeseeks.one(doc, css("title")),
      t when t != nil and t != "" <- Meeseeks.own_text(te) |> get_first_line_trimmed(),
      do: t
    )
  end

  defp get_summary_title_and_description(doc, _opts) do
    imgur = "Imgur: The most awesome images on the Internet"

    with te when te != nil <- Meeseeks.one(doc, css("title")),
         de when de != nil <- Meeseeks.one(doc, css("meta[name='description']")),
         t when t != nil and t != "" <- Meeseeks.own_text(te) |> get_first_line_trimmed(),
         # when d != nil and d != "" <-
         d <- Meeseeks.attr(de, "content") |> get_first_line_trimmed(),
         do:
           (case {t, d} do
              {"Imgur", "Imgur"} -> nil
              {^imgur, ^imgur} -> nil
              {"Imgur", _} -> d
              {^imgur, _} -> d
              {_, "Imgur"} -> t
              {_, ^imgur} -> t
              {_, nil} -> t
              {_, ""} -> t
              _ -> "#{t} : #{d}"
            end)
  end

  defp get_summary_first_paragraph(doc, _opts) do
    with p when p != nil <- Meeseeks.one(doc, css("p")),
         t when t != nil and t != "" <- Meeseeks.text(p) |> get_first_line_trimmed(),
         do: t
  end

  defp get_first_line_trimmed(nil), do: nil
  defp get_first_line_trimmed(""), do: nil

  defp get_first_line_trimmed(lines) do
    lines
    |> String.trim()
    |> String.split("\n")
    |> List.first()
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      "Imgur: " <> _ -> nil
      "Use old embed code" -> nil
      result -> result
    end
  end
end
