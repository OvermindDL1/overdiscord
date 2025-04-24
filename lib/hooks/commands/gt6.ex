defmodule Overdiscord.Hooks.Commands.GT6 do
  require Logger

  alias Overdiscord.Storage

  import Overdiscord.Hooks.CommandParser, only: [log: 2]

  def parser_def() do
    %{
      strict: [
        verbose: :count
      ],
      aliases: [
        v: :verbose
      ],
      args: 0,
      help: %{
        nil => "GT6 related commands"
      },
      sub_parsers: %{
        "screenshot" => %{
          help: %{nil: "Get the most recently updated screenshot URL"},
          args: 0,
          strict: [],
          aliases: [],
          callback: {__MODULE__, :handle_cmd_screenshot, []}
        },
        "changelog" => %{
          help: %{nil: "Show the GT6 changelog"},
          args: 0..1,
          strict: [],
          aliases: [],
          callback: {__MODULE__, :handle_cmd_changelog, []},
          sub_parsers: %{
            "link" => %{
              help: %{nil: "Show the GT6 Changelog URL"},
              args: 0,
              strict: [],
              aliases: [],
              callback: {__MODULE__, :handle_cmd_changelog_link, []}
            }
          }
        }
      }
    }
  end

  def handle_cmd_screenshot(_arg) do
    HTTPoison.get!(
      "https://gregtech.overminddl1.com/com/gregoriust/gregtech/screenshots/LATEST.image.url"
    )
    |> case do
      %{body: url, status_code: 200} ->
        url = String.trim(url)

        if not String.ends_with?(url, [".png", ".jpg", ".jpeg", ".gif", ".webp", ".webm"]) do
          "Invalid image URL, last uploaded file to the screenshots directory was not an image, advise GregoriusTechneticies and/or @OvermindDL1 to update the image"
        else
          HTTPoison.get!("https://gregtech.overminddl1.com/imagecaption.adoc")
          |> case do
            %{body: description, status_code: 200} ->
              description =
                case String.trim(description) do
                  "." <> desc -> desc
                  "\uFEFF." <> desc -> desc
                  # "\uFEFF" <> desc -> desc
                  # Should always have a dot...
                  desc -> desc
                end

              "https://gregtech.overminddl1.com#{url}\n#{description}"

            _ ->
              "https://gregtech.overminddl1.com" <> url
          end
        end

      _ ->
        "Unable to retrieve image URL, report to @OvermindDL1" |> log(:error)
    end
  end

  def screenshot_poll() do
    # Screenshots are now updated from the GT6 maven refresh callback, don't duplicate the functionality
    screenshot = handle_cmd_screenshot(:console)

    Storage.get(:gt6, :kv, :screenshot_poll, nil)
    |> case do
      nil -> screenshot
      ^screenshot -> nil
      old_screenshot when is_binary(old_screenshot) -> screenshot
    end
    |> case do
      nil ->
        nil

      screenshot ->
        Storage.put(:gt6, :kv, :screenshot_poll, screenshot)
        Overdiscord.EventPipe.inject({:system, "Screenshot Updater"}, %{msg: "?gt6 screenshot"})
    end
  end

  def handle_cmd_changelog_link(_arg) do
    "https://gregtech.overminddl1.com/com/gregoriust/gregtech/gregtech_1.7.10/changelog.txt"
  end

  def handle_cmd_changelog(%{args: args} = _arg) do
    version = List.first(args) || "#SNAPSHOT"
    IO.inspect(version)

    case Overdiscord.Commands.GT6.get_changelog_version(version) do
      {:error, msgs} ->
        Enum.join(msgs, "\n")

      {:ok, %{changesets: []}} ->
        "Changelog has no changesets in it for version #{version}, see full log at:  https://gregtech.overminddl1.com/com/gregoriust/gregtech/gregtech_1.7.10/changelog.txt"

      {:ok, changelog} ->
        text = Overdiscord.Commands.GT6.format_changelog_as_text(changelog)
        embed = Overdiscord.Commands.GT6.format_changelog_as_embed(changelog)
        %{msg: Enum.join(text, "\n"), msg_discord: embed, reply?: true}
    end
  end
end
