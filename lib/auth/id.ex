import ProtocolEx

defimplEx ID, %Overdiscord.Auth.AuthData{}, for: Overdiscord.Auth do
  def to_auth(authdata), do: authdata
end
