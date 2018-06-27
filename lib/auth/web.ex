import ProtocolEx

defimplEx Web, {:web, %{}}, for: Overdiscord.Auth do
  def to_auth({:web, %{name: name}}) do
    %Overdiscord.Auth.AuthData{
      server: :web,
      location: "/gregchat",
      username: name,
      nickname: name,
      permissions: fn _ -> true end
    }
  end
end
