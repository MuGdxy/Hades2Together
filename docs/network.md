# 本机 TCP 五进程验证

从仓库根目录执行：

```powershell
lua tests/run.lua
python tests/net_smoke.py --lua lua
```

第一条命令使用 Lua 5.2 或以上版本。第二条命令使用 Python 3 和可执行 `require("socket")` 的 Lua，例如安装了 LuaSocket 的 Lua 5.2.4。使用 LuaRocks 时可为同一 Lua 版本执行 `luarocks --lua-version 5.2 install luasocket`。若使用自带 LuaSocket 的 MiKTeX `texlua`，对应命令为：

```powershell
texlua tests/run.lua
python tests/net_smoke.py --lua texlua
```

也可通过 `--lua C:\path\to\lua.exe` 指定解释器，并按该解释器的 ABI 用 `LUA_PATH` 和 `LUA_CPATH` 查找对应的模块。Hell2Modding 1.0.125 会预加载原生 `socket.core` 和 `require("socket")` 的 Lua 包。其 `rom["socket.core"]` 也是核心表入口。独立验证使用同一公开 LuaSocket API 注入连接，已用 Lua 5.2.4 和加载器固定的 LuaSocket 源码运行。见 [加载器绑定](https://github.com/SGG-Modding/Hell2Modding/blob/a80069739d1333591c7ddfb89b606d9101bd31f4/src/lua_extensions/bindings/luasocket/luasocket.cpp)、[预加载入口](https://github.com/SGG-Modding/Hell2Modding/blob/a80069739d1333591c7ddfb89b606d9101bd31f4/src/lua_extensions/bindings/luasocket/luasocket_scripts.cpp#L2327-L2353) 和 [LuaSocket 固定版本](https://github.com/SGG-Modding/Hell2Modding/blob/a80069739d1333591c7ddfb89b606d9101bd31f4/cmake_scripts/luasocket.cmake#L5-L10)。

脚本启动一个 `serve`（零个本地玩家席）和四个独立的 `play` 进程，在 `127.0.0.1` 的临时端口通信。它打印进程 ID、服务器实际接收的输入及分配的席位和 tick，并比对权威和四个客户端看到的同一敌人 ID、HP 和裁决。测试还检查第五人、在线重名、重复和过期序号、冒用席位、无效输入、断开，以及同名重连后的一次快照启动。

各测试客户端从自己的命令行参数取输入。测试权威使用 `hack/fake.lua` 和显式的伤害、移除、动作状态夹具。五进程用例验证传输、会话和状态投影。下述正式插件入口另有真实 TCP 与游戏接口回放。

房间切换和逐席原版奖励的快照契约使用单独的 `--stock-room` 夹具。见 [房间通行与原版奖励](room-rewards.md)。

## 接入约定

### 正式插件的远端输入

在权威游戏的 `config.lua` 设置 `role="serve"`，或使用默认的 `"serve+play"` 为本机玩家保留第一席。两种模式都保留普通 CLI。跨机使用时，将 `bindAddress` 设为权威机器的局域网 IPv4 地址。客户端设置 `role="play"`、相同的 `serverAddress`、`playerPort` 和自己的唯一 `playerName`。修改启动配置后重启插件所在进程。玩家端口默认 27780，默认地址为本机回环。原有只读订阅继续使用 `port`（默认 27778）及独立名册。

收到 `welcome` 后，客户端按约 20 Hz 读取本机四个方向和 `Attack1`、`Attack2` 的按住态，松开后发送零值。权威端使用该连接获配的席号，调用 CLI 共用的 `Game:SubmitInput`。协议序号在每次连接内递增，提交给原版的序号由权威端逐席分配。断线保留名册与房内角色，同名重连建立新的连接代际。

客户端插件的 `public.getRemoteSnapshot()` 返回最近一份完整权威快照及当前获配席号。控制目录的 `status.txt` 在 `control=play` 下提供 `connection`、`seat`、`sentSeq`、快照 `tick`、角色及最近一次 `reason`。`sentSeq` 表示连接已发送的帧；实际原版消费序号仍以权威端角色回执为准。控制页用这份快照展示权威端报告的状态。

访客可从快照 `room.rewards[].claims[]` 找到 `playerId` 等于获配席号的记录。从该记录的 `grantOptions` 选取一项 `option`，调用 `public.chooseRemoteBoon(claim.opportunity, option)`。当前支持普通新增的 `PoseidonWeaponBoon` 和 `PoseidonSpecialBoon`。旧快照可用单值 `grantOption`；新快照继续提供该字段。玩家端口发送 `{t="boon", opportunity="房间/奖励/轮次", option="PoseidonWeaponBoon"}`，权威端在执行时按连接绑定的席号与代际复核。返回 `true` 表示已提交发送；领取成功以随后权威快照中本席的 `state="consumed"` 和 `choice` 为准。权威拒绝通过现有 `error` 消息返回原因。同名重连后从新连接的快照恢复，play 和 observer 控制页保持只读。

执行 `texlua tests/run.lua` 可用 LuaSocket 回环和模拟游戏边界重放正式启动、分席、采样、选择祝福、回传及重连。

插件启动时从 `config.maxPlayers` 设置会话容量，默认四席。独立权威可通过 `Server.listen` 的 `options.maxPlayers` 设置同一容量。客户端从 `welcome.maxPlayers` 读取容量，历史握手省略该字段时沿用四席。CLI 和回放脚本使用会话容量校验席号；回放脚本可以只指定第五席，空席保留。实机可用角色及输入通道由原生适配层确认。

- `Server.listen(socket, port, engine, options)` 创建专用权威；设置 `port=0` 可由系统分配端口，然后读取 `server:port()`。初始化期间使用 `server:poll()` 完成入席，准备好后由调用方按权威 tick 调用 `server:step()`。
- `Client.connect(socket, port, name)` 发起连接并排入握手。随后用 `client:poll()` 取消息。收到服务器的 `welcome` 后，用 `client:sendInput(state)` 提交当前玩家的方向、按键和瞄准状态。服务器按连接绑定席位、要求递增序号并在进入权威循环时指定输入 tick。关闭连接调用 `close()`。断开时释放连接，保留名字对应的席位及权威角色；本机验证按名字恢复席位。
- 每帧是 4 字节大端长度加一条 `Codec` 消息，正文上限为 64 KiB。读取和写入可跨多次轮询，接入、每轮解码和发送缓冲都有上限。握手有时限，慢连接的发送队列满时关闭连接。
- `Snapshot` 在同一权威 tick 携带完整的英雄和敌人记录数组；记录内带自己的 ID。客户端用 `client.snapshot` 取得当前完整视图。更新用整份快照替换视图，缺席对象随之移除，重复和过期 tick 不改变视图。重连只需要一份新快照，无需前序状态、裁决或确认。增量传输留作后续优化。
- `ReadActors` 负责完整投影当前同步范围内的游戏状态，例如位置、朝向、HP、动作及阶段、动作实例标识和可见奖励，字段以实际引擎能力为准。正式客户端由 `ApplySnapshot` 应用投影；同一动作实例反复出现在快照时，应维持已有动画进度。按键表示意图，`decisions` 事件提供裁决通知，持久状态由快照提供。

## 实机只读观察模式

在测试安装的 `src/config.lua` 对应插件文件中设 `observerSnapshots = true` 后重启。用 [CLI 安全启动方式](cli.md) 进入 `F_Combat01`。模式使用固定版本 Hell2Modding 1.0.125 预加载的 `require("socket")`，在 `127.0.0.1` 监听 `port`，`port = 0` 时读取加载器日志中的实际端口。每次轮询都有连接、收发与队列上限，快照随游戏更新发布，上限约 20 Hz。Lua 热更新保留原监听器、连接和 tick，游戏进程退出时释放套接字。观察模式配置、启动协调器或服务端传输代码更改后需重启；`Game:ReadActors()` 等运行模块的改动可热更新。

外部进程通过 `Client.connect(socket, port, name)` 和 `Client:poll()` 接收完整状态，观察连接容量由 `config.maxPlayers` 设置。同名断开重连沿用席位，并从下一份完整快照恢复。观察模式使用 `Game:ReadActors()`，输入消息会被拒绝，游戏内的 CLI 动作队列暂停处理。实机验证观察到一个原生英雄和原版遭遇；观察席仅用于网络连接。

从仓库根目录运行 `texlua tests/observer.lua` 检查只读传输、输入拒绝和重连。房间及门的读取范围和实机证据见 [实机只读投影](room-rewards.md#实机只读投影)。

## 在权威 CLI 上订阅快照

在游戏插件的 `config.lua` 中保留 `observerSnapshots = false`，设置 `cliSnapshots = true` 并重启。适用于 `serve` 和 `serve+play`，默认关闭。CLI 每次游戏更新照常处理命令并更新控制页。同一个 `Game` 实例在处理命令后提供约 20 Hz 的完整只读快照。监听仍使用 `127.0.0.1:port`。连接的 `welcome` 编号只用于订阅会话，订阅者不会进入 CLI 玩家名册，发送的输入会被拒绝。仅观察模式下仍由 `observerSnapshots` 管理状态文件和更新回调。

启动权威进程后，可从仓库根目录用已安装 LuaSocket 的 Lua 读取一份快照。若配置了临时端口，将示例端口换成加载器日志报告的端口。

```powershell
@'
package.path = "src/?.lua;" .. package.path
function import(path)
  return require((path:gsub("%.lua$", ""):gsub("/", ".")))
end
local socket = require("socket")
local client = assert(import("client/connection.lua").connect(socket, 27778, "Reader"))
local deadline = socket.gettime() + 2
while not client.snapshot and socket.gettime() < deadline do
  local _, err = client:poll()
  assert(not err, err)
  socket.sleep(0.01)
end
local snapshot = assert(client.snapshot, "snapshot timeout")
client:close()
print(assert(import("protocol/codec.lua").encode(snapshot)))
'@ | lua -
```

`texlua tests/run.lua` 包含 CLI 与 TCP 订阅共存的回归测试，覆盖本地输入、远端输入拒绝、完整快照、热更新和订阅连接保留。
