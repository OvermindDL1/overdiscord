import ProtocolEx

defimplEx IRC, {chan, %ExIRC.SenderInfo{}, %Overdiscord.IRC.Bridge.State{}} when is_binary(chan),
  for: Overdiscord.Auth do
  def to_auth({chan, senderinfo, state}) do
    _host = senderinfo.host
    user = senderinfo.user
    nick = senderinfo.nick

    %Overdiscord.Auth.AuthData{
      server: {:IRC, "#{state.host}##{state.nick}"},
      location: chan,
      username: user,
      nickname: nick,
      permissions: fn _action ->
        case senderinfo do
          # OvermindDL1
          %{user: "~uid16796"} ->
            true

          # Greg
          %{host: "ltea-" <> _, user: "~Gregorius"}
          when chan in ["GregoriusTechneticies", "#gt-dev"] ->
            true

          _ ->
            false
        end
      end
    }
  end
end
