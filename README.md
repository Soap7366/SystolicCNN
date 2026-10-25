# CNN Accelerator — 基准方案单层 Verilog 实现

入口模块是 `rtl/cnn_layer_accelerator.v`，由 `cnn_controller` 接收层参数，执行完整的
**Conv → Bias → INT8 重定标 → ReLU → 2×2 MaxPool → BRAM 写回**。

- [架构、Tile、时钟与接口说明](docs/baseline_design.md)
- [验证结果、资源与交付边界](docs/verification.md)
- [参数加载、Prep、Array、Post 逐阶段耗时](docs/timing_breakdown.md)
- [模型整数导出来源与校验值](data/manifest.json)
- `rtl/`：可综合 Verilog
- `sim/`：阵列、重定标、完整层、布线后仿真 testbench
- `scripts/`：导出、仿真、工程配置、综合及布局布线
- `build/`：工具日志、报告、DCP、布线网表及 SDF

Vivado 工程 `CNN_Accelerator.xpr` 已设置设计顶层 `cnn_layer_accelerator`、仿真顶层 `tb_layer`。
原来的空 `top.v` 保留，但不再是工程顶层。

在本目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_sim.ps1 -Test array
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_sim.ps1 -Test post
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_sim.ps1 -Test layer
& 'D:\Vivado\2023.2\bin\vivado.bat' -mode batch -source scripts/implement.tcl -log build/implementation.log -journal build/implementation.jou
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_timing_sim.ps1
```

最后一条默认执行 SDF 回标后的首 Tile 检查及 BRAM 读回；添加 `-FullLayer` 可运行耗时较长的完整 Conv1 门级仿真。
完整层的整数正确性使用上面的 `-Test layer` 验证，实际覆盖 Conv1、Conv2、Conv3 各两个样本。

移动工程后，运行 `scripts/configure_project.tcl` 更新 GUI 工程中的参数文件路径。
命令行仿真脚本自动切回工程目录，不依赖调用位置。
当前提供的是原生同步配置/存储接口；不包含 AXI、PS 软件、GAP、FC 或可下载到板卡的 bitstream。
