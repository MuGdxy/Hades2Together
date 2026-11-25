# 玩家输入

在仓库根目录运行以下命令。游戏处理 `help` 后，`status` 会显示 Lua 动作表。后两条 `input` 分别提交按住攻击和冲刺，以及松开所有动作并把移动归零。

```powershell
.\tools\h2t.ps1 help
.\tools\h2t.ps1 status
.\tools\h2t.ps1 input 1 -0.5 0 Attack1 Rush
.\tools\h2t.ps1 input 1 0 0
```

`input <seat> <moveX> <moveY> [action ...]` 每次提交一份完整的状态。席位必须已连接，轴值范围为 `[-1,1]`，动作名区分大小写，省略动作即提交零掩码。PowerShell 确认排队，Lua 校验参数并在 `status` 写回处理结果。原生适配目前返回 `ERR input unsupported …`。`enter`、`status` 和席位管理仍是独立的开发命令。

协议 V1 的唯一运行时动作表是 [src/protocol/actions.lua](../src/protocol/actions.lua)。位值依次为 `Attack1=1`、`Attack2=2`、`Attack3=4`、`Rush=8`、`Use=16`、`Shout=32`、`Select=64`、`Cancel=128`。这些名字在 Steam v1.143476 安装目录的 `Content/Scripts/MetaUpgradeCardUpgradeScreenLogic.lua` 中作为控制名出现。当前本机读回仍只采样数字方向与 `Attack1`。瞄准轴及未采集的轴用零表示，连续硬件轴读回和菜单执行有待验证。

客户端通过 `Input.frame` 构造同一种状态。权威按连接检查席位，拒绝未知位、额外字段及重复或倒序序号，再用自己的 tick 提交给 `Engine.PushInput`。本地 `input` 和 `play` 也经 `Input.frame` 提交给该引擎入口。同一席位的本地序号在两种命令间连续。播放文件继续使用 `席位 moveX moveY 秒数` 与可选的 `name 席位 名字`，格式错误或轴值越界的播放行会被跳过。
