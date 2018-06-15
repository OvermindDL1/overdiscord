import ProtocolEx

defimplEx IRC, {chan, %ExIrc.SenderInfo{}, %Overdiscord.IRC.Bridge.State{}} when is_binary(chan),
  for: Overdiscord.Auth do
  def to_auth({chan, senderinfo, state}) do
    host = senderinfo.host
    _user = senderinfo.user
    nick = senderinfo.nick

    %Overdiscord.Auth.AuthData{
      server: {:IRC, "#{state.host}##{state.nick}"},
      location: chan,
      username: host,
      nickname: nick,
      permissions: fn _action ->
        case senderinfo do
          # OvermindDL1
          %{host: "id-16796." <> _, user: "uid16796"} ->
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
