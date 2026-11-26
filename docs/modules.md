# 模块

一个进程按角色加载其中几层。`serve+play` 全加载。`serve` 不采集本机输入。`play` 不加载 `authority`。

| 路径 | 加载方 | 职责 |
| --- | --- | --- |
| `src/protocol/` | 两边 | 消息、编解码、席位。协议号在 `messages.lua`，当前是 1。 |
| `src/net/` | 两边 | `loopback.lua` 和本机 `tcp.lua` 使用 `send` / `drain`。 |
| `src/gameplay/` | 权威 | 纯规则。输入是事件，输出是命令。 |
| `src/authority/loop.lua` | 权威 | 取输入，问 gameplay 要命令，交给 hack 执行，再读出快照。 |
| `src/authority/server.lua` | 权威 | 接入 TCP、分配席位和验证输入，调用权威循环并广播完整快照。 |
| `src/hack/engine.lua` | 两边 | hack 接口的方法表。不调用游戏。 |
| `src/hack/fake.lua` | 测试 | 同一套方法的假世界。一只怪一条血。 |
| `src/hack/game.lua` | 游戏进程 | 唯一允许调用游戏的文件。 |
| `src/client/` | 客人 | 把本机操作编成 `Input`，接收权威裁决并用完整快照替换视图。 |
| `src/dev/console.lua` | 权威 | 开发命令。只改席位，不碰游戏。 |
| `src/dev/bridge.lua` | 权威 | 执行控制页排进来的命令，并写出席位。 |
| `src/hack/menu.lua` | 游戏进程 | 在游戏渲染时读命令队列。 |
| `tools/h2t.ps1` | 本机 | 提供 `http://127.0.0.1:27779/`。 |
| `src/main.lua` `reload.lua` `ready.lua` `config.lua` | 游戏进程 | Hell2Modding 入口、热更新、运行模块和角色配置。 |

## 开发时热更新 Lua

先用 Hell2Modding 1.0.125 和 LuaENVY 1.2.1 启动一次游戏。编辑安装中的 `ReturnOfModding/plugins/MuGdxy-Hades2Together` 下的运行模块并保存。如果这个目录联接到仓库的 `src`，可以直接改仓库文件。加载器监视启动时已存在的目录，收到 `.lua` 文件写入通知后会在下一次渲染时重新执行 `main.lua`。如果编辑器用临时文件替换源文件而没有触发通知，保存完所有改动后，在安装的插件目录执行以下命令，随后让游戏窗口处于前台。

```powershell
(Get-Item .\ready.lua).LastWriteTime = Get-Date
```

- 可以热更新 `ready.lua`、`hack/menu.lua`、`hack/game.lua`、`dev/` 和 `ready.lua` 加载的其他模块。保持会话、控制状态、游戏状态和已解析的播放脚本的数据格式兼容。已排队命令由下一次控制轮询处理。席位、确认和播放进度继续使用原值。已经调度的 `enter` 和 `play` 保留当前进度。
- 运行模块有语法错误、顶层执行错误或缺少控制入口时，日志会写 `[Hades2Together] Lua load failed:`，旧版控制继续轮询。修正并保存后，看到 `[Hades2Together] Lua reloaded` 即可验证下一次轮询用了新代码。加载模块时应只定义代码和数据，游戏调用及控制操作留到回调执行时。
- 改 `main.lua`、`reload.lua`、`config.lua`、`def.lua`、依赖或已存活状态的数据结构需要重启游戏。热更新重新挂接控制轮询，游戏持有的 `OnAnyLoad` 回调继续调用当前模块的方法。直接编辑 `main.lua` 时，加载器会先清除旧回调，入口本身的语法错误需要先修正才能恢复轮询。

