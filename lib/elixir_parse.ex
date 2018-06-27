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

    case parse(input, allowed_types, opts) do
      {:error, _} = err -> err
      {:ok, result, rest} -> {:ok, result, skip_whitespace(rest)}
    end
  end

  def skip_whitespace(" " <> input), do: skip_whitespace(input)
  def skip_whitespace("\t" <> input), do: skip_whitespace(input)
  def skip_whitespace("\n" <> input), do: skip_whitespace(input)
  def skip_whitespace("\r" <> input), do: skip_whitespace(input)
  def skip_whitespace(input), do: input

  defp parse("", _a, _opts) do
    {:error, ""}
  end

  defp parse(input, a, opts) do
    input = skip_whitespace(input)

    ignore = {:error, :ignore}

    with(
      {:error, _} <- (a[:atom] && parse_atom(input, a, opts)) || ignore,
      {:error, _} <- (a[:list] && parse_list(input, a, opts)) || ignore,
      {:error, _} <- (a[:tuple] && parse_tuple(input, a, opts)) || ignore,
      {:error, _} <- (a[:string] && parse_string(input, a, opts)) || ignore,
      {:error, _} <- (a[:number] && parse_number(input, a, opts)) || ignore,
      do: {:error, input}
    )
  end

  defp parse_atom(":" <> input, allowed_types, opts) do
    case parse_string(input, allowed_types, opts) do
      {:ok, atom, rest} ->
        if allowed_types[:unsafe_atom] do
          {:ok, String.to_atom(atom), rest}
        else
          try do
            {:ok, String.to_existing_atom(atom), rest}
          rescue
            ArgumentError -> {:error, input}
          end
        end

      {:error, _} ->
        case String.split(input, ~R|[^a-zA-Z_?!]|, parts: 2, include_captures: true) do
          ["", _] ->
            {:error, input}

          [atom | input] ->
            input = (input == [] && "") || Enum.join(input)

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
  end

  defp parse_atom(input, allowed_types, _opts) do
    first = String.first(input)

    if first === String.upcase(first) and first !== String.downcase(first) do
      case String.split(input, ~R|[^a-zA-Z_?!.]|, parts: 2, include_captures: true) do
        [result] -> {result, ""}
        [result | rest] -> {result, Enum.join(rest)}
        [] -> nil
      end
      |> case do
        nil -> nil
        {"Elixir." <> _, _rest} = result -> result
        {atom, rest} -> {"Elixir." <> atom, rest}
      end
      |> case do
        nil ->
          {:error, input}

        {atom, rest} ->
          if allowed_types[:unsafe_atom] do
            {:ok, String.to_atom(atom), rest}
          else
            try do
              {:ok, String.to_existing_atom(atom), rest}
            rescue
              ArgumentError -> {:error, input}
            end
          end
      end
    else
      {:error, input}
    end
  end

  defp parse_tuple("{" <> input, a, opts) do
    input = skip_whitespace(input)
    parse_tuple_element(input, a, opts, [])
  end

  defp parse_tuple(input, _, _opts) do
    {:error, input}
  end

  defp parse_tuple_element("}" <> input, _, _opts, results) do
    {:ok, List.to_tuple(:lists.reverse(results)), input}
  end

  defp parse_tuple_element(input, a, opts, results) do
    case parse(input, a, opts) do
      {:error, _} = err ->
        err

      {:ok, result, rest} ->
        rest =
          case skip_whitespace(rest) do
            "," <> rest -> skip_whitespace(rest)
            rest -> rest
          end

        parse_tuple_element(rest, a, opts, [result | results])
    end
  end

  defp parse_list("[" <> input, a, opts) do
    input = skip_whitespace(input)
    parse_list_element(input, a, opts, [])
  end

  defp parse_list(input, _a, _opts) do
    {:error, input}
  end

  defp parse_list_element("]" <> input, _, _opts, results) do
    {:ok, :lists.reverse(results), input}
  end

  defp parse_list_element(input, a, opts, results) do
    case parse(input, a, opts) do
      {:error, _} = err ->
        err

      {:ok, result, rest} ->
        rest =
          case skip_whitespace(rest) do
            "," <> rest -> skip_whitespace(rest)
            rest -> rest
          end

        parse_list_element(rest, a, opts, [result | results])
    end
  end

  defp parse_string("\"" <> input, a, opts) do
    parse_string_character(input, a, opts, "")
  end

  defp parse_string(input, _a, _opts), do: {:error, input}

  defp parse_string_character("", _a, _opts, _result) do
    {:error, ""}
  end

  defp parse_string_character("\"" <> input, _a, _opts, result) do
    {:ok, result, input}
  end

  defp parse_string_character("\\\"" <> input, a, opts, result) do
    parse_string_character(input, a, opts, result <> "\"")
  end

  defp parse_string_character(<<c::utf8, input::binary>>, a, opts, result) do
    parse_string_character(input, a, opts, result <> <<c::utf8>>)
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
