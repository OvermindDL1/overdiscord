for f <- [Map, Tuple, Any] do
  defimpl Exleveldb.Keys, for: f do
    def to_key(value) do
      :erlang.term_to_binary(value)
    end
  end

  defimpl Exleveldb.Values, for: f do
    def to_value(value) do
      :erlang.term_to_binary(value)
    end
  end
end
