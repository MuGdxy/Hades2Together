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

`Game:ReadActors()` 在原版 `OnAnyLoad` 通知的名称、房间表、`SessionState.MapLoads` 及 `SessionMapState` 一致，且原版已完成延后物件初始化时附带房间数据。对应原版顺序见 `RoomLogic.lua:126–175, 180–236, 295–359`。装载确认前省略房间作用域。同一地图的不同进图使用不同编号；同一进图中的主遭遇以原版遭遇表保持身份。Lua 热更新沿用同一游戏实例及已登记的加载回调。门来自 `MapState.OfferedExitDoors`，通过原版 `IdExists` 核对对象；读取不到门时省略 `exits`。

关闭覆盖层且禁用存档的 `F_Combat01` 实机验证中，四个 localhost 观察端收到同一份房间、`FIntroFight` 和锁定的原版门 `560570`，热更新和重连后房间及遭遇编号不变。该次遭遇仍在进行。真实关卡完成、可用门的使用及原版奖励领取仍需验证。同名地图重访、装载窗口及不同遭遇的编号由 `texlua tests/read_actors.lua` 的夹具覆盖，只读传输用 `texlua tests/observer.lua` 检查。运行实机观察端见 [观察模式](network.md#实机只读观察模式)。

### 已生成的原版奖励

已打包的 `F_Reprieve01` 使用 `HealthRestore`。其房间开始事件调用原版 `SpawnRoomReward`，两次实机只读探针在固定生成点 `40055` 分别观察到原版 `PoseidonUpgrade` 和 `MaxHealthDrop`。来源见 `RoomDataF.lua:2960–2974`、`EncounterData_Unique.lua:4–12`、`RoomLogic.lua:1198, 2275–2283`、`RewardLogic.lua:399–428` 及 `InteractLogic.lua:861–865`。

当前投影仅包含 `HealthRestore` 的原版指定点上已确认可用的物件。它使用生成点的 `RewardPointsUsed` 记录定位 `RoomRequiredObjects` 中的对象，确认原版 `LootObjects` 或无购买要求的 `ActiveObstacles` 条目引用同一对象，再核对原版 `IdExists`、`IsUseable` 和 `GetName`。商店也会写 `RewardPointsUsed`，其配置见 `StoreLogic.lua:647–668`。门前预告、商店标记和未验证类型不会形成奖励记录。奖励的逻辑 ID 绑定于该进图中的原版对象表。原版在奖励已经出现时可能尚未写入 `Completed`，此时允许先送带 `encounterId` 的奖励，确认结算状态后同一 ID 会出现在遭遇记录上。

停止展示奖励可能是物件关掉了使用、准备选择或消失。原版选择界面的 `CurrentLootData` 和 `ScreenAnchors.ChoiceScreen.Source` 只能提供上下文，实际选择的原版提交另有路径。观察模式省略未验证的奖励集合、玩家资格和领取凭据。

### 原版提交边界（源码）

- **祝福。** `InteractLogic.lua:303–354, 621–739` 的 `OnUsed` 给出源物件 `TriggeredByTable` 和交互者 `UserTable`。有些使用记录在检查前就写入。拾取将物件禁用并打开选择，之后原版界面才根据输入可用性和实际按钮调用选择函数（`UILogic.lua:910–931`、`UpgradeChoiceLogic.lua:501`）。`HandleUpgradeChoiceSelection`（940–1066）在处理前先设置 `ChoiceMade`，再将实际选择加入 `CurrentRun.Hero`，叠层时修改已有特质。普通祝福的实质结果是 `AddTraitToHero` 转入 `AddTraitData`，后者在实际角色的 `Traits` 中插入带 ID 的原版实例（`TraitLogic.lua:471–493, 873–912`）。原版升级替换与额外祝福可在一次选择流程里产生多个变化；应按同一原版选择流程核对最终结果。全局的 `LastUpgradeChoice` 也由其他事件写入，`LootChoiceHistory` 仅保留深度、奖励名与选择内容。
- **免费消耗品。** `UseConsumableItem` 保留源物件和交互者入参，在检查死亡处理、使用限制、资源与阻止交互的敌人后才进入执行。禁用物件与演出先于效果；免费的原版分支跳过购买记账（`InteractLogic.lua:979–1037`）。已观察的 `MaxHealthDrop` 调用 `AddMaxHealth(amount, source, args)`，此处 `source` 是原物件，实际增益通过 `AddTraitToHero` 落到 `CurrentRun.Hero`，可能延后执行（`InteractLogic.lua:1055–1057`、`RoomLogic.lua:2722–2739`）。针对这类物件可核对该角色新增的 `RoomRewardMaxHealthTrait` 实例及其 `MaxHealth` 属性变化（`TraitData.lua:1302–1327`）。其他消耗品可能改全局资源，或用 `user.ObjectId` 应用效果（`InteractLogic.lua:1088–1105`、`ResourceLogic.lua:7–28`），受益人的判定需按实际效果入口验证。
- **区分状态变化。** 重复奖励可能重新启用物件（`InteractLogic.lua:1118–1129`），金币转换也可清除必需物件并销毁目标（`GiftLogic.lua:90–114`），换房重新初始化地图对象与菜单上下文（`RoomLogic.lua:131–141, 184–193, 4360–4417`）。因此领取核对需同时关联原房间实例、原物件、交互者和实际受益角色；跨房时关闭尚无提交证据的旧机会，已确认的回执可按旧身份保留。门解锁、对象消失、血量变化和历史计数各自均缺少这条关联。

现有只读表可以核对同一房间里的角色特质和菜单来源。源码审计未发现同时暴露原物件、交互者及已提交效果的原版只读回执。后续在原生输入映射可用时，用固定输入表的 `Use` 走普通世界交互，用验证过的原版菜单 `Select` 选择并核对实际角色实例变化；免费消耗品只走普通 `Use`。在同一房间分别采样使用前、菜单打开或效果提交后的状态，再独立验证取消、对象失效及换房。当前未运行这些交互。

## 后续原版接入

奖励均等指同一次经过验证的原版机会对每个符合条件的参与者提供一次原版交互。每席由该席原版上下文执行检查和选择，结果可以不同。已证实的零售流程只有当前英雄的赋予上下文；多人归属、同时选择或依次选择的原版入口仍待验证。需要确认 `OnUsed` 的真实角色/物件映射、原版选项归属和提交回执。用房间实例、遭遇实例、奖励机会和已绑定席位组合关联回执；等原版确认再从 `claiming` 进入 `consumed`。不得由网络自行选择或生成奖励，也不得复制一次 `AddTraitToHero` 结果、切换当前英雄或替原版开放出口。

若后续原版适配需要传递一次性操作（使用选中的门、选择当前原版菜单项），它需要可靠有序的意图和可重试的权威结果，连接要绑定席位和当前实例。每个意图需稳定请求 ID，按会话及席位去重，重连重发只返回既有结果。跨房意图在执行前检查房间实例和目标；离开后保留必要的最近请求结果用于拒绝或回执，但旧房的对象和机会不进入新房快照。`RoomLeaving` 或 `RewardConsumed` 可作为确认通知，恢复状态仍从完整快照读取。本提交只实现上述快照路径，未知或过期奖励请求收到普通无效输入错误。
