# 本地控制页

控制页是单独的本机网页，不画在游戏画面上。游戏窗口不在前台时会停止模拟，所以页面自己一直能开。命令写在 `%USERPROFILE%\Hades2Together\commands.txt`，窗口回到前台时再执行。

先开页面：

```powershell
.\tools\h2t.ps1
```

浏览器打开 `http://127.0.0.1:27779/`。上面可以看席位、加入假玩家、按名字加入、按席位或名字移除。

不打开页面时，也可以直接排队：

```powershell
.\tools\h2t.ps1 player add
.\tools\h2t.ps1 player add "Second Melinoe"
.\tools\h2t.ps1 player remove 2
.\tools\h2t.ps1 status
```

`player add` 不写名字时，名字从 `Fake1` 开始递增。本地玩家启动时占 1 号席，名字来自 `playerName`。

这些操作只改席位。把假玩家变成世界里的单位是里程碑 2 的 `BindHero`。
