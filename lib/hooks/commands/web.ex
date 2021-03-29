defmodule Overdiscord.Hooks.Commands.Web do
  require Logger

  import Meeseeks.CSS

  # alias Overdiscord.Storage

  # @db :cmd_web
  @lookup_limit 10

  def parser_def() do
    %{
      strict: [],
      aliases: [],
      args: 0,
      help: %{nil: "Command module with various useful web-based commands"},
      hoist: %{
        "udef" => true
      },
      sub_parsers: %{
        "udef" => %{
          help: %{
            nil: "Lookup the definition of a word or phrase on Urban Dictionary",
            count: "The max number of results to return, capped to @lookup_limit",
            live: "Bypass cache and get live results, this is slow"
          },
          args: 1..11,
          strict: [
            count: :integer,
            live: :boolean
          ],
          aliases: [
            n: :count
          ],
          callback: {__MODULE__, :handle_cmd_udef, []}
        }
      }
    }
  end

  def handle_cmd_udef(%{args: args, params: params}) do
    args = Enum.join(args, " ")

    count =
      case params[:count] do
        nil -> 3
        i when i <= 0 -> 1
        i when is_integer(i) -> i
      end

    if params[:live] do
      Cachex.del(:summary_cache, {args, count})
    end

    case Cachex.fetch(:summary_cache, {args, count}, fn {arg, count} ->
           case get_udef(args, count) do
             {:error, :no_definition} -> {:commit, []}
             {:error, error} -> {:ignore, []}
             {:ok, meanings} -> {:commit, meanings}
           end
         end) do
      {:ok, results} -> {:ok, results}
      {:loaded, results} -> {:ok, results}
      {:commit, results} -> {:ok, results}
      {:error, error} -> {:error, error}
    end
    |> case do
      {:error, _error} ->
        "Error with udef lookup"

      {:ok, []} ->
        "No meanings found for word"

      {:ok, meanings} when is_list(meanings) ->
        meanings =
          meanings
          |> Enum.with_index(1)
          |> Enum.map(fn {meaning, idx} -> "#{idx}. #{meaning}" end)

        ["#{length(meanings)} meaning(s) found for `#{args}`" | meanings]
        |> Enum.join("\n")
    end
  end

  # Helpers

  def get_udef(args, count) do
    url = "https://www.urbandictionary.com/define.php?term=#{args}"

    count =
      case count do
        count when count <= 0 -> 1
        count when count > @lookup_limit -> @lookup_limit
        count -> count
      end

    case get_webpage(url) do
      {:error, %{status_code: code} = error} when code in 200..600 ->
        Logger.info("UDef missing a definition: #{inspect(error)}")
        {:error, :no_definition}

      {:error, error} ->
        Logger.warn("Error on webpage lookup for `udef`: #{inspect(error)}")
        {:error, :lookup_error}

      {:ok, resp} ->
        doc = Meeseeks.parse(resp.body)

        meanings =
          doc
          |> Meeseeks.all(css(".meaning"))
          |> Enum.take(count)
          |> Enum.map(&Meeseeks.text/1)

        {:ok, meanings}
    end
  end

  def get_webpage(url) do
    uri = URI.parse(url)

    headers = [
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

    case HTTPoison.get!(url, headers, follow_redirect: true, recv_timeout: 4500) do
      %{body: _body, status_code: 200, headers: _headers} = result -> {:ok, result}
      error -> {:error, error}
    end
  end
end
