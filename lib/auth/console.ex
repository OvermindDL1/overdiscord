import ProtocolEx

defimplEx Console, :console, for: Overdiscord.Auth do
  def to_auth(:console) do
    %Overdiscord.Auth.AuthData{
      server: :console,
      id: "0",
      location: "<CONSOLE>",
      username: "<CONSOLE>",
      nickname: "<CONSOLE>",
      permissions: fn _ -> true end
    }
  end
end

defimplEx ConsoleNamed, {:console, name} when is_binary(name), for: Overdiscord.Auth do
  def to_auth({:console, name}) do
    %Overdiscord.Auth.AuthData{
      server: :console,
      id: "#{name}",
      location: "<CONSOLE>",
      username: "<CONSOLE>",
      nickname: name,
      permissions: fn _ -> true end
    }
  end
end
