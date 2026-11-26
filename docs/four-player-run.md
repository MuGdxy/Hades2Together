# 四人在同一权威房间战斗与领取

验收需要四条同时在线的玩家连接。权威配置为 `serve`，名册初始为空；四个 `play` 各自握手，取得一个稳定席号，用本机方向键位、Attack2 和松键驱动权威游戏。第一个获配席 1 的玩家控制原版英雄，并由本人在权威窗口完成原版奖励选择。另三席各自从其玩家连接领取。控制页供观察。

## 准备

TCP 支持单机多进程。这里选用四个独立的人工输入环境，因为正式 `play` 入口 `Game:ReadLocalInput` 从有本地英雄的游戏实例读取 `IsControlDown`。每位玩家需要自己的输入源、可同时运行的授权游戏环境、同版 Hell2Modding/ENVY 和到权威地址的 TCP 27780 连通性。四个客户端可各用一台机器；协议没有机器数限制。若多实例共机，还需各自可操作的游戏、插件目录、profile 与独立输入焦点。同一桌面的四个窗口共用键鼠不能提供四路独立操作。四人可共看权威屏幕，异地可共享该窗口。

另有一个权威游戏进程。它沿用已验证的 Windows 零售游戏、Hell2Modding 1.0.125、LuaENVY 1.2.1 和 `8A85AB29…` 加载器。权威进程启动时保持实体手柄断开，让原版识别固定虚拟通道；采集依赖现有 texlua/LuaSocket、空闲 GPU 和已验证的 Windows 游戏窗口 FFmpeg 工具。四个玩家客户端使用普通加载器。

在仓库根目录准备全新隔离目录。将地址换成访客可达的权威机 IPv4。

```powershell
$party = Join-Path $env:AGENT_SERVER_TMP 'h2t-party-session'
./tools/party/prepare.ps1 -SourceStage "$env:AGENT_SERVER_TMP/h2t-14aea73-guest-staff-live" -Out $party -Address 10.30.59.176 -CaptureHelper "$env:AGENT_SERVER_TMP/seat-owner/same-brawler-align/capture-secondary-scene.ps1"
```

准备器写入五份插件配置。在私有 `F_Combat02` 房间定义中指定普通波塞冬掉落。原版遭遇负责生成敌群、等待清场和调用 `SpawnRoomReward`。神祇是本次场景的已知条件，每人的选项和授予仍由各自的正式路径决定。

## 执行

1. 将 `clients/PlayerA` 到 `clients/PlayerD` 分给四位玩家。在各自的独立游戏安装或隔离副本中，将分配到的 `MuGdxy-Hades2Together` 安装到 `Ship/ReturnOfModding/plugins/`。保留包内原文件，启动脚本会核对字节。获准实机后各自在包目录运行下面的命令。客户端进入有本地英雄的非战斗房，并自动连接。席号以实际 welcome 为准。

   ```powershell
   ./guest.ps1 -Ship 'D:/Hades II/Ship' -ProfileDirectory 'D:/H2T/session01/guest-profile' -Run
   ```

2. 独占游戏名额就绪后，权威机在独立 PowerShell 进程执行下面的命令。同机部署时，先启动权威，再启动同机客户端。运行器检查 GPU、存档基线和 DLL，启动权威游戏窗口、只读 TCP 订阅和独立录像终端。各机用 Insert 打开加载器，查看 **My rewards** 中的席号。关闭面板回到本机游戏输入。核对四条真实连接与同房四个不同的英雄 ID。只读订阅使用另一个端口 27778。

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "$party/host.ps1" -Run
   ```

3. 四位玩家都在自己的 play 客户端靠近同批原版敌人，按住并松开 Attack2。每条玩家连接的日志保留实际发送的按键变更序号。权威端按同房、席号和 Unit 记录原版发射的 projectile、OnHit 的 victim 及快照中的敌人血量。逐人的命中归属要能对上实际发射、命中事件和敌人 ID。

4. 在同一房间完成领取后再离开。宿主与实际掉落交互，在原版菜单选一个普通新增祝福。各访客按 Insert 打开 **My rewards**，从自己当前机会显示的按钮中选择。菜单打开时玩家连接持续发送中立帧。按钮提交后先显示 Sent，权威快照中的 `consumed` 和 `choice` 表示领取结果。访客的 `heldBoons` 可另外核对对应 Unit 的名称、稀有度和层数。已支持的访客选项为普通新增的 PoseidonWeaponBoon 和 PoseidonSpecialBoon，各人只能领取实际抽到且可授予的一项。若某席没有可授予项或错过首次绑定，保留该席的实际状态。

5. 四个回执入档后在录像终端按 **q** 完成 MP4，再正常退出游戏。检查原始画面中的四人、战斗和宿主选择。各客户端的隔离 profile 保留 `player-events.txt`，含真实 welcome 席号、发送的按键序号和访客选择。核对 `stages.txt` 中的原版事件、`snapshots.tsv` 中的双方实体和四份领取、`run-output.txt` 中的录像 SHA-256、退出码与存档校验。运行器退出码只描述采集和退出。用已有历史工具发布文本，另交原始 MP4 和四份客户端记录。

   ```powershell
   ./tools/publish-run.ps1 -RunDirectory $party
   ```

## 本轮离线核对

`texlua tests/run.lua` 通过正式 play/serve 回环校验从访客按钮到该连接的授权席位、领取回执及菜单中立帧。`texlua tests/read_actors.lua "<游戏目录>/Content/Scripts"` 运行安装版 `SpawnRoomReward`，用受控原生边界核对实际返回的奖励物件和换房失效。四人完成同一场战斗和领取仍需上述实机记录。
