import ProtocolEx

defimplEx SystemNamed, {:system, name} when is_binary(name), for: Overdiscord.Auth do
  def to_auth({:system, name}) do
    %Overdiscord.Auth.AuthData{
      server: :console,
      id: name,
      location: "<SYSTEM>",
      username: "<SYSTEM>",
      nickname: name,
      permissions: fn _ -> true end
    }
  end
end
