# 模块

一个进程按角色加载其中几层。`serve+play` 全加载。`serve` 不采集本机输入。`play` 不加载 `authority`。

| 路径 | 加载方 | 职责 |
| --- | --- | --- |
| `src/protocol/` | 两边 | 消息、编解码、席位。协议号在 `messages.lua`，当前是 1。 |
| `src/net/` | 两边 | 传输。`send` / `drain`。现在只有 `loopback.lua`。 |
| `src/gameplay/` | 权威 | 纯规则。输入是事件，输出是命令。 |
| `src/authority/loop.lua` | 权威 | 取输入，问 gameplay 要命令，交给 hack 执行，再读出快照。 |
| `src/hack/engine.lua` | 两边 | hack 接口的方法表。不调用游戏。 |
| `src/hack/fake.lua` | 测试 | 同一套方法的假世界。一只怪一条血。 |
| `src/hack/game.lua` | 游戏进程 | 唯一允许调用游戏的文件。 |
| `src/client/` | 客人 | 把本机操作收成 `Input`。 |
| `src/main.lua` `ready.lua` `config.lua` | 游戏进程 | Hell2Modding 入口和角色配置。 |

## hack 接口

`engine.lua` 规定方法名。`fake.lua` 和 `game.lua` 都要实现它们。

| 方法 | 用途 |
| --- | --- |
| `BindHero` | 把席位绑成世界里的一个单位 |
| `PushInput` | 把一帧操作写给这个单位 |
| `ReadActors` | 读出英雄和敌人的位置与血量 |
| `PullEvents` | 取出这一拍里发生的命中、死亡 |
| `RunAsHero` | 引擎要一个当前英雄时，把这次调用绑到指定席位 |
| `SetCamera` | 镜头框住给出的席位 |
| `SetAggroTargets` | 敌人可以把这些人当作目标 |
| `SetFocusTick` | 窗口失焦时是否继续模拟 |
| `ApplySnapshot` | 客人按快照摆放演员 |
| `SuppressLocalSim` | 客人停下自己的遭遇生成 |
| `Call` | 调用一个点名的游戏动作，例如 `ScaleEncounter`、`EndRun`、`OfferLoot` |

## 规则现在会产出的命令

`HeroDown`、`EndRun`、`OfferLoot`、`ScaleEncounter`、`SpawnHero`。

死亡：还有人活着就继续，全灭才 `EndRun("wipe")`。血量默认每多一名玩家增加 75%，在权威的第一拍按当时人数结算一次。祝福归属可以是 `host`、`killer` 或 `round_robin`，默认轮流，并且跳过已经倒下的人。

## 边界

`gameplay`、`authority`、`protocol`、`net`、`client`、`hack/engine.lua`、`hack/fake.lua` 里不能出现这些字样：

`CurrentRun`、`Path.Wrap`、`Path.Override`、`modutil`、`rom.game`、`rom.log`

加载器入口（`main.lua`、`ready.lua`、`reload.lua`、`config.lua`、`def.lua`）和 `hack/game.lua` 不受这条限制。`tests/run.lua` 会扫描源码。

游戏里的 `Path.Wrap`、对 `CurrentRun` 的读写、对原版函数的调用，只写在 `src/hack/game.lua`。其他文件通过 `Engine` 的方法使用它。
