# CNN Accelerator — 双任务整网 Verilog 实现

当前整网入口为 `rtl/cnn_accelerator.v`，一次 start 自动执行
**三个 Conv/Bias/重定标/ReLU/Pool → 在线 GAP → 复用阵列的两个 Linear → 两个 INT32 输出**。
使用 `artifacts_dual_task_baseline2_int8_qat/export` 的完整参数，30个样本全部对齐 golden。
最新结构、接口、控制验证和资源时序见 [整网实现报告](docs/full_network.md)。

原 `cnn_layer_accelerator.v` 默认保留单层模式；整网 wrapper 启用 `ENABLE_NETWORK=1`。

当前架构为 **8 个输出通道 × 16 个空间位置、四路并行 Post**。
当前 Prep 已改成按列流式读取，每块 Feature BRAM 分为四个行 bank，同拍返回四行的一列，直接推进滑窗。
先验证单路按列版本，再实现四路读取；[本次结构、性能与验证记录](docs/column_stream_optimization.md)。
此前的[阵列与 Post 优化记录](docs/array_8x16_optimization.md)保留为历史对比。

- [架构、Tile、时钟与接口说明](docs/baseline_design.md)
- [验证结果、资源与交付边界](docs/verification.md)
- [参数加载、Prep、Array、Post 逐阶段耗时](docs/timing_breakdown.md)
- [模型整数导出来源与校验值](data/manifest.json)
- [双任务 baseline_2 QAT：兼容性与 30 个样本的实际三层串接验证](docs/dual_task_baseline2_qat_verification.md)
- `rtl/`：可综合 Verilog
- `sim/`：阵列、重定标、完整层、布线后仿真 testbench
- `scripts/`：导出、仿真、工程配置、综合及布局布线
- `build/`：工具日志、报告、DCP、布线网表及 SDF

Vivado 工程 `CNN_Accelerator.xpr` 已设置设计顶层 `cnn_accelerator`、仿真顶层 `tb_network`。
原来的空 `top.v` 保留，但不再是工程顶层。

在本目录运行：

```powershell
& 'D:\programm\anaconda\envs\vision_attention\python.exe' scripts/export_dual_qat_vectors.py
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_sim.ps1 -Test network
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_sim.ps1 -Test gap
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_sim.ps1 -Test linear
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_sim.ps1 -Test control
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_sim.ps1 -Test array
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_sim.ps1 -Test post
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_sim.ps1 -Test memory
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_sim.ps1 -Test layer
& 'D:\programm\anaconda\envs\vision_attention\python.exe' scripts/capture_network_inputs.py
& 'D:\Vivado\2023.2\bin\vivado.bat' -mode batch -source scripts/implement_full_network.tcl -log build/full_network/implementation.log -journal build/full_network/implementation.jou
& 'D:\programm\anaconda\envs\vision_attention\python.exe' scripts/verify_full_network.py
```

完整整网为65116拍，按50 MHz为1.30232 ms，不含host传输和PS反量化。布局布线通过50 MHz时序；20,017 LUT、18,191 FF、6.5 BRAM Tile、20 DSP。
当前整网尚未执行动态SDF。`run_timing_sim.ps1` 保留为旧单层版本入口，不是当前整网SDF验证。
host连续引脚级写入的既有验证限制见历史验证报告；本次没有将RTL仿真当成板级接口验证。
`-Test layer` 是原HNM两样本六层回归；`-Test network` 才是30个QAT样本、GAP和双FC全部由RTL执行的整网验证。

移动工程后，运行 `scripts/configure_project.tcl` 更新 GUI 工程中的参数文件路径。
命令行仿真脚本自动切回工程目录，不依赖调用位置。
当前提供原生同步输入存储及结果接口，已包含整数GAP和双FC；不包含AXI、PS软件或可下载到板卡的bitstream。
