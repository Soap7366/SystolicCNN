# 验证记录：8×16 阵列与四路 Post

环境：Vivado / XSim 2023.2，xc7z020clg400-1，50 MHz。更新于 2026-10-26。
入口：`rtl/cnn_layer_accelerator.v`；工程：`CNN_Accelerator.xpr`。
两步实施顺序、结构和详细耗时见 [优化记录](array_8x16_optimization.md)。

## 整数功能仿真

权重、bias、multiplier、输入和逐层 golden 均来自原始 `artifacts_int8_hnm`，没有重新校准或量化。
`data/manifest.json` 的 23 个来源文件 SHA256 已全部核对。
另向独立目录 `build/golden_reexport_8x16/` 重新导出，所有 golden/参数 HEX 与 `data/` 逐文件哈希一致。

| 测试 | 结果 | 覆盖 |
|---|---|---|
| tb_array | PASS | K=9/72/144 各两次，逐项核对全部 768 个 INT32，包含正负激活/权重和 16 列错拍 |
| tb_post | PASS | 四次完整 Tile，每次 128 个 bias 结果、128 个 ReLU 前量化结果、32 个池化结果及地址；正负半值、饱和、零乘数、通道参数、各 lane 最大值、在途复位、busy 重复 start、完成后无残留 |
| tb_layer | PASS | 两个样本各三层，114,688 个带 bias 累加结果、28,672 个池化输出及全部 BRAM 回读逐项一致 |

日志：`build/xsim_array.log`、`build/xsim_post.log`、`build/xsim_layer.log`。
样本 0 使用实际 RTL 上一层输出连续运行 Conv1→Conv2→Conv3，不重装中间输入。
样本 1 独立装载，检查反向 BRAM 和合法非零基址。
层测试检查每个地址唯一、覆盖完整、非法配置、运行中复位、读请求/返回在途复位、busy 隔离、窗口写入数量及 Mapper ic/tap 对齐。
Post 每次连续读取 32 个四值组，量化组 II=1，池化写入 II=1；从启动到末次写入提交 41 拍，含调度交接 42 拍。
最后一次实际写入提交后才释放 Output Buffer，保留双缓冲的所有权规则。

| 层 | 单层周期 | 按 50 MHz 换算 |
|---|---:|---:|
| Conv1 | 14,730 | 0.29460 ms |
| Conv2 | 60,498 | 1.20996 ms |
| Conv3 | 74,820 | 1.49640 ms |
| 合计 | 150,048 | 3.00096 ms |

周期包含内部参数加载和最终写回，不含 host 输入/回读、GAP、FC；不是板卡实测或完整模型端到端帧率。
三层吞吐约 333.23 次/s、1.76891 GOPS，按 128 PE 计算的有效 MAC 利用率约 13.82%。
阵列翻倍后峰值为 12.8 GOPS，有效利用率与此前 64 PE 的百分比不能直接作为绝对吞吐比较。
三层 Array 等待结果空 bank 的计数均为零，当前主要受 Prep 限制。

## 先后顺序与第一步留档

先实现 8×16 + 单路 Post，完成阵列、Post 和六次完整 CNN 检查，再完成 50 MHz 布局布线。
第一步 WNS +3.391 ns、WHS +0.040 ns，18,078 LUT、16,184 FF、7 BRAM Tile、4 DSP。
第一步 Conv1 的 Array 为 34 拍/Tile，Post 为 137 拍/Tile，确认满足用户条件后才开始四路 Post。
源码、仿真日志、报告和 routed DCP 位于 `build/array_8x16_single_post/`。
第一步未单独执行 SDF 动态仿真；最终版本另外执行 SDF 检查。
改动前 8×8 的源码和主要日志/资源结果保存在 `build/before_array_8x16/`。

## 最终布局布线静态时序

完整综合、布局、布线，包含 IBUF/OBUF/BUFG；20 ns 时钟、0.2 ns uncertainty、输入输出 max=2 ns / min=0.5 ns。
没有 false-path 或 multicycle-path 例外。

| 指标 | 结果 |
|---|---:|
| WNS | +2.139 ns |
| WHS | +0.049 ns |
| LUT | 18,728（35.20%） |
| FF | 16,532（15.54%） |
| BRAM Tile | 7（5.00%，6×RAMB36 + 2×RAMB18） |
| DSP | 16（7.27%） |

依据：`build/array_8x16_post4_implement.log`、`build/timing_route.rpt`、`build/implementation_status.txt`、`build/utilization_route.rpt`。
PE 乘法由综合器映射到 LUT，16 个 DSP 用于四路后处理重定标乘法。
相对第一步单路 Post，最终版本增加 650 LUT、348 FF、12 DSP，BRAM 数量不变。
`scripts/pre_opt.tcl` 保留 Weight ROM 原始使能，防止自动省电重写；GUI impl_1 和命令行实现均应用该设置。

## 布线延迟仿真

最终版本 SDF 动态检查：**PASS**。最大延迟回标成功，27 个实际输入字节核验、32 个池化写入和全部 32 字节 BRAM 回读均与 golden 一致，日志无建立/保持/恢复时序违例。
依据：`build/xelab_timing.log`、`build/xsim_timing_smoke.log`。复用同一最终回标快照运行；第一次检查因综合删除顶层信号别名而停止，脚本改用连接 BRAM 的 Post 写端口后重跑通过，DUT 未改动。
`scripts/run_timing_sim.ps1` 以 `--sdfmax` 回标最终 `cnn_timesim.v` / `cnn_timesim.sdf`，检查明确的回标成功消息、锚定 PASS 标记和时序违例。
默认首 Tile 检查在计算前通过 host 读回确认 27 个非 padding 输入字节，核对 32 个池化写入，再同步中止层并读回这 32 个实际 BRAM 字节。
脚本仅控制 testbench 激励，不强制 DUT 状态或 RAM；观察实际目的 RAM 写使能和连接到 RAM 的 Post 写地址/数据端口，并核对实际 BRAM 回读。
`-FullLayer` 可执行完整 Conv1 门级仿真；该项未运行，不计入已通过覆盖。三层完整整数覆盖由 RTL 仿真提供。

已有 host 引脚级限制仍保留：此前连续每拍改变地址/数据的旧 SDF 写入出现相邻地址数据对换。
本次 SDF 使用地址/数据先稳定一拍、写使能一拍、撤销后保持一拍的装载协议，并核验实际输入。
RTL 连续写入检查通过不能证明连续引脚级写入通过；接入 PS/AXI 时仍需专门验证该接口。

## 工程边界

支持三个固定卷积形状的 Conv→Bias→Requant→ReLU→MaxPool；GAP、FC、PS/AXI、bitstream 和上板测试未实现。
118 个逻辑 I/O 没有板级 LOC，由工具自动安排以检查完整 I/O 时序。
DRC 中 UCIO-1（缺少用户引脚位置）、ZPS7-1（未实例化 PS7）及 DSP 流水建议不能视为板级集成已完成；最终集成需使用真实系统约束重新实现。
