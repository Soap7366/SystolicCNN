# 验证记录

环境：Vivado / XSim 2023.2，xc7z020clg400-1，2026-10-25。
实现入口为 `rtl/cnn_layer_accelerator.v`；工程为根目录 `CNN_Accelerator.xpr`。

## 整数功能仿真

输入、权重、bias、multiplier 均由原始 `artifacts_int8_hnm` 文件直接转换。
来源和 SHA256 见 `data/manifest.json`，没有重新校准或量化。

| 测试 | 结果 | 覆盖 |
|---|---|---|
| tb_array | PASS | K=9/72/144，各运行两次，核对 384 个有符号 INT32 结果 |
| tb_post | PASS | bias、正负半值舍入、正负饱和、零 multiplier、ReLU、池化和写地址 |
| tb_layer | PASS | 两个样本各三层，114,688 个带 bias 累加结果及 28,672 个池化输出逐整数一致 |

日志：`build/xsim_array.log`、`build/xsim_post.log`、`build/xsim_layer.log`。
层测试还检查全部池化结果的 BRAM 读回、每个地址只写一次、非法配置、运行中复位、busy 隔离。
样本 0 使用实际上一层输出连续执行 Conv1→Conv2→Conv3；样本 1 独立装载各层，验证反向 bank 和合法非零基址。

| 层 | 输入通道→输出通道 | 单层周期 | 50 MHz 对应计算时间 |
|---|---|---:|---:|
| Conv1 | 1→8 | 304,622 | 6.09244 ms |
| Conv2 | 8→16 | 311,696 | 6.23392 ms |
| Conv3 | 16→32 | 326,976 | 6.53952 ms |

周期包含引擎内部参数加载与最终写回，不包含 host 输入装载、host 结果读回、GAP、FC。
这不是完整模型端到端帧率。Conv1 检测到 Prep/Array/Post 三阶段同时运行；各层均有 Prep/Array 和 Prep/Post 重叠。
当前串行准备和后处理限制吞吐，64 个 PE 并非每周期都有效计算。

## 布局布线静态时序

完整综合、布局、布线，包含 IBUF、OBUF 和 BUFG。
约束为 20 ns 时钟、0.2 ns uncertainty、输入输出 max=2 ns / min=0.5 ns。
没有 false-path 或 multicycle-path 例外。

| 指标 | 结果 |
|---|---:|
| 工作频率 | 50 MHz |
| 最差建立裕量 WNS | +2.892 ns |
| 最差保持裕量 WHS | +0.049 ns |
| 最差脉宽裕量 | +8.750 ns |
| 建立 / 保持违例端点 | 0 / 0 |
| 无时钟 / 未约束内部端点 | 0 / 0 |
| 缺少输入 / 输出延迟约束 | 0 / 0 |

依据：`build/timing_route.rpt`、`build/implementation_status.txt`。
100 MHz 未通过完整 I/O 时序，不作为交付频率。

最终布线资源：9,125 LUT、8,655 寄存器、7 个 BRAM Tile（6×RAMB36 + 2×RAMB18）、4 DSP、1 BUFG。
PE 乘法当前由综合器映射到 LUT；4 个 DSP 用于后处理乘法。详见 `build/utilization_route.rpt`。

## 带布线延迟仿真方法

结果：**PASS**。最大延迟 SDF 回标成功，Conv1 首 Tile 的 16 个池化值、写地址及实际 BRAM 读回全部与 golden 一致，
完整运行日志中未出现 setup/hold/recovery 时序违例。还验证了同步复位中止任务后，Feature BRAM 内容保持可读。
依据：`build/xelab_timing.log`、`build/xsim_timing_smoke.log`。

`scripts/run_timing_sim.ps1` 使用 `build/cnn_timesim.v` 和 `build/cnn_timesim.sdf`，
以 `--sdfmax` 将最大延迟回标到 `/tb_timing/dut`。
脚本要求日志明确确认回标成功，并检查 PASS 标记及任何 setup/hold/recovery 时序违例。
默认运行首个 Tile 的动态延迟检查：通过 host 装载前三行所需输入，启动完整层配置，
核对首个 Tile 的 16 次池化写回，再同步复位中止剩余计算，通过 host 读回这 16 个实际 BRAM 字节。
`timing_smoke.tcl` 只跳过 testbench 中不需要的后续输入装载，不强制 DUT 状态或 RAM。
该脚本监视当前布线网表的写使能 `post_n_22`；若修改 RTL 或重新优化导致网名变化，需更新此观测点。
完整层整数一致性由 `tb_layer` 的六次完整层运行覆盖；本次不把首 Tile SDF 检查称为完整层门级仿真。
可添加 `-FullLayer` 参数运行完整 Conv1 门级仿真与 8,192 字节读回，耗时较长；该项未完成，不计入已通过结果。
输入在外部时钟上升沿后 1 ns 驱动，符合 XDC 的 0.5～2 ns 输入延迟范围；
输出在第二次读取沿后 19 ns 采样，位于该周期输出稳定窗口内。
最小延迟保持检查同时由多角静态时序报告覆盖。

## 工程边界

本次交付是单层计算引擎，支持三个固定卷积形状，完整执行 Conv→Bias→Requant→ReLU→MaxPool。
原生同步 host 接口尚未接入 PS/AXI；不包含 GAP/FC，不生成上板 bitstream。
当前 118 个逻辑 I/O 由实现工具自动安排位置，没有板级 LOC。
因此 DRC 保留 UCIO-1（缺少用户引脚位置）及 ZPS7-1（未实例化 PS7）；另有 DSP 流水优化建议。
这些结果不能替代最终板级集成验证，不能将当前 XDC 直接作为可上板约束。
接入 PS/AXI 后应使用实际系统约束重新实现。
