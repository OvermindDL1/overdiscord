defmodule ElixirParse do
  @moduledoc ~S"""
  """

  @default_allowed_types %{
    float: true,
    integer: true,
    safe_atom: true,
    unsafe_atom: false,
    string: true,
    binary: true,
    list: true,
    tuple: true
  }

  def default_allowed_types(), do: @default_allowed_types

  @doc ~S"""
  """
  def parse(input, opts \\ []) do
    %{} = allowed_types = opts[:allowed_types] || @default_allowed_types

    allowed_types =
      allowed_types
      |> Map.put_new(:number, allowed_types[:float] || allowed_types[:integer])
      |> Map.put_new(:atom, allowed_types[:safe_atom] || allowed_types[:unsafe_atom])

    parse(input, allowed_types, opts)
  end

  def skip_whitespace(" " <> input), do: skip_whitespace(input)
  def skip_whitespace("\t" <> input), do: skip_whitespace(input)
  def skip_whitespace("\n" <> input), do: skip_whitespace(input)
  def skip_whitespace("\r" <> input), do: skip_whitespace(input)
  def skip_whitespace(input), do: input

  defp parse(input, allowed_types, opts) do
    input = skip_whitespace(input)

    ignore = {:error, :ignore}

    with(
      {:error, _} <- (allowed_types[:atom] && parse_atom(input, allowed_types, opts)) || ignore,
      {:error, _} <-
        (allowed_types[:number] && parse_number(input, allowed_types, opts)) || ignore,
      do: {:error, input}
    )
  end

  defp parse_atom(":" <> input, allowed_types, _opts) do
    case String.split(input, ~R|[^a-zA-Z?!]|, parts: 2) do
      ["", _] ->
        {:error, input}

      [atom | input] ->
        input = (input == [] && "") || hd(input)

        if allowed_types[:unsafe_atom] do
          {:ok, String.to_atom(atom), input}
        else
          try do
            {:ok, String.to_existing_atom(atom), input}
          rescue
            ArgumentError -> {:error, input}
          end
        end

      _ ->
        {:error, input}
    end
  end

  defp parse_atom(input, _, _opts) do
    {:error, input}
  end

  defp parse_number(input, %{integer: true, float: true}, _opts) do
    case {Integer.parse(input), Float.parse(input)} do
      {{n, rest}, {m, rest}} when n == m -> {:ok, n, rest}
      {{_, _}, {m, rest}} -> {:ok, m, rest}
      {{n, rest}, :error} -> {:ok, n, rest}
      {:error, {m, rest}} -> {:ok, m, rest}
      {:error, :error} -> {:error, input}
    end
  end
end
