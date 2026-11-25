# 本地控制页

控制页是单独的本机网页，不画在游戏画面上。游戏窗口不在前台时会停止模拟，所以页面自己一直能开。命令写在 `%USERPROFILE%\Hades2Together\commands.txt`，窗口回到前台时再执行。

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

`h2t.ps1 status` 最后一行是角色有没有进到世界里。`hero=absent` 表示还在主菜单，游戏里还没有英雄。`2:Fake1:spawned=<id>` 表示这个席位已经在英雄旁边生成了一个身体。

`player add` 不写名字时，名字从 `Fake1` 开始递增。本地玩家启动时占 1 号席，名字来自 `playerName`。

`enter` 的意图是不经过存档栏，直接加载 `F_Test`。这间房不是正式开局房，游戏会跳过存档写入，不会覆盖现有存档。也可以写 `enter F_Combat01` 换一张图。这一步目前失败：插件 Lua 里没有 `LoadMap`，`status` 停在 `enter=waiting`。原因见 [blockers.md](blockers.md)。

`play` 读取 `%USERPROFILE%\Hades2Together\inputs.txt`。文件不存在时，会先复制仓库里的 `control/inputs.txt`。格式是 `席位 moveX moveY 秒数`，可选 `name 席位 名字`。四个席位按这个序列走动：移动时播跑步动画，停下播待机，面朝移动方向。1 号是真正的英雄，2 到 4 号是同一套梅利诺埃模型。

进入世界前，最后一行是 `bodies hero=absent`。`enter` 被游戏执行后，额外席位应变成 `spawned=<id>`，坐标会随 `play` 变化。窗口不在前台时命令会先排队。
