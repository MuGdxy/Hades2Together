return {
  enabled = true,
  -- serve: authority, no local player.
  -- serve+play: this process is the authority and player 1.
  -- play: this process only sends input and presents snapshots.
  role = "serve+play",
  port = 27778,
  playerPort = 27780, -- Shared by play and the live authority. false disables player networking.
  bindAddress = "127.0.0.1", -- Set to the authority's LAN address for remote players.
  serverAddress = "127.0.0.1", -- play connects here.
  observerSnapshots = false, -- Run only the read-only observer.
  cliSnapshots = false, -- Publish read-only snapshots alongside the authority CLI.
  playerName = "Player",
  maxPlayers = 4,
  hpPerExtraPlayer = 0.75,
  lootPolicy = "round_robin",
  devPort = 27779,
}
