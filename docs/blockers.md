# 当前卡点

Steam v1.143476 的标题画面可以启动游戏和模组，但没有触发游戏 Lua 更新或 Hell2Modding 的 ImGui 轮询。标题画面收到的 `player add`、`enter` 和 `play` 仍在队列中，`status` 显示 `queue=waiting for game update` 和 `hero=absent`。实机测试将 `RequireFocusToUpdate` 设为 `false`，游戏开着窗口，游戏 Lua 更新、持久线程和 ImGui 回调仍都没有执行。

默认房间 `F_Test` 有 `RoomData` 定义和 `Content/Maps/bin/F_Test.thing_bin`，本机 Steam 构建缺少 `Content/Maps/F_Test.map_text`。游戏原生启动路径会用 `MapData::MapFileExists` 检查直接启动请求，缺失时会回退到会写存档的正式开局房 `F_Opening01`。因此冷启动前先检查地图文件，进图后确认 `map=F_Combat01`，见 [CLI 用法](cli.md)。`enter` 对缺少地图文件和正式开局房的请求给出错误。

## 已验证的游戏接口

Hell2Modding 1.0.125（`a80069739d1333591c7ddfb89b606d9101bd31f4`）将 `rom.game` 绑定到真实游戏全局表。`LoadMap` 在启动模组时尚未出现，执行 `Main.lua` 后可用。`LoadMap` 会在引擎加载调用前后各让出一次执行，CLI 在游戏自己的 `thread` 内调用它，并在有引擎英雄坐标时才报告 `enter=ready`。CLI 会检查 `AllowSaveLoad`，并拒绝从已经存在的其他房间重置运行状态。 [Hell2Modding 游戏 Lua 绑定](https://github.com/SGG-Modding/Hell2Modding/blob/a80069739d1333591c7ddfb89b606d9101bd31f4/src/hades2/hades_lua.hpp#L105-L220)

在隔离启动目录用 `/AllowSaveLoad=false /DirectLoad=F_Combat01 /DirectLoadShell=false /RequireFocusToUpdate=false` 实测，CLI 在游戏启动后处理了 `status`、`player add`、`enter F_Combat01` 和 `play`。英雄和 2–4 号席的引擎 ID 各不相同，`GetLocation` 返回的四组坐标均随播放变化。两个实机测试前后的三个真实 `Profile*.sav` 文件哈希一致。

## 开发约定

- 优先通过 CLI 操作游戏，优先通过 Lua 热更新迭代，优先在游戏外的控制页查看和操作开发状态。游戏内开发 GUI 的代码可以用来查游戏 API，需要操作时在 CLI 暴露对应能力。
- 保持网页服务在独立进程的 `127.0.0.1:27779`。测试进图时使用 `/AllowSaveLoad=false`，跳过存档菜单和正式开局房 `F_Opening01`。
- Lua 兼容 5.2。插件内不要用 `os.execute`。离线套件在仓库根目录执行 `lua tests/run.lua`。
- 提交作者必须是 `MuGdxy <lxy819469559@gmail.com>`。不要改 git config，用每次提交的环境变量。推送需要 Clash：`git -c http.proxy=http://127.0.0.1:7890 push`。不要 force-push `main`，除非用户明确要求。
