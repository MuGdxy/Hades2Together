# 开发命令行

`tools/h2t.ps1` 连到已经启动、并且加载了本模组的哈迪斯 2。地址固定是 `127.0.0.1`，端口是 `src/config.lua` 里的 `devPort`，默认 `27779`。

```powershell
.\tools\h2t.ps1 status
.\tools\h2t.ps1 players
.\tools\h2t.ps1 player add
.\tools\h2t.ps1 player add "Second Melinoe"
.\tools\h2t.ps1 player remove 2
```

`player add` 不写名字时，名字从 `Fake1` 开始递增。`player remove` 可以写席位号，也可以写名字。本地玩家启动时占 1 号席，名字来自 `playerName`。

这些命令只改席位。把假玩家变成世界里的单位是里程碑 2 的 `BindHero`。

游戏没开、或模组没听端口时，脚本会直接失败并说明原因。
