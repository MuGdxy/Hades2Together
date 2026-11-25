# 房间通行与原版奖励

房间验证沿用一个零席的权威和四个独立客户端。从仓库根目录运行：

```powershell
lua tests/run.lua
python tests/net_smoke.py --lua lua --stock-room
```

使用自带 LuaSocket 的 MiKTeX 时，也可以运行 `texlua tests/run.lua` 和 `python tests/net_smoke.py --lua texlua --stock-room`。依赖及原传输测试见 [五进程 TCP 验证](network.md)。加上 `--stock-room` 后，夹具用现有 Fake 引擎证明四席各自提交输入，随后观察敌人血量、奖励状态、已解锁和已可用的门、离开旧房及进入同名的新房实例。四个客户端看到相同权威 tick 和四份已消耗凭据。伤害、奖励状态及房间转换来自显式测试夹具。

## 已确认的原版入口

以下行号来自本机 Steam v1.143476 的 `Content/Scripts`。它们是源码证据，室内交互和多人授予仍需运行验证。

| 观察阶段 | 原版脚本 |
| --- | --- |
| 遭遇结束 | `RoomLogic.lua:1897–1939` 在开始时将遭遇加入 `ActiveEncounters`，执行该遭遇的事件后才移除并设置 `Completed`。`EncounterSets.lua:452` 等场景在事件中生成房间奖励；`EncounterData_Opening.lua:28` 也有战斗前奖励。敌人死亡、奖励出现和遭遇结束是独立观察。 |
| 房间奖励 | `RewardLogic.lua:34–59, 210–258, 303–457` 用原版重复限制、房间和游戏状态条件选择内容，再按房间、遭遇及行为配置生成实际奖励。房门的预览和 `ChosenRewardType` 是配置或预告，实际机会以生成的原版对象为准。房间必需对象表也会包含其他交互。 |
| 拾取、选项、消耗 | `InteractLogic.lua:303–354` 从原版使用事件取得对象和玩家，检查使用要求。其 `UseLoot`（621–691）还检查阻挡敌人、界面及价格；返回成功值并不足以证明授予。`HandleLootPickup`（693–739）将对象设为不可用并打开原版选择界面。`UpgradeChoiceLogic.lua:940–1066` 由实际按钮执行原版选择，效果进入当前英雄，必要对象随后移除。普通消耗品走 `UseConsumableItem`（`InteractLogic.lua:979`）。 |
| 解锁及用门 | `RoomLogic.lua:3100–3131` 检查死亡、必需对象、阻塞界面及未结束遭遇。`UnlockRoomExits`（3778–3845）先标记房间，延时后 `DoUnlockRoomExits`（4002–4010）才把具体门设为可用。`ObstacleData.lua:251–254` 将门的使用事件交给 `AttemptUseDoor`（`RoomLogic.lua:749–875`），门本身还检查 `InUse`、特殊要求和额外遭遇。`LeaveRoom`（4159–4162、4360–4417）标记离开并走原版切图。 |

`CurrentRun.CurrentRoom` 在实际 `LoadMap` 之前已经赋值。发布下一房状态时，需要等待进图生命周期和对应 `MapState` 一致，再读取角色与交互对象。直接调用门或奖励脚本会跳过部分原版正常交互流程。以上函数只作为观察位置和验证原版路径的依据。

## 权威快照

`Server.listen(socket, port, engine, { stockRules = true })` 选择原版观察路径。权威转交已经入席的玩家输入，再用一次 `Engine.ReadActors()` 读取角色和可选的 `room`，作为同一 tick 的完整快照。这个路径没有旧的缩放、击杀授奖或死亡命令。现有不带 `stockRules` 的 Fake 测试继续验证旧版命令和传输。

