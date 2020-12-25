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

  def get_summary("http://demosthenes.org" <> _url, _opts), do: "No, bad Demosthenex!"

  def get_summary(_url, %{recursion_limit: -1}) do
    "URL recursed HTTP 3xx status codes too many times (>4), this is a *bad* site setup and should be reported to the URL owner"
  end

  def get_summary(url, opts) do
    IO.inspect({url, opts})

    {is_yt, uri} =
      case URI.parse(url) do
        %{authority: yt} = uri
        when yt in ["m.youtube.com"] ->
          host = "www.youtube.com"

          case uri.query do
            nil ->
              {true, %{uri | query: "hl=en&disable_polymer=true", authority: host, host: host}}

            "" ->
              {true, %{uri | query: "hl=en&disable_polymer=true", authority: host, host: host}}

            query ->
              {true,
               %{uri | query: query <> "&hl=en&disable_polymer=true", authority: host, host: host}}
          end

        %{authority: yt} = uri
        when yt in ["youtube.com", "www.youtube.com", "youtu.be", "youtube.de"] ->
          case uri.query do
            nil -> {true, %{uri | query: "hl=en&disable_polymer=true"}}
            "" -> {true, %{uri | query: "hl=en&disable_polymer=true"}}
            query -> {true, %{uri | query: query <> "&hl=en&disable_polymer=true"}}
          end

        others ->
          {false, others}
      end

    # opts = [uri: uri] ++ opts
    opts = Map.put(opts, :uri, uri)
    url = URI.to_string(uri)

    IO.inspect(opts, label: :SiteParser_FullOpts)

    if String.contains?(url, [".zip", ".png", ".gif"]) do
      IO.puts("Skipped url")
      nil
    else
      req_headers = [
        {"authority", uri.host},
        {"pragma", "no-cache"},
        {"cache-control", "no-cache"},
        {"upgrade-insecure-requests", "1"},
        {"user-agent",
         "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/76.0.3809.100 Safari/537.36"},
        {"sec-fetch-mode", "navigate"},
        {"sec-fetch-user", "?1"},
        {"accept",
         "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3"},
        {"sec-fetch-site", "none"},
        # {"accept-encoding", "gzip, deflate, br"},
        {"accept-language", "en-US,en;q=0.9"}
      ]

      %{body: body, status_code: status_code, headers: headers} =
        _response = HTTPoison.get!(url, req_headers, follow_redirect: true, max_redirect: 10)

      case status_code do
        code when code >= 400 and code <= 499 ->
          # TODO:  Github returns a 4?? error code before the page fully exists, so check for github
          case uri do
            %{authority: "www.urbandictionary.com", path: "/define.php", query: "term=" <> word} ->
              "#{word}: Has no definition"

            _ ->
              # specifically and return empty here otherwise the message, just returning empty for now
              case code do
                403 -> "Page not allowed to be accessed, code: #{code}"
                _ -> "Page does not exist, code: #{code}"
              end
          end

        # nil

        code when code >= 300 and code <= 399 ->
          IO.inspect(headers, label: :Headers)

          case :proplists.get_value("Location", headers) do
            :undefined ->
              "URL Redirects without a Location header"

            new_url ->
              get_summary(new_url, Map.put(opts, :recursion_limit, opts[:recursion_limit] - 1))
          end

        200 ->
          cond do
            is_yt ->
              doc = Meeseeks.parse(body)

              case get_general(doc, opts) do
                result when is_binary(result) ->
                  case Meeseeks.attr(Meeseeks.one(doc, css("link[itemprop=name]")), "content") do
                    "" ->
                      result

                    author_name ->
                      "#{author_name}: #{result}"
                  end

                otherwise ->
                  otherwise
              end

            :else ->
              case url |> String.downcase() |> String.replace(~r|^https?://|, "") do
                "bash.org/" <> _ ->
                  get_bash_summary(Meeseeks.parse(body), opts)

                "git.gregtech.overminddl1.com/" <> _ ->
                  get_git(Meeseeks.parse(body), url, ".L", opts)

                "github.com/" <> _ ->
                  case Path.split(uri.path) do
                    ["/", _owner, _repository, "compare", _range] ->
                      get_github_compare(Meeseeks.parse(body), url, opts)

                    _ ->
                      get_git(Meeseeks.parse(body), url, "#LC", opts)
                  end

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
          end

        _ ->
          IO.inspect({:invalid_status_code, :get_summary, status_code})
          nil
      end
    end
  rescue
    err in HTTPoison.Error ->
      case err do
        # Broke HTTPoison... issue #171 still not resolved almost 4 years later...
        %{reason: {:invalid_redirection, {:ok, 303, headers, _client}}} ->
          # TODO:  Check each value case insensitive, but this works for youtu.be for now...
          case :proplists.get_all_values("Location", headers) do
            [new_url] when new_url != url ->
              get_summary(new_url, opts)

            _ ->
              IO.puts(
                "EXCEPTION: get_summary HTTPoison Location\n" <>
                  Exception.format(:error, err, __STACKTRACE__)
              )

              nil
          end

        _ ->
          IO.puts(
            "EXCEPTION: get_summary HTTPoison\n" <> Exception.format(:error, err, __STACKTRACE__)
          )

          nil
      end

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
    with nil <- get_fragment_paragraph(doc, opts) |> IO.inspect(label: "Fragment Paragraph"),
         nil <- get_summary_opengraph(doc, opts) |> IO.inspect(label: "Opengraph"),
         nil <- get_summary_title_and_description(doc, opts) |> IO.inspect(label: "TitleDesc"),
         nil <- get_summary_first_paragraph(doc, opts) |> IO.inspect(label: "First Paragraph"),
         nil <- get_summary_title(doc, opts) |> IO.inspect(label: "Title"),
         do: nil
  end

  def get_fragment_paragraph(doc, opts) do
    fragment = opts[:uri] && opts[:uri].fragment
    host = opts[:uri] && opts[:uri].host

    if fragment in [nil, ""] do
      nil
    else
      frag_selector = "#" <> fragment

      cond do
        String.contains?(host, "wikipedia.org") ->
          get_when_matched(doc, css(".mw-parser-output > *"), frag_selector, true, nil)

        String.contains?(host, "github.com") ->
          get_when_matched(
            doc,
            css("div.js-timeline-item"),
            frag_selector,
            false,
            css(".comment-body")
          )

        :else ->
          nil
      end
    end
  end

  defp get_when_matched(doc, selector, frag_selector, get_after, child_selector) do
    Meeseeks.all(doc, selector)
    |> get_when_matched(frag_selector, get_after, child_selector)
  end

  defp get_when_matched([], _frag_selector, _get_after, _child_selector), do: nil

  defp get_when_matched([_ | _] = elems, frag_selector, get_after, child_selector) do
    case Enum.drop_while(elems, &(nil == Meeseeks.one(&1, css(frag_selector)))) do
      [elem | _] when not get_after -> elem
      [_header, elem | _] when get_after -> elem
      _ -> nil
    end
    |> case do
      elem when child_selector == nil -> elem
      elem when child_selector != nil -> Meeseeks.one(elem, child_selector)
    end
    |> Meeseeks.text()
    |> get_first_line_trimmed()
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

  defp get_git(doc, url, l, %{uri: uri} = opts) do
    # uri = URI.parse(url)
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

  defp get_github_compare(doc, url, %{uri: uri} = opts) do
    # title = get_general(doc, opts)

    lines =
      doc
      |> Meeseeks.all(css(".TimelineItem-body"))
      |> Enum.flat_map(fn item ->
        with(
          name when is_binary(name) and bit_size(name) > 0 <-
            item
            |> Meeseeks.one(css("img.avatar-user"))
            |> Meeseeks.attr("alt")
            |> to_string()
            |> String.trim()
            |> String.split("\n", parts: 2)
            |> List.first()
            |> to_string()
            |> String.trim(),
          line when is_binary(line) and bit_size(line) > 0 <-
            item
            |> Meeseeks.one(css(".pr-1 code a"))
            |> Meeseeks.text()
            |> to_string()
            |> String.trim()
            |> String.split("\n", parts: 2)
            |> List.first()
            |> to_string()
            |> String.trim(),
          commit when is_binary(commit) and bit_size(commit) > 0 <-
            item
            |> Meeseeks.one(css(".ml-1 code a"))
            |> Meeseeks.text()
            |> to_string()
            |> String.trim()
            |> String.split("\n", parts: 2)
            |> List.first()
            |> to_string()
            |> String.trim(),
          do: ["#{line} · #{name} · #{commit}"],
          else: (_ -> [])
        )
      end)
      |> Enum.join("\n")

    # "#{title}\n#{lines}"
    lines
  end

  defp get_summary_opengraph(doc, _opts) do
    title = Meeseeks.one(doc, css("meta[property='og:title']"))
    description = title && Meeseeks.one(doc, css("meta[property='og:description']"))

    cond do
      title in [nil, ""] ->
        nil

      # description not in [nil, ""] ->
      #  get_first_line_trimmed(Meeseeks.attr(title, "content"))

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
          title in [nil, ""] -> nil
          description in [nil, ""] -> title
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

  defp get_summary_first_paragraph(doc, opts) do
    case opts[:uri] do
      %{authority: "www.urbandictionary.com", path: "/define.php", query: "term=" <> word} ->
        with(
          m when m != nil <- Meeseeks.one(doc, css(".meaning")),
          r when r != nil and r != "" <- Meeseeks.text(m) |> get_first_line_trimmed(),
          do: "#{word}: #{r}"
        )

      _ ->
        with(
          p when p != nil <- Meeseeks.one(doc, css("p")),
          t when t != nil and t != "" <- Meeseeks.text(p) |> get_first_line_trimmed(),
          do: t
        )
    end
  end

  defp get_first_line_trimmed(nil), do: nil
  defp get_first_line_trimmed(""), do: nil

  defp get_first_line_trimmed(lines) do
    lines
    # Institute 'some' kind of max limit, 2048 will do for now
    |> String.split_at(2048)
    |> elem(0)
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
