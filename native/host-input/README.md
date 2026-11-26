# 一席原版输入采样器

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

一次进程支持一个房间 owner。原版 World、Player、Unit、handler、手柄句柄和实例必须持续匹配。每个原版批次读取六个轴和十四个按钮。接收时间使用游戏线程的单调时钟，同一序号不会刷新 500 毫秒租约。切图、换人或撤销后，本版需要新进程重新绑定。二席实验的 `h2t_probe_pair_movement_submit` 和 `h2t_probe_staff_attack_submit` 依赖实验发布的第二个 Player、generation、各席 session 及限定阶段。正式二席仍需可跨普通房间获取、发布、撤销和回收该原生 owner 的接口，以及对两个原版 handler 分别采样的提交端。

同源加载器在既有实机记录 `5EqRkTn7If1y` 中取得一席 X 轴 0.8、正向位移 9、显式归零后速度 0，以及原版 Attack2 按下和武器事件。该次记录未捕获攻击释放边沿。后续聚焦测试使用带观测的加载器独立记录了显式零对应的原版释放；本目录只包含提交输入所需的源码。正常入口及回执见[玩家输入](../../docs/input.md)。
