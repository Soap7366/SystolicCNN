# 验证记录

环境：Vivado / XSim 2023.2，xc7z020clg400-1。当前 Prep 优化验证更新于 2026-10-26。
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
| Conv1 | 1→8 | 304,507 | 6.09014 ms |
| Conv2 | 8→16 | 157,456 | 3.14912 ms |
| Conv3 | 16→32 | 97,408 | 1.94816 ms |

周期包含引擎内部参数加载与最终写回，不包含 host 输入装载、host 结果读回、GAP、FC。
三层合计 559,371 拍，按 50 MHz 为 11.18742 ms。这不是完整模型端到端帧率。
三层均检测到 Prep/Array/Post 同时运行；当前主要受单路后处理限制，64 个 PE 并非每周期都有效计算。
2026-10-26 的 Prep 优化已通过两个样本的全部逐层整数检查，另增加了实际读请求/返回在途复位、窗口对写入数量、Mapper ic/tap 对齐检查。
优化前后周期及逐状态对比见 `docs/timing_breakdown.md`。

## 布局布线静态时序

完整综合、布局、布线，包含 IBUF、OBUF 和 BUFG。
约束为 20 ns 时钟、0.2 ns uncertainty、输入输出 max=2 ns / min=0.5 ns。
没有 false-path 或 multicycle-path 例外。

| 指标 | 结果 |
|---|---:|
| 工作频率 | 50 MHz |
| 最差建立裕量 WNS | +3.857 ns |
| 最差保持裕量 WHS | +0.050 ns |
| 最差脉宽裕量 | +8.750 ns |
| 建立 / 保持违例端点 | 0 / 0 |
| 无时钟 / 未约束内部端点 | 0 / 0 |
| 缺少输入 / 输出延迟约束 | 0 / 0 |

依据：`build/timing_route.rpt`、`build/implementation_status.txt`。
100 MHz 未通过完整 I/O 时序，不作为交付频率。

当前布线资源：9,627 LUT、8,507 寄存器、7 个 BRAM Tile（6×RAMB36 + 2×RAMB18）、4 DSP、1 BUFG。
相对优化前增加 502 LUT，减少 148 寄存器，BRAM/DSP 数量不变。逻辑存储容量没有增加。
最终实现通过 `scripts/pre_opt.tcl` 保留权重 ROM 原始使能，避免自动 BRAM 省电改写产生的 SDF 保持违例；
GUI impl_1 和命令行实现都应用该设置，未增加时序例外。相关工具设置参考 [AMD set_power_opt](https://docs.amd.com/r/en-US/ug904-vivado-implementation/power_opt_design?contentId=P_h3wRukZWPi5GyicDD31g)。
PE 乘法当前由综合器映射到 LUT；4 个 DSP 用于后处理乘法。详见 `build/utilization_route.rpt`。

## 带布线延迟仿真方法

当前优化版结果：**PASS（2026-10-26）**。排除自动 ROM 省电使能改写后，最终最大延迟 SDF 回标成功；
Conv1 首 Tile 的 16 个池化值、写地址和实际 BRAM 读回均与 golden 一致，整个最终运行日志中没有 setup/hold/recovery 时序违例。
同步复位中止任务后，Feature BRAM 内容保持可读。首次带告警的中间记录保存在 `build/timing_smoke_before_rom_power_fix.log`，不计入通过结果。
依据：`build/xelab_timing.log`、`build/xsim_timing_smoke.log`。

`scripts/run_timing_sim.ps1` 使用 `build/cnn_timesim.v` 和 `build/cnn_timesim.sdf`，
以 `--sdfmax` 将最大延迟回标到 `/tb_timing/dut`。
脚本要求日志明确确认回标成功，并检查 PASS 标记及任何 setup/hold/recovery 时序违例。
默认运行首个 Tile 的动态延迟检查：通过 host 装载前三行所需输入，启动完整层配置，
核对首个 Tile 的 16 次池化写回，再同步复位中止剩余计算，通过 host 读回这 16 个实际 BRAM 字节。
`timing_smoke.tcl` 只跳过 testbench 中不需要的后续输入装载，不强制 DUT 状态或 RAM。
该脚本查找目的 Feature BRAM 的实际写使能 `feature_memories[1].wr`，避免依赖不稳定的综合临时网名。
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
