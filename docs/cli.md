# 本地控制页

控制页是单独的本机网页。游戏收到更新回调时，会从 `%USERPROFILE%\Hades2Together\commands.txt` 取走命令。标题画面在已测试的 Steam 构建上没有触发该回调，切换窗口焦点无法替代进图。

先开页面：

```powershell
.\tools\h2t.ps1
```

浏览器打开 `http://127.0.0.1:27779/`。实时页根据游戏状态显示席位、连接、角色 ID、坐标和最近应用序号。可以加入玩家、让任意已有席位按原名重连或断线、为指定席位提交 X/Y 与 Attack1/Attack2、发送显式零、请求进房和执行输入脚本。新名字按现有规则进入首个空席。页面与命令行共用队列及 `inputs.txt` 初始化，打开网页不会启动游戏。

页面分别显示本页命令的排队结果、游戏命令回执和最近应用序号。排队成功只表示写入队列，`OK input` 表示游戏接收提交，`appliedSeq` 来自原版采样回执。当前状态未携带每条队列命令与应用序号的关联，页面不会自动认定哪条命令已应用。最新原始状态和本页最近读数可展开查看。

不打开页面时，也可以直接排队：

```powershell
.\tools\h2t.ps1 enter
.\tools\h2t.ps1 player add
.\tools\h2t.ps1 player add "Second Melinoe"
.\tools\h2t.ps1 player remove 2
.\tools\h2t.ps1 status
```

`h2t.ps1 status` 显示最近一批命令的确认。看到 `queue=waiting for game update` 时，队列文件仍在等待游戏处理。最后一行的 `hero=absent` 表示游戏里还没有可用的英雄。实际地图由游戏的 `CurrentRun` 提供，英雄的 `x`、`y` 由引擎的 `GetLocation` 提供。`2:Fake1:unsupported` 表示席位已加入，但没有可用的原生玩家输入槽。

单次按住状态通过 `h2t.ps1 input` 提交。用法、动作列表和当前的原生执行限制见 [玩家输入](input.md)。

**访客祝福。** 权威本机的“祝福领取”按席显示实际候选、待确认选择和已领取结果。可提交的选项带有领取按钮。命令行从 `h2t.ps1 status` 的同一条 `claim` 记录复制 `seat`、`opportunity`，并从 `grantOptions` 选择一项（旧状态使用 `grantOption`）。例如，第三席获得房间 7、奖励 2、第 4 轮的机会时，可执行：

```powershell
.\tools\h2t.ps1 boon 3 7/2/4 PoseidonWeaponBoon
```

当前支持访客普通新增的 `PoseidonWeaponBoon` 和 `PoseidonSpecialBoon`。`options` 列出本轮候选，`grantOptions` 列出其中可提交的选项。返回 `queued` 后，查看游戏回执中的 `OK boon ... instance=...` 或 `ERR boon ...`。同席记录中的 `state=consumed choice=...` 表示已确认领取。换房或重掷后请使用新机会标识。观察者和远端玩家页可查看快照里的选项与结果。

玩家卡片中的“持有的波塞冬祝福”读取当前绑定角色的普攻和特攻祝福。权威快照的 `heroes[].heldBoons` 按实例提供 `name`、`rarity`、`stacks`。离线持席换房后从新角色读取；空列表显示“无”，旧快照或未读到特质表时显示“状态未提供”。尚无绑定角色的名册席位单独标明。

启用 [只读观察模式](network.md#实机只读观察模式) 或远端玩家 `play` 模式时，`h2t.ps1 status` 与控制页显示最近完整的状态文件，控制页和本机 CLI 拒绝排队游戏操作。远端玩家页额外显示连接状态、获配席位和本机已发送序号，后者表示网络发送，与权威端的原版应用回执含义不同。

## 历史运行

新增玩家操作或游戏状态时，同一次交付应更新控制页的操作、状态或回执。验证页面时使用产生该状态的那一层，已结束的验证可以发布到运行记录，保留其实际验证范围和退出结果。

在控制页选择 **运行记录**，即可从默认控制目录的 `history/<runId>/` 查看已发布的记录，游戏关闭时也可用。要收录一次已结束的运行，从仓库根目录执行：

```powershell
.\tools\publish-run.ps1 -RunDirectory <实机运行目录>
```

运行目录名用作 `runId`，网页列出实际存在的 `run-output.txt`、`stages.txt`、`snapshots.tsv` 和可选的 `door.log`，原文来自各自归档。实时状态来自 `status.txt`，独立于历史列表。

`player add` 不写名字时，名字从 `Fake1` 开始递增。本地玩家启动时占 1 号席，名字来自 `playerName`。

`player remove <席位或名字>` 将玩家标记为离线，返回 `OK offline`，在本会话内保留原席。用 `player add` 加原名可回到同一席位。其他名字不能占用该席位，离线席位的输入会被拒绝。

`enter` 默认请求 `F_Test`，也接受 `enter F_Combat01`。游戏处理请求时会检查地图文件和 `/AllowSaveLoad=false`。已经在请求的房间时，`enter=ready` 会确认房间和英雄，无需再次加载。Steam v1.143476 没有 `F_Test.map_text`，因此请使用 `F_Combat01`。原因见 [当前卡点](blockers.md)。

## 从 PowerShell 启动测试房间

先关闭已有游戏进程。将 `$ship` 指向已装好 Hell2Modding 与本模组的游戏可执行文件目录，例如隔离测试目录。以下命令先确认房间资产，再直接启动测试房间，跳过标题画面和存档菜单。

```powershell
$ship = 'C:\Program Files (x86)\Steam\steamapps\common\Hades II\Ship'
$map = Join-Path (Split-Path $ship -Parent) 'Content\Maps\F_Combat01.map_text'
if (!(Test-Path -LiteralPath $map -PathType Leaf)) {
    throw "Missing packaged map: $map"
}
if (Get-Process Hades2 -ErrorAction SilentlyContinue) {
    throw 'Close the existing Hades II process before launching the test room.'
}
.\tools\h2t.ps1 status
$env:SteamAppId = '1145350'
Start-Process -FilePath (Join-Path $ship 'Hades2.exe') -WorkingDirectory $ship -ArgumentList @(
    '/DirectLoad=F_Combat01', '/DirectLoadShell=false', '/AllowSaveLoad=false', '/RequireFocusToUpdate=false'
)
```

启动后用 `status` 确认 `map=F_Combat01` 和英雄 ID，然后执行：

```powershell
.\tools\h2t.ps1 player add
.\tools\h2t.ps1 enter F_Combat01
.\tools\h2t.ps1 play
.\tools\h2t.ps1 status
```

`play` 读取 `%USERPROFILE%\Hades2Together\inputs.txt`。文件不存在时，会先复制仓库里的 `control/inputs.txt`。格式是 `席位 moveX moveY 秒数`，可选 `name 席位 名字`。解析出的摇杆状态通过 `Engine.PushInput` 提交。

Steam v1.143476 的 Lua 接口无法向英雄提交原生移动输入，也没有 2–4 号席的原生输入通道。实机状态显示 `play=unsupported`，席位仍可加入和移除。[输入接口验证](blockers.md)