1.0.125 的 DLL SHA-256 与发布构建一致。该构建启用了插件目录监听，在渲染前清除插件的 GUI 和导入回调，并在原环境中重新执行入口。LuaENVY 1.2.1 的 `import(path, env)` 用 `loadfile` 读磁盘并支持指定模块环境。 [Hell2Modding 构建](https://github.com/SGG-Modding/Hell2Modding/actions/runs/45138009861) · [监听与回调清理](https://github.com/xiaoxiao921/ReturnOfModdingBase/blob/693360501a0b5309e302956fca1c5aaf528da441/src/lua/lua_manager.cpp#L165-L256) · [LuaENVY 1.2.1](https://thunderstore.io/c/hades-ii/p/LuaENVY/ENVY/v/1.2.1/)

## hack 接口

`engine.lua` 规定方法名。`fake.lua` 和 `game.lua` 都要实现它们。

| 方法 | 用途 |
| --- | --- |
| `BindHero` | 把席位绑成世界里的一个单位 |
| `PushInput` | 提交一帧玩家输入，游戏接口不支持时返回 `false` 和原因 |
| `ReadActors` | 读出英雄和敌人的位置与血量 |
| `PullEvents` | 取出这一拍里发生的命中、死亡 |
| `RunAsHero` | 引擎要一个当前英雄时，把这次调用绑到指定席位 |
| `SetCamera` | 镜头框住给出的席位 |
| `SetAggroTargets` | 敌人可以把这些人当作目标 |
| `SetFocusTick` | 窗口失焦时是否继续模拟 |
| `ApplySnapshot` | 客人按快照摆放演员 |
| `SuppressLocalSim` | 客人停下自己的遭遇生成 |
| `Call` | 调用一个点名的游戏动作，例如 `ScaleEncounter`、`EndRun`、`OfferLoot` |

`Game:ReadActors()` 每次返回一份当前 `heroes` 和 `enemies` 数组。英雄来自当前运行中的原生英雄，敌人取引擎 `EnemyTeam` 与脚本 `ActiveEnemies` 的交集。敌人按原生对象 ID 排序，每个 ID 只出现一次。死亡或被移出该范围的敌人从下一份完整快照消失。仍有原生对象的死亡英雄保留 `alive=false`。连入会话的其他席位当前不会生成英雄记录。

记录包含 `id`、`kind`、`x`、`y`、`hp`、`maxHp` 和 `alive`，可读时附带引擎的 `facing`（角度）。HP 来自游戏战斗使用的 Lua 单位表，位置和朝向来自原生查询。缺少有效对象、位置、血量或存活状态时省略该对象。动作、动作阶段、动作实例和奖励对象尚未验证读回协议，目前省略。

运行中的游戏绑定另提供 `Game:ReadLocalInput()`。调用方可在游戏更新时采样本机玩家的 `IsControlDown`。方向按右减左、下减上分别取 `-1`、`0`、`1`，`buttons` 按 V1 记录按住状态，第 0 位为 `Attack1`，第 1 位为 `Attack2`。原生方向查询可以把手柄读数归入方向，但结果仍是布尔值。采样读取当前的按住状态，短于采样间隔的按下并释放可能漏掉。输入状态可交给 `client/input.lua` 的帧构造器，由调用方指定网络席位。连续摇杆轴与瞄准输入目前没有验证，帧构造器补上的瞄准零值仅作占位。没有本地英雄或游戏读回函数时返回 `nil` 和原因。

## 规则现在会产出的命令

`HeroDown`、`EndRun`、`OfferLoot`、`ScaleEncounter`、`SpawnHero`。

死亡：还有人活着就继续，全灭才 `EndRun("wipe")`。血量默认每多一名玩家增加 75%，在权威的第一拍按当时人数结算一次。祝福归属可以是 `host`、`killer` 或 `round_robin`，默认轮流，并且跳过已经倒下的人。

## 边界

`gameplay`、`authority`、`protocol`、`net`、`client`、`hack/engine.lua`、`hack/fake.lua` 里不能出现这些字样：

`CurrentRun`、`Path.Wrap`、`Path.Override`、`modutil`、`rom.game`、`rom.log`

加载器入口（`main.lua`、`ready.lua`、`reload.lua`、`config.lua`、`def.lua`）和 `hack/game.lua` 不受这条限制。`tests/run.lua` 会扫描源码。

游戏里的 `Path.Wrap`、对 `CurrentRun` 的读写、对原版函数的调用，只写在 `src/hack/game.lua`。其他文件通过 `Engine` 的方法使用它。
