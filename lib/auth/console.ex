import ProtocolEx

defimplEx Console, :console, for: Overdiscord.Auth do
  def to_auth(:console) do
    %Overdiscord.Auth.AuthData{
      server: :console,
      location: "<CONSOLE>",
      username: "<CONSOLE>",
      nickname: "<CONSOLE>",
      permissions: fn _ -> true end
    }
  end
end
