# 四人在同一权威房间战斗与领取

一个 `serve` 游戏提供原版世界、角色、菜单和游戏窗口。四个独立 CLI 玩家各自向 TCP 27780 握手，从 welcome 取得稳定席号。首席控制原版英雄，其余三席控制各自绑定的 Unit。四个 CLI 可在同一台机器运行，每个只需要 texlua、LuaSocket 和到权威的 TCP 连接。游戏内操作方式仍可使用 `guest.ps1` 与本地英雄；只读订阅使用 27778，不占玩家席位。

## 准备

在仓库根目录准备全新的隔离目录。同机用回环地址，分机时使用玩家可达的权威 IPv4。

```powershell
$party = Join-Path $env:AGENT_SERVER_TMP 'h2t-party-session'
./tools/party/prepare.ps1 -SourceStage "$env:AGENT_SERVER_TMP/h2t-14aea73-guest-staff-live" -Out $party -Address 127.0.0.1 -PlayerLoader "$env:AGENT_SERVER_TMP/player-cli-use-build/d3d12.dll" -CaptureHelper "$env:AGENT_SERVER_TMP/seat-owner/same-brawler-align/capture-secondary-scene.ps1"
```

权威机使用 Windows 零售版、Hell2Modding 1.0.125、LuaENVY 1.2.1 和支持首席 V1 `Use` 的加载器。准备器和运行器核对 DLL 哈希。启动时保持实体手柄断开，让原版识别固定虚拟通道。采集使用现有精确窗口 FFmpeg 工具。在私有 `F_Combat02` 定义中指定普通波塞冬掉落，原版遭遇生成敌群，清场后调用 `SpawnRoomReward`。每人的候选取自本席实际机会。

## 执行

1. 获准使用空闲 GPU 后，在权威机独立终端运行 `powershell -NoProfile -ExecutionPolicy Bypass -File "$party/host.ps1" -Run`。它启动禁存档游戏、只读快照订阅和录像终端。
2. 权威开始监听后，在四个终端分别运行各包的玩家入口。下例为第一个终端，其余将 PlayerA 改成 PlayerB、PlayerC、PlayerD。玩家也可在各自机器运行收到的包。每个终端输出的 `joined` 行给出实际席位。`status` 显示本机 `seat`、`sentSeq` 及最新权威快照，角色和领取行均带席号。四个角色都应在奖励首次生成前绑定。

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "$party/clients/PlayerA/player.ps1"
   ```

3. 每位玩家在自己的终端输入 `input <x> <y> [动作 ...]`。移动与攻击示例为 `input 0.8 0` 和 `input 0 0 Attack2`，松开为 `input 0 0`。每条是完整样本，原生租约上限 500 ms。按下和显式零分开发送，给原版采样留出时间。同一批次只会采用最新状态。`sent_input` 记录本连接已发送的序号。战斗结果核对权威同房的原版发射、弹体、OnHit、敌人 ID 和实际 HP。
4. 清场后，首席通过移动靠近原版可交互掉落，输入 `input 0 0 Use`，看到原版交互后发 `input 0 0`。原版菜单等待输入时，`status` 才显示首席可以提交的按钮。每个玩家从自己席位的 `opportunity` 和 `grantOptions` 选一个，命令形如 `boon 1/1/1 PoseidonWeaponBoon`。实际机会和选项以快照为准。普通新增访客祝福支持 PoseidonWeaponBoon 和 PoseidonSpecialBoon。宿主请求交给原版菜单协程和授予函数。客户端显示 `sent_boon` 后，再用 `status` 核对本席 `state=consumed choice=...` 和实际持有。某席错过资格、没有可授予项或请求被拒时，保留该席的实际结果。 隔离运行器使用原版选项 `/AutoAdvanceNarration=true`，有台词时由 `AutoAdvanceNarration` 等语音结束并推进普通对白。叙事分支仍由原版处理。
5. 每个玩家入口会打印自己的 `Player log` 路径，文件保留本席的发送记录和查询到的权威状态。四条权威领取回执入档后，录像终端按 **q** 完成 MP4，各玩家输入 `quit`，正常退出权威游戏。核对原视频、`stages.txt` 的发射及命中、`snapshots.tsv` 的实体及领取、`run-output.txt` 的退出码、视频哈希及存档。运行器退出码描述采集及退出。用 `./tools/publish-run.ps1 -RunDirectory $party` 发布历史文本，另交原始 MP4 和玩家记录。

## 接口验证

`texlua tests/run.lua` 覆盖正式 play/serve 连接、席位代际和权威回执。`texlua tests/read_actors.lua "<游戏目录>/Content/Scripts"` 加载安装版 Lua，从原版菜单等待输入，经按钮派发、宿主授予，核对同一实际返回实例和 consumed 投影。该回放的原生交互和按钮布局为夹具。四名玩家在同一真实遭遇共战并各自领取仍需一次完整录像和权威记录。
