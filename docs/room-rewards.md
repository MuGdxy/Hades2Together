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

### 普通波塞冬祝福的领取回执

权威层 `gameplay/boon.lua` 按一次房间奖励机会分别保存每个席位的角色、有效选项、待确认选择和实际领取结果。引擎适配层调用 `setOptions` 提供经核实的选项；`select` 校验名册、角色和该席的选项；`confirm` 需要同一机会的选择凭据、实际受益角色、特质名和实例 ID。每席对同一机会最多确认一次。原版菜单表和按钮只在 `hack/stock_boon.lua` 转换为这些数据。菜单重建不会复制或提交一次选择。

当前房间的权威调用入口是 `Game:SelectBoon(roomId, rewardId, seat, choice)`。调用者从已认证的会话取得席号，入口用已绑定角色和原物件校验意图。已有有效选项时，调用无需菜单对象。快照 `room.rewards[].claims[]` 的 `options` 是该席已知的有效选项，`selected` 表示尚待引擎确认，`consumed/choice` 保留给已经落到受益角色的结果。此切片提供权威 Lua 接口；远端提交选择的传输命令仍待接入。

**普通候选可以在开菜单前读取。** 安装版 `CreateLoot` 调用 `SetTraitsOnLoot`，后者根据当前英雄生成 `loot.UpgradeOptions`；房间还可能用指定选项替换这张表。适配层读取当房已识别物件的最终列表，调用原版 `CalcNumLootChoices(loot)` 取得该英雄的可选数量。数量覆盖全部候选时即可向已绑定的宿主席公布普通新增特质。读取快照和提交选择均不重新抽取。见 `RoomLogic.lua:2266`、`RewardLogic.lua:376`、`TraitLogic.lua:1746–1754, 1760–2001`。

数量小于候选总数时，具体封锁索引由 `CreateBoonLootButtons` 随机抽取，再应用到排序后的条目。`CreateUpgradeChoiceButton` 逐条写入 `item.Blocked`，原版领取历史也读取此字段。适配层核对当次抽取留下的全部索引（可能有空洞）及对应条目标记，之后同一张候选表可脱离菜单使用。限制尚未确定或重掷后等待新结果时，快照暂缺该席的待选记录，旧选择凭据失效；已经确认的领取记录保留。候选生成与数量限制均依赖当前英雄，访客仍缺少按其 Unit 生成原版候选的入口。见 `UpgradeChoiceLogic.lua:149–193, 441–445, 707–717, 1184–1199` 和 `UtilityLogic.lua:1094–1120`。

运行 `texlua tests/run.lua` 可重放无 UI 的双席交错选择和逆序确认。该用例显式提供两个受益角色的结果数据，用于验证逐席归属；真实访客能否获得效果仍见下文安装版脚本的限制。

权威插件在 `HealthRestore` 房间先观察到指定点的可用 `PoseidonUpgrade`。该物件成为原版选择屏的来源后，观察器核对实际选择屏、按钮引用的原物件、传给 `AddTraitData` 的同一份特质数据，以及该调用的受益角色。原版普通新增分支见 `UpgradeChoiceLogic.lua:940–974`，受益角色与新特质实例的插入和返回见 `TraitLogic.lua:471–493, 873–905, 1154`。插件原样转发调用；只有返回的带 ID 新实例存在于该角色的 `Traits`，且房间、机会和席位仍匹配时才记录一次。

目前能按此路径确认的受益角色是 `CurrentRun.Hero`，席号取自权威游戏的 `hostSeat` 和当房名册。领取记录不标识按键的玩家。换装、叠层、消耗品以及访客受益仍缺对应的提交观察。取消选择、打开界面和物件销毁都不会生成回执。已确认的 `claims` 随当房快照保留，换房后清除。权威控制页和读取该快照的客户端在“游戏回执”显示 `seat`、`state=consumed` 和原版特质名 `choice`。

从仓库根目录运行 `texlua tests/read_actors.lua` 可重放这一接口。提供本机游戏的脚本目录作为参数（`texlua tests/read_actors.lua "<游戏目录>/Content/Scripts"`），正例将执行该版本原版的选择、授予及特质插入函数，界面与引擎调用仍由夹具提供。归档实机已确认该房能出现波塞冬奖励；领取与席位投影在本次接口回放中验证。

### 访客触发普通波塞冬祝福时的受益角色

**访客候选的数据边界（安装版 143476）。** 正式绑定 `Game:EnsureGuestActor` 已能取得原版创建并附在该 Unit 上的独立角色表。`GetTotalTraitCount(unit)` 可读取该角色的特质数。普通 `PoseidonWeaponBoon` 属于波塞冬掉落的五个优先候选之一（`LootData_Poseidon.lua:34–43`）。有空的近战槽只是进入候选池的条件；最终清单还取决于原版优先抽取、补位和数量限制。

可用 `texlua tests/stock_guest_boon_source.lua "<游戏目录>/Content/Scripts"` 单独验证选项来源。夹具用原版 `CreateNewHero` 创建两个 Lua 角色，只有访客持有该祝福、占近战槽并带有限选特质。用三个优先项排除随机裁剪后，原版 `SetTraitsOnLoot(loot, { Unit = guest })` 仍列出该访客已有的祝福，`CalcNumLootChoices` 仍返回宿主的 3。具体读取如下：

