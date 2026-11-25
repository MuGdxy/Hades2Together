return {
  enabled = true,
  -- serve: authority, no local player.
  -- serve+play: this process is the authority and player 1.
  -- play: this process only sends input and presents snapshots.
  role = "serve+play",
  port = 27778,
  playerName = "Player",
  maxPlayers = 4,
  hpPerExtraPlayer = 0.75,
  lootPolicy = "round_robin",
  devPort = 27779,
}
