# Hades2Together

四个人在同一局哈迪斯 2 里打同一批怪物。权威是一个正在运行的游戏进程：主机玩家的进程，或者一台不占玩家席的专用进程。客人只发送操作，并按快照把人和怪画出来。

开发路径写在 `docs/`：

- [架构](docs/architecture.md)：已经定下的决定，以及数据怎么走。
- [模块](docs/modules.md)：每层谁加载、hack 接口、哪些文件不许碰游戏。
- [路线](docs/roadmap.md)：阶段 0 到 5 的顺序和完成标准。当前是阶段 1 的里程碑 1。
- [控制页](docs/cli.md)：游戏启动后用浏览器加入假玩家。
- [四人实机流程](docs/four-player-run.md)：四条玩家连接、同场清敌、逐席领取与录像归档。

## 测试

在仓库根目录执行：

```powershell
lua tests/run.lua
```
