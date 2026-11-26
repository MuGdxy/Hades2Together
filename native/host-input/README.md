# 原版席位输入采样器

本目录保留已在 Steam v1.143476 使用的采样、owner 校验和 Lua 注册源码。目标是 Hell2Modding 1.0.125 的 `rom.data`。原版加载器没有这些注册。需要 Windows x64、VS 2022 x64 开发环境、CMake、Ninja 和 Rust。以下命令从本仓库根目录执行，目标目录使用新的加载器检出。

```powershell
$overlay = (Resolve-Path native/host-input).Path
git clone https://github.com/SGG-Modding/Hell2Modding.git ../h2t-input-loader
git -C ../h2t-input-loader checkout --detach a80069739d1333591c7ddfb89b606d9101bd31f4
git -C ../h2t-input-loader apply --unidiff-zero "$overlay/loader.patch"
Copy-Item "$overlay/*.hpp" ../h2t-input-loader/src/lua_extensions/bindings/hades/
cmake -S ../h2t-input-loader -B ../h2t-input-loader/build -G Ninja -DFINAL=YES -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build ../h2t-input-loader/build --target Hell2Modding
```

使用隔离 Ship 目录。将构建产物 `d3d12_.dll` 作为该目录的 `d3d12.dll`，安装本仓库的普通插件及 ENVY。在启动游戏的同一进程环境设置 `$env:H2T_SAMPLER_SCRATCH_SHIP = (Resolve-Path $ship).Path`。使用 `/AllowSaveLoad=false`，进入有原版英雄的房间。采样器核对 EXE、PDB、SDL2 的固定 SHA-256 和原版采样位置，再等待空设备列表。它只绑定自己创建、经原版识别的中性 model-2 手柄。已接入其他手柄时会等待。原版加载器和只读观察模式继续使用原有路径。

第二席使用同一份加载器、原版启动选项 `/AllowControlHotSwap=false` 和插件随附的 `hack/H2TGuest.bin`。普通房间初始化完成后，`player add Guest` 保留名额。工厂从当前房间选取空闲的原版 SpawnPoints，在原版采样返回时再次检查占用，创建定向 PlayerUnit，使用原版 AssignController 建立第二个 handler。状态中出现第二席的实际 ID 和 ready 后可提交输入。两席各采六轴、十四键，各自保存连接代际和最长 500 毫秒的输入租约。

同房执行 `player remove Guest` 仅撤销该连接的样本；原版继续更新同一角色。再次执行 `player add Guest` 后，新的连接须通过自己的原版中立批次。房间释放会先撤槽并保留私有存储，直到对应的原版 UnitManager::Remove 返回、各索引确认空缺，再清理哈希、震动引用和分配。handler 由原版 PlayerManager 持有，可供下一房间复用。

同源加载器在既有实机记录 `5EqRkTn7If1y` 中取得一席 X 轴 0.8、正向位移 9、显式归零后速度 0，以及原版 Attack2 按下和武器事件。该次记录未捕获攻击释放边沿。后续聚焦测试使用带观测的加载器独立记录了显式零对应的原版释放；本目录只包含提交输入所需的源码。正常入口及回执见[玩家输入](../../docs/input.md)。