- `GetPriorityTraits` 从 `CurrentRun.Hero.Traits` 建立占槽表，用 `HeroHasTrait` 查宿主字典。`IsTraitEligible` 的数量上限检查也向宿主取数。按名称调用 `GetTraitCount(guest, ...)` 会触发仅限当前英雄的调试断言；断言不终止时读到的仍是宿主的层数。见 `UpgradeChoiceLogic.lua:739–778`、`RunLogic.lua:99–129`、`TraitLogic.lua:496–512, 541–557`。
- `GetHeroTraitValues(key, { Unit = guest })` 能遍历访客，但普通查询的缓存命中和填充都使用宿主的 `HeroTraitValuesCache`。回放中一次访客查询写入宿主缓存，随后宿主查询也返回该值。`HasHeroTraitValue` 则直接遍历宿主，是 `CalcNumLootChoices` 检查限选的来源。见 `TraitLogic.lua:398–428, 1746–1754`。

建议的最小接口是模组适配层的 `resolveOrdinaryBoonOptions(offer, unit)`。输入取该机会的原始掉落配置和已绑定的受益 Unit；占槽、已持有特质、限选、稀有度加成及其缓存均按该 Unit 读取，房间条件和本局禁用列表沿用权威世界。结果按机会、角色和本轮重掷保存，交给现有 `Boon.setOptions`。读取快照只取已裁定的结果。

具体需要决定的是访客抽取使用哪条随机序列。原版对一个物件写一次 `loot.UpgradeOptions`；优先池裁剪与封锁都调用未传 RNG 的 `RemoveRandomValue`，会消耗游戏的全局随机序列（`UpgradeChoiceLogic.lua:157–162, 774–779`、`UtilityLogic.lua:1094–1119`）。给访客再抽一次会推进后续原版随机结果。若要求保留宿主序列，则需为该机会的访客抽取显式传入权威管理的独立 RNG。两种策略都要保留宿主已经生成的掉落和限选结果。决定前，访客候选保持未知；本次回放没有执行授予。

安装版的 `OnUsed` 从 `triggerArgs.UserTable` 取得交互者，将其传给 `UseLoot(usee, args, user)`。正常通过检查后，`UseLoot` 调用 `HandleLootPickup(CurrentRun, usee, args)`，在这里丢失了独立的 `user` 参数。后者调用 `OpenUpgradeChoiceMenu(loot, args)`。见 `InteractLogic.lua:303–343, 621–676, 693–733`。

选项构建时，`CreateUpgradeChoiceButton` 明确以 `CurrentRun.Hero` 生成特质数据。普通新增分支在 `HandleUpgradeChoiceSelection` 调用 `AddTraitToHero`，最终执行 `AddTraitData(CurrentRun.Hero, traitData, args)`。正式二席绑定能取得真实访客 Unit、向对应 handler 提交输入；选择和授予函数没有使用该绑定来决定受益角色。见 `UpgradeChoiceLogic.lua:294, 940–974`、`TraitLogic.lua:471–493` 和 `native/host-input/observe-sampler-lua.hpp`。

低层的 `AddTrait(unit, ...)` 可以向指定 Unit 的 `Traits` 插入实例，直接调用会跳过原版选择。以 `PoseidonWeaponBoon` 为例，实际溅射通过 `OnEnemyDamagedAction` 触发：`CheckOnDamagedPowers` 在当前英雄或其法术召唤物攻击时遍历当前英雄的特质；`CheckPoseidonSplash` 创建弹体时也使用当前英雄的 ObjectId。访客 PlayerUnit 有一条同名特质记录，仍不足以证明其攻击获得了溅射。见 `TraitLogic.lua:859–911`、`TraitData_Poseidon.lua:27–34`、`PowersLogic.lua:148–180, 3813–3817`。

上面的安装脚本回放以夹具访客触发原版 `OnUsed`，在菜单界面边界提交现有选择按钮。断言覆盖原版调用只给宿主新增特质、访客特质表为空、快照只包含宿主席的一条已领取记录。游戏内访客操作及战斗效果仍未实测。访客领取需要原版选择可携带指定受益 Unit，并在实际效果消费处沿用该角色；当前接口缺少这条路径。

## 后续原版接入

奖励均等指同一次经过验证的原版机会对每个符合条件的参与者提供一次原版交互。每席由该席原版上下文执行检查和选择，结果可以不同。已证实的零售流程只有当前英雄的赋予上下文；多人归属、同时选择或依次选择的原版入口仍待验证。需要确认 `OnUsed` 的真实角色/物件映射、原版选项归属和提交回执。用房间实例、遭遇实例、奖励机会和已绑定席位组合关联回执；等原版确认再从 `claiming` 进入 `consumed`。不得由网络自行选择或生成奖励，也不得复制一次 `AddTraitToHero` 结果、切换当前英雄或替原版开放出口。

若后续原版适配需要传递一次性操作（使用选中的门、选择当前原版菜单项），它需要可靠有序的意图和可重试的权威结果，连接要绑定席位和当前实例。每个意图需稳定请求 ID，按会话及席位去重，重连重发只返回既有结果。跨房意图在执行前检查房间实例和目标；离开后保留必要的最近请求结果用于拒绝或回执，但旧房的对象和机会不进入新房快照。`RoomLeaving` 或 `RewardConsumed` 可作为确认通知，恢复状态仍从完整快照读取。本提交只实现上述快照路径，未知或过期奖励请求收到普通无效输入错误。
