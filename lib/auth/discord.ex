import ProtocolEx

defimplEx Discord, %Alchemy.Message{}, for: Overdiscord.Auth do
  def to_auth(msg) do
    server_id =
      case Alchemy.Cache.guild_id(msg.channel_id) do
        {:ok, guild_id} -> guild_id
        {:error, _} -> nil
      end

    %Overdiscord.Auth.AuthData{
      server: {:Discord, server_id},
      # TODO: Look this up from a shared cache?
      id:
        case msg.author.id do
          "240159434859479041" -> "OvermindDL1"
          id -> "D-#{id}"
        end,
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
