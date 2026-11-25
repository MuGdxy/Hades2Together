# 本地控制页

控制页是单独的本机网页。游戏收到更新回调时，会从 `%USERPROFILE%\Hades2Together\commands.txt` 取走命令。标题画面在已测试的 Steam 构建上没有触发该回调，切换窗口焦点无法替代进图。

先开页面：

```powershell
.\tools\h2t.ps1
```

浏览器打开 `http://127.0.0.1:27779/`。上面可以看席位、加入假玩家、按名字加入、按席位或名字移除。

不打开页面时，也可以直接排队：

```powershell
.\tools\h2t.ps1 enter
.\tools\h2t.ps1 player add
.\tools\h2t.ps1 player add "Second Melinoe"
.\tools\h2t.ps1 player remove 2
.\tools\h2t.ps1 status
```

`h2t.ps1 status` 显示最近一批命令的确认。看到 `queue=waiting for game update` 时，队列文件仍在等待游戏处理。最后一行的 `hero=absent` 表示游戏里还没有可用的英雄。实际地图由游戏的 `CurrentRun` 提供，英雄的 `x`、`y` 由引擎的 `GetLocation` 提供。`2:Fake1:unsupported` 表示席位已加入，但没有可用的原生玩家输入槽。

`player add` 不写名字时，名字从 `Fake1` 开始递增。本地玩家启动时占 1 号席，名字来自 `playerName`。

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
