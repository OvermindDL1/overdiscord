defmodule Overdiscord.SiteParser do
  import Meeseeks.CSS

  def get_summary_cache_init(url) do
    get_summary(url)
  end

  def get_summary_cached(url) do
    case Cachex.get(:summary_cache, url) do
      {:ok, result} -> result
      {:loaded, result} -> result
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
    %{body: body, status_code: status_code, headers: headers} = _response = HTTPoison.get!(url)
    case status_code do
      code when code >= 300 and code <= 399 ->
        IO.inspect(headers, label: :Headers)
        case :proplists.get_value("Location", headers) do
          :undefined -> "URL Redirects without a Location header"
          new_url -> get_summary(new_url, Map.put(opts, :recursion_limit, opts[:recursion_limit] - 1))
        end
      200 ->
        case :proplists.get_value("Content-Type", headers) do
          :undefined -> nil
          "image" <> _ -> nil
          _ ->
            doc = Meeseeks.parse(body)
            with\
              nil <- get_summary_opengraph(doc, opts),
              nil <- get_summary_title_and_description(doc, opts),
              #nil <- get_summary_opengraph(doc, opts),
              nil <- get_summary_first_paragraph(doc, opts),
              do: nil
        end
      _ ->
        IO.inspect({:invalid_status_code, :get_summary, status_code})
        nil
    end
  rescue e ->
    IO.inspect({:EXCEPTION, :get_summary, e})
    nil
  catch e ->
    IO.inspect({:CRASH, :get_summary, e})
    nil
  end

  defp get_summary_opengraph(doc, _opts) do
    title = Meeseeks.one(doc, css("meta[property='og:title']"))
    description = title && Meeseeks.one(doc, css("meta[property='og:description']"))
    cond do
      title == nil -> nil
      description == nil -> get_first_line_trimmed(Meeseeks.attr(title, "content"))
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

  defp get_summary_title_and_description(doc, _opts) do
    imgur = "Imgur: The most awesome images on the Internet"
    with\
      te when te != nil <- Meeseeks.one(doc, css("title")),
      de when de != nil <- Meeseeks.one(doc, css("meta[name='description']")),
      t when t != nil and t != "" <-
        Meeseeks.own_text(te) |> get_first_line_trimmed(),
      d <- #when d != nil and d != "" <-
        Meeseeks.attr(de, "content") |> get_first_line_trimmed(),
      do: (case {t, d} do
            {^imgur, ^imgur} -> nil
            {^imgur, _} -> d
             {_, ^imgur} -> t
            {_, nil} -> t
             {_, ""} -> t
            _ -> "#{t} : #{d}"
          end)
  end

  defp get_summary_first_paragraph(doc, _opts) do
    with\
      p when p != nil <- Meeseeks.one(doc, css("p")),
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
