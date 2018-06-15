import ProtocolEx

defimplEx Discord, %Alchemy.Message{}, for: Overdiscord.Auth do
  def to_auth(msg) do
    {:ok, guild_id} = Alchemy.Cache.guild_id(msg.channel_id)

    %Overdiscord.Auth.AuthData{
      server: {:Discord, guild_id},
      location: msg.channel_id,
      username: msg.author.id,
      nickname: msg.author.username,
      permissions: fn _action ->
        case msg do
          # OvermindDL1
          %{author: %{id: "240159434859479041"}} ->
            true

          _ ->
            false
        end
      end
    }
  end
end
