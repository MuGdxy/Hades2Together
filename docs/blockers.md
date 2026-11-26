# 当前卡点

Steam v1.143476 的标题画面可以启动游戏和模组，但没有触发游戏 Lua 更新或 Hell2Modding 的 ImGui 轮询。标题画面收到的 `player add`、`enter` 和 `play` 仍在队列中，`status` 显示 `queue=waiting for game update` 和 `hero=absent`。实机测试将 `RequireFocusToUpdate` 设为 `false`，游戏开着窗口，游戏 Lua 更新、持久线程和 ImGui 回调仍都没有执行。

默认房间 `F_Test` 有 `RoomData` 定义和 `Content/Maps/bin/F_Test.thing_bin`，本机 Steam 构建缺少 `Content/Maps/F_Test.map_text`。游戏原生启动路径会用 `MapData::MapFileExists` 检查直接启动请求，缺失时会回退到会写存档的正式开局房 `F_Opening01`。因此冷启动前先检查地图文件，进图后确认 `map=F_Combat01`，见 [CLI 用法](cli.md)。`enter` 对缺少地图文件和正式开局房的请求给出错误。

## 已验证的游戏接口

Hell2Modding 1.0.125（`a80069739d1333591c7ddfb89b606d9101bd31f4`）将 `rom.game` 绑定到真实游戏全局表。`LoadMap` 在启动模组时尚未出现，执行 `Main.lua` 后可用。`LoadMap` 会在引擎加载调用前后各让出一次执行，CLI 在游戏自己的 `thread` 内调用它，并在有引擎英雄坐标时才报告 `enter=ready`。CLI 会检查 `AllowSaveLoad`，并拒绝从已经存在的其他房间重置运行状态。 [Hell2Modding 游戏 Lua 绑定](https://github.com/SGG-Modding/Hell2Modding/blob/a80069739d1333591c7ddfb89b606d9101bd31f4/src/hades2/hades_lua.hpp#L105-L220)

在隔离启动目录用 `/AllowSaveLoad=false /DirectLoad=F_Combat01 /DirectLoadShell=false /RequireFocusToUpdate=false` 实测，CLI 在游戏启动后处理了 `status`、`player add` 和 `enter F_Combat01`。三个真实 `Profile*.sav` 文件的哈希在测试前后相同。

## 原生移动输入

Steam v1.143476 暴露的 `SendControlInput` 在原生动作分派中直接返回。实机请求按下、转向和释放后，`IsControlDown` 均为 false，英雄速度为 0，`GetLocation` 坐标保持一致。该分支没有读取玩家或对象参数。加载器的 `rom.inputs` 可注册按键观察回调。 [Hell2Modding 输入接口](https://github.com/SGG-Modding/Hell2Modding/blob/a80069739d1333591c7ddfb89b606d9101bd31f4/docs/lua/tables/rom.inputs.md)

演出 `Move` 在 `AddInputBlock` 下仍可移动英雄，角度和速度形式还可以进入引擎报告为阻挡的点。实机 `SpawnUnit` 生成的三个原生 NPC 都是 `PlayerControlled=false`。一席的 `input` 和 `play` 已接入可选的原版手柄采样器。普通二席仍依赖可独立管理的原生 Player/Unit/handler 生命周期。见[采样器与构建条件](../native/host-input/README.md)。

## 独立观察与既有模型调查记录

[只读观察模式](network.md#实机只读观察模式) 已验证四个独立进程接收同一权威快照，游戏外 CLI 与网页可查看状态。以下证据来自 Steam Ship v1.143476、上述 Hell2Modding 1.0.125 固定版本和对应的零售 PDB。`Hades2.exe` 的 SHA-256 为 `a6be16e91683e6fe3e566c5d68c1dcf8992bab9126b856606d57b7115e9c30dc`，`Hades2.pdb` 的 SHA-256 为 `dfebc6219deaaaa1d96dc03fe2866d14ca621e1836f685ff40e989c81d577ea7`。

隔离房间 `F_Combat01` 中的只读探针 `a_IuIXChN0fw` 验证了原生动画片段和时间。英雄 `40000` 的 `Melinoe_Staff_Idle` 从 0.2333 秒推进到 1.0333 秒，总时长 1.5667 秒。Brawler `1000001` 的 `Enemy_Brawler_Move` 从 0.2774 秒推进到 1.0774 秒，总时长 1.4167 秒。探针 `jTTcsHyFUtql` 记录到 Brawler 从 `Idle` 的分配编号 259、槽位 2 切换到 `Move` 的编号 261、槽位 3。随后编号和槽位保持不变，循环计数从 1 增至 2，本地时钟从 1.4001 秒回绕到 0.0001 秒。原地重启可保留原分配编号，因此稳定的播放实例代号、语义动作和客户端实际播放均未验证。

零售原生工厂 `AnimationManager::Create`（RVA `0x25ba80`）允许部分动画没有宿主。`ModelAnimation::Init`（RVA `0x2715c0`）在宿主为空时跳过挂接，但仍调用 `CreateResources`。初始化默认值会清空宿主字段，池复用时同样如此。`CreateResources` 在加载模型资源前直接解引用宿主的模型字段（RVA `0x2719df`），素材配置无法绕过这条指令。因此无法用该工厂安全创建无 `Thing` 宿主的原版模型，未构建或试运行呈现探针。已检查的原版 Ghost 会生成世界对象，Lua FX 句柄经过浮点转换而有精度损失，GUI 动画和缩略图入口分别使用屏幕坐标或消费已有绘制记录，Granny 子模型依赖已有父模型。

## 开发约定

- 优先通过 CLI 操作游戏，优先通过 Lua 热更新迭代，优先在游戏外的控制页查看和操作开发状态。游戏内开发 GUI 的代码可以用来查游戏 API，需要操作时在 CLI 暴露对应能力。
- 保持网页服务在独立进程的 `127.0.0.1:27779`。测试进图时使用 `/AllowSaveLoad=false`，跳过存档菜单和正式开局房 `F_Opening01`。
- Lua 兼容 5.2。插件内不要用 `os.execute`。离线套件在仓库根目录执行 `lua tests/run.lua`。
- 提交作者必须是 `MuGdxy <lxy819469559@gmail.com>`。不要改 git config，用每次提交的环境变量。推送需要 Clash：`git -c http.proxy=http://127.0.0.1:7890 push`。不要 force-push `main`，除非用户明确要求。
