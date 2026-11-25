# 当前卡点

下一个 agent 从这里接着做。目标仍是：四个角色出现在同一场景里，按配置文件走动，并且用游戏自己的模型正确渲染。

玩家已经确认：游戏窗口里看不到场景。命令行进图没有成功，人停在主菜单或存档界面。

## 现象

游戏窗口在前台、命令已经被读走之后，`.\tools\h2t.ps1 status` 最后一行仍是：

```
bodies hero=absent enter=waiting
```

日志在 `C:\Program Files (x86)\Steam\steamapps\common\Hades II\Ship\ReturnOfModding\LogOutput.log`。已看到的行：

```
[Hades2Together] LoadMap missing rom.game=table LoadMap=nil
[Hades2Together] LoadMap missing, gameEnv=nil
[Hades2Together] import pre args string nil _G.LoadMap=nil raw=nil
```

没有 `enter F_Test` 成功行，也没有 `spawned seat`。

## 根因

插件 Lua 和游戏脚本 Lua 不是同一个状态。`src/hack/game.lua` 的 `Game:Enter` 找不到 `LoadMap`，返回 `false`。`src/hack/menu.lua` 因此不会清掉 `console.enterMap`，下一帧继续等。

已经核对过的事实：

- Hell2Modding 文档里 `rom.game` 只声明了 `LoadPackages`。源码在 `https://github.com/xiaoxiao921/Hell2Modding`，文件是 `docs/lua/tables/rom.game.md`。`d3d12.dll` 里有字符串 `rom.game`，没有 `LoadMap`、`SpawnObstacle`、`CurrentRun`。
- 插件启动时 `import_as_fallback(rom.game)` 只会回退到这张表。脚本加载前后再查 `rom.game.LoadMap`，类型都是 `nil`。`rom.game` 本身是 `table`。
- `rom.on_import.pre` 的文档签名是 `(file_name, current_ENV)`，返回值可以替换该脚本的 `_ENV`。这台机器上的 Hell2Modding 1.0.125 实际只传入文件名，第二个参数是 `nil`。回调里的 `_G.LoadMap` 也是 `nil`。闭包的 `_ENV` 是插件环境，Lua 5.2 的 `_ENV` 是词法上值，在回调里写 `LoadMap` 读不到游戏全局。
- `d3d12.dll` 里能找到 `on_import`、`pre`、`post`、`hook_luaL_loadfilex`。找不到 `dostring`、`luaL_loadstring` 或别的“在游戏状态里执行一段字符串”的入口。`on_import` 的实现不在 Hell2Modding 这个仓库里，应在 ReturnOfModding 基座。

所以现在不是地图名错了，也不是命令没排队。是模组进程里没有可以调用的进图函数。

## 已经写好、但没在场景里验证的部分

这些代码在 `main` 上，实机没有跑到。进图成功之后不要推倒重写。

- `control/inputs.txt` 是四个人的操作序列。`.\tools\h2t.ps1 play` 在目标文件不存在时把它复制到 `%USERPROFILE%\Hades2Together\inputs.txt`。格式是 `席位 moveX moveY 秒数`，也可以用 `name 席位 名字`。
- `src/dev/inputs.lua` 解析序列并积分位移。速度常量是 540，和 `_PlayerUnit` 一致。
- `src/hack/game.lua` 的 `BindHero` / `Drive`：1 号移动真正的英雄。2 到 4 号用 `BlankObstacle3D`，`GrannyModel = Melinoe_Mesh`，`Graphic = MelinoeIdle`，`Material = Unlit`，缩放 0.7。移动时切 `MelinoeRun`，停下切 `MelinoeIdle`，朝向是 `atan2(my, mx) * 180 / pi`。不要 `SetColor`，上色会破坏“正确渲染”。不要每帧把身体传送回英雄身边，那会抵消走动。
- 席位命令已经能在窗口前台时往返：`player add`、`player remove`、`status`。当时读到过 `1:Player` 和 `2:Fake1`，同时 `hero=absent`。

完成判据：窗口在前台时，`status` 最后一行出现 `hero=<id>`；执行 `play` 之后，2 到 4 号出现 `spawned=<id>`，并且 `x`、`y` 随时间变化。在这之前不要用 GUI 测。