- `room.id` 是本次权威会话中递增的进图实例编号，并随会话保持。重复地图名、返回同一地图和对象 ID 重用都可以产生新实例。`name` 只是地图名。缺少一致的进图状态时省略 `room`。
- `room.encounter` 是可选的当前原版遭遇记录，带房间内的实例 `id`、`name` 和 `completed`。多个同名遭遇需要不同实例 ID；角色消失或怪物血量为零不决定完成状态。
- `room.leaving`、`room.exitsUnlocked` 和可选 `room.exits` 分别投影离开、房间解锁及原版提供的门。门记录带原版对象 `id`、`readyToUse`、`inUse` 和可选的已知 `destination`。客户端提示仍以权威状态为准，使用动作走原版检查。
- `room.participants` 是可选的已验证席位数组，含仍保留资格的断线席位。参与资格由权威在相应原版奖励机会出现时确认。重连继承原席位；新连接或晚加入不能靠请求获得旧机会。
- `room.rewards` 是可选的当前房间奖励记录数组。每条记录带房间内唯一的逻辑机会 `id`、所属 `encounterId`、`kind` 和可选的原版 `objectId`。后者是当前物件的引用。已消耗机会可在当前房间内继续携带凭据，即使物件消失。
- 每个机会的可选 `claims` 数组每席至多一条，带 `playerId` 和 `state`（`eligible`、`claiming` 或 `consumed`），已消费时可带观测到的 `choice`。消耗只在原版提交确认后记录，且同一机会同一席只提交一次。缺少 `participants`、`rewards` 或 `claims` 表示尚未得到对应观察，空数组表示已观察到该集合为空。
- 客户端从全量快照恢复当前视图，并丢弃较旧的 tick 和回退的房间实例。换房即替换旧房的敌人、门和奖励视图，也能从下一房的一份快照加入。房间、门、奖励和领取状态没有独立的客户端写入入口。

## 实机只读投影

`Game:ReadActors()` 在原版 `OnAnyLoad` 通知的名称、房间表、`SessionState.MapLoads` 及 `SessionMapState` 一致，且原版已完成延后物件初始化时附带房间数据。对应原版顺序见 `RoomLogic.lua:126–175, 180–236, 295–359`。装载确认前省略房间作用域。同一地图的不同进图使用不同编号；同一进图中的主遭遇以原版遭遇表保持身份。Lua 热更新沿用同一游戏实例及已登记的加载回调。门来自 `MapState.OfferedExitDoors`，通过原版 `IdExists` 核对对象；读取不到门时省略 `exits`。未确认当前奖励归属和逐席资格，实机投影省略 `rewards` 和 `participants`。

关闭覆盖层且禁用存档的 `F_Combat01` 实机验证中，四个 localhost 观察端收到同一份房间、`FIntroFight` 和锁定的原版门 `560570`，热更新和重连后房间及遭遇编号不变。该次遭遇仍在进行。真实关卡完成、可用门的使用及原版奖励领取仍需验证。同名地图重访、装载窗口及不同遭遇的编号由 `texlua tests/read_actors.lua` 的夹具覆盖，只读传输用 `texlua tests/observer.lua` 检查。运行实机观察端见 [观察模式](network.md#实机只读观察模式)。

## 后续原版接入

奖励均等指同一次经过验证的原版机会对每个符合条件的参与者提供一次原版交互。每席由该席原版上下文执行检查和选择，结果可以不同。已证实的零售流程只有当前英雄的赋予上下文；多人归属、同时选择或依次选择的原版入口仍待验证。需要确认 `OnUsed` 的真实角色/物件映射、原版选项归属和提交回执。用房间实例、遭遇实例、奖励机会和已绑定席位组合关联回执；等原版确认再从 `claiming` 进入 `consumed`。不得由网络自行选择或生成奖励，也不得复制一次 `AddTraitToHero` 结果、切换当前英雄或替原版开放出口。

若后续原版适配需要传递一次性操作（使用选中的门、选择当前原版菜单项），它需要可靠有序的意图和可重试的权威结果，连接要绑定席位和当前实例。每个意图需稳定请求 ID，按会话及席位去重，重连重发只返回既有结果。跨房意图在执行前检查房间实例和目标；离开后保留必要的最近请求结果用于拒绝或回执，但旧房的对象和机会不进入新房快照。`RoomLeaving` 或 `RewardConsumed` 可作为确认通知，恢复状态仍从完整快照读取。本提交只实现上述快照路径，未知或过期奖励请求收到普通无效输入错误。
