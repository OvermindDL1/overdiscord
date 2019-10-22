import ProtocolEx

defimplEx IRC, {chan, %ExIRC.SenderInfo{}, %Overdiscord.IRC.Bridge.State{}} when is_binary(chan),
  for: Overdiscord.Auth do
  def to_auth({chan, senderinfo, state}) do
    _host = senderinfo.host
    user = senderinfo.user
    nick = senderinfo.nick

    %Overdiscord.Auth.AuthData{
      server: {:IRC, "#{state.host}##{state.nick}"},
      id: case senderinfo do
            %{host: "6.ip-144-217-164.net", user: "~OvermindD"} -> "OvermindDL1"
            _ -> "I-#{user}"
          end,
      location: chan,
      username: user,
      nickname: nick,
      permissions: fn _action ->
        case senderinfo do
          # OvermindDL1
          %{host: "6.ip-144-217-164.net", user: "~OvermindD"} ->
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