## 下一个 agent 要解开的问题

找到一条能在游戏 Lua 状态里执行代码的路，然后从那里调用：

```lua
LoadMap({ Name = "F_Test" })
```

进图之后，同一条路上还要能调用 `SpawnObstacle`、`SetThingProperty`、`SetAnimation`、`Teleport`、`GetLocation`、`SetAngle`、`SetGoalAngle`、`Destroy`、`OnAnyLoad`，并读到 `CurrentRun.Hero.ObjectId`。这些名字现在在插件环境里全是 `nil`。生成和移动已经改成优先走 `Game.gameEnv`，但这张表从未被赋上有 `LoadMap` 的环境。

值得查的方向：

- ReturnOfModding 里 `hook_luaL_loadfilex` 的实现。文档说 `pre` 能拿到并替换脚本 `_ENV`，当前二进制没有把环境传进来。确认是版本差异、调用约定错误，还是环境只存在于另一个 Lua state。
- 其他模组用 ModUtil 的 `Path.Wrap` 包游戏函数。本仓库故意没装 ModUtil，它还依赖 `SGG_Modding-ENVY` 和 DemonDaemon。如果要借它拿到游戏函数，调用只能留在 `src/hack/game.lua`。
- 不要在 `on_import.pre` 里返回一张新的 `_ENV` 来“借”游戏函数。当前拿不到原来的环境，替换掉会让游戏脚本失去自己的全局变量。

`src/hack/game.lua` 里有这次留下的探测：`on_import.pre` 只收到文件名，以及生成、移动、`OnAnyLoad` 改为经 `Game.gameEnv` 调用。探测已经说明这条路目前拿不到环境，`Game.gameEnv` 一直是 `nil`。

## 不要做的事

- 不要点击主菜单或存档卡。测试面是 `tools/h2t.ps1`。
- 不要加载 `F_Opening01`。它是唯一 `GameStart = true` 的房间（`Content/Scripts/RoomDataF.lua`）。直接加载它会允许 `RequestSave` 写档，可能覆盖 `C:\Users\ROG\Saved Games\Hades II\Profile1.sav`。`F_Test` 是 `DebugOnly`，不是 `GameStart`；游戏会因此设置 `IllegalConversationModification`，并跳过存档。测试图用 `F_Test`。
- 不要在插件里调用 `os.execute`。插件会报 `os.execute() is not available`，`menu.lua` 会加载失败。
- 不要把 HTTP 服务做进游戏进程。泵在渲染回调 `rom.gui.add_always_draw_imgui` 上，窗口失焦时模拟停止，连接会挂住。网页由 `tools/h2t.ps1` 单独听 `127.0.0.1:27779`。
- 窗口不在前台时，`commands.txt` 不会被消费。`SetForegroundWindow` 不能可靠地让游戏恢复模拟。
- 开发时 `Ship\ReturnOfModding\plugins\MuGdxy-Hades2Together` 可以联接到仓库的 `src`。运行模块可以按 [热更新说明](modules.md#开发时热更新-lua) 重新加载。需要在已导入的游戏脚本之前注册钩子时，必须重启 `Hades2.exe`。
- 插件 Lua 兼容 5.2：不要位运算，不要 `//`，不要 `goto`。
- 提交作者必须是 `MuGdxy <lxy819469559@gmail.com>`。不要改 git config，用每次提交的环境变量。推送需要 Clash：`git -c http.proxy=http://127.0.0.1:7890 push`。不要 force-push `main`，除非用户明确要求。

## 本机位置

| 用途 | 路径 |
| --- | --- |
| 仓库 | `d:\Projects\Hades2Multiplayer`，`https://github.com/MuGdxy/Hades2Together.git`，分支 `main` |
| 游戏 | `C:\Program Files (x86)\Steam\steamapps\common\Hades II\Ship\Hades2.exe`，Steam `1145350` |
| 加载器 | `Ship\d3d12.dll`，Hell2Modding 1.0.125；旁边有 `LuaENVY-ENVY` 1.2.1 |
| 控制文件 | `%USERPROFILE%\Hades2Together\commands.txt`、`status.txt`、`inputs.txt` |
| 离线测试 | 仓库根目录 `lua tests/run.lua`。上次 14 项通过 |
