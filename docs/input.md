# 玩家输入

在仓库根目录运行以下命令。使用可重建的一席采样器时，先在 `status` 确认 `hostInput=ready`。第一条输入提交移动和 Attack2，看到对应 `appliedSeq` 后单独提交显式零。构建与启动条件见[一席原版输入采样器](../native/host-input/README.md)。

```powershell
.\tools\h2t.ps1 help
.\tools\h2t.ps1 status
.\tools\h2t.ps1 input 1 -0.5 0 Attack2
.\tools\h2t.ps1 status
.\tools\h2t.ps1 input 1 0 0
```

`input <seat> <moveX> <moveY> [action ...]` 每次提交一份完整的状态。席位必须已连接，轴值范围为 `[-1,1]`，动作名区分大小写，省略动作即提交零掩码。PowerShell 确认排队，`OK input 1` 表示原生提交端收件，`appliedSeq` 表示最近完整原版采样批次采用的序号。一个批次只采用当时最新的有效状态，同批排队的按下与松开可能只采到松开。

每个已绑定的席位支持移动两轴、`Attack1`、`Attack2` 和显式零，瞄准轴须为零。每份输入的租约上限为 500 毫秒。`input` 使用名册中的逻辑席号；例如会话容量至少为五时，脚本可只声明 `name 5 Fifth` 并向 5 号席发送移动，2–4 号席保持空缺。用 `status` 查看该席的实际角色 ID、就绪状态和回执。加载器可分配的物理通道数与会话容量分别计算。未取得原生通道的席位会显示原因。

协议 V1 的唯一运行时动作表是 [src/protocol/actions.lua](../src/protocol/actions.lua)。位值依次为 `Attack1=1`、`Attack2=2`、`Attack3=4`、`Rush=8`、`Use=16`、`Shout=32`、`Select=64`、`Cancel=128`。这些名字在 Steam v1.143476 安装目录的 `Content/Scripts/MetaUpgradeCardUpgradeScreenLogic.lua` 中作为控制名出现。当前本机读回仍只采样数字方向与 `Attack1`。瞄准轴及未采集的轴用零表示，连续硬件轴读回和菜单执行有待验证。

客户端通过 `Input.frame` 构造同一种状态。权威按连接检查席位，拒绝未知位、额外字段及重复或倒序序号，再用自己的 tick 提交给 `Engine.PushInput`。本地 `input` 和 `play` 也经 `Input.frame` 提交给该引擎入口。同一席位的本地序号在两种命令间连续。播放文件继续使用 `席位 moveX moveY 秒数` 与可选的 `name 席位 名字`，格式错误或轴值越界的播放行会被跳过。
