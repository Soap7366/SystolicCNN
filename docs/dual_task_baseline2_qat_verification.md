# baseline_2 QAT 双任务 CNN：现有架构兼容性与实际 RTL 验证

> 本文保留“仅CNN主干RTL＋软件GAP/FC”的历史验证。当前已完成GAP和双Linear的整网RTL，最新结果见 [整网实现报告](full_network.md)。

导出来源：`D:\Workspace\FPGA_CNN\artifacts_dual_task_baseline2_int8_qat\export`。

结论：这份模型的三个卷积块可直接使用现有 8×16 阵列、四 bank Feature BRAM 和四路 Post。计算 RTL 没有修改，仅转换已导出整数的存储格式，增加独立参数文件和测试入口。全部 30 个 golden 样本完成实际三层串接并逐项通过。

## 结构和数值格式

| 项目 | QAT 导出 | 现有架构 |
|---|---|---|
| 输入 | batch=1、1×64×64、灰度 INT8 | 支持 |
| Conv1 | 1→8，64×64，3×3/s1/p1 | 支持 |
| Conv2 | 8→16，32×32，3×3/s1/p1 | 支持 |
| Conv3 | 16→32，16×16，3×3/s1/p1 | 支持 |
| 每层后处理 | Bias→逐通道重定标→ReLU→2×2/s2 Pool | 支持 |
| BN | 已融合；结构中的 BN 为 Identity | 无需增加算子 |
| 激活、权重 | INT8，zero-point=0，[-127,127] | 一致 |
| bias、累加 | INT32 | 一致 |
| 舍入、饱和 | 半值远离零，INT8 饱和 | 一致 |
| 重定标 shift | 全部为 31 | 与现有固定移位一致 |
| GAP、两个 FC | GAP 后分别输出 collision/steering INT32 | 当前未实现硬件，本次用实际 RTL 特征执行软件尾部验证 |

虽然导出使用 INT64 文件保存 multiplier，三个卷积层的实际 multiplier 全部可放入现有有符号 INT32 参数口：

| 层 | 最小 multiplier | 最大 multiplier | 最大累加绝对上界 |
|---|---:|---:|---:|
| Conv1 | 5,232,992 | 27,568,307 | 105,019 |
| Conv2 | 6,875,156 | 10,798,697 | 472,570 |
| Conv3 | 6,451,931 | 11,158,905 | 824,124 |

导出转换脚本检查权重、bias 的 dtype/shape/range，重新计算并比对每输出通道累加上界，检查 multiplier/shift 和 INT64 乘法范围。没有重新训练、校准、量化或重新计算倍率。

## 验证流程

1. 检查 `tensor_manifest.json`、`golden_tensor_manifest.json` 中全部 373 个二进制文件的大小和 SHA256，并检查对应 NPY 的 dtype、shape 和原始 payload 完全相同。
2. 用原软件整数参考重新生成 30 个样本的 330 个整数中间/最终张量，逐项与导出 golden 对齐。
3. 将三个卷积层的权重、bias、multiplier 转成现有 ROM 可读取的 HEX，放入独立的 `data/dual_task_baseline2_qat/`，保留默认 HNM 数据。权重基址仍为 0/72/1224，bias 和 quant 基址为 0/8/24。
4. `tb_dual_qat` 复用现有 `tb_layer` 和同一个 DUT，每个样本只在 Conv1 前装载图片。之后由 testbench 配置、启动下一层，Conv2/3 直接读取上一层真实写入的 Feature BRAM；没有重新装载 golden 中间特征。
5. 检查每一对滑窗的 18 字节、每个带 bias 的 INT32 累加值、每个池化写地址/数值，以及整层结束后的实际 BRAM 回读。检查地址唯一、完整覆盖、输入流水和阶段重叠。
6. 奇数样本交换 A/B 并使用非行对齐基地址，保证前一层输出基址和后一层输入基址匹配。还检查非法配置、busy 隔离、运行中复位、BRAM 请求/返回在途复位。
7. 保存每个样本每层的实际 BRAM 回读值到 `build/dual_task_baseline2_qat/rtl_outputs/`，共 90 个文件。
8. 从实际 Conv3 回读特征计算软件 GAP、两个整数 FC、反量化和 sigmoid，再核对 GAP 求和、GAP INT8、两个 INT32 输出及导出 CSV 的数值。

注意：第 8 步在 Python 中执行，证明实际硬件主干特征可以恢复正确的双任务整数答案；不表示 GAP 或两个 FC 已在 FPGA RTL 中实现。数值验证对齐的是模型整数参考，并非要求预测角度或分类结果与人工标签完全相同。

## 结果

全部 30 个导出样本均已验证：20 个 collision validation（10 safe、10 collision）和 10 个 steering validation。

| 检查 | 数量 | 结果 |
|---|---:|---|
| 实际三层串接 | 30 次 / 90 层 | PASS |
| 带 bias 的 INT32 累加结果 | 1,720,320 | 全部一致 |
| 池化 INT8 写入 | 430,080 | 全部一致 |
| 实际 BRAM 回读 | 430,080 | 全部一致 |
| 滑窗 INT8 元素 | 9,953,280 | 全部一致 |
| 软件 GAP INT32 求和 | 960 | 全部一致 |
| 软件 GAP INT8 | 960 | 全部一致 |
| 软件 collision / steering INT32 | 60 | 全部一致 |

同时重新执行默认 HNM 的两个样本、六次整层回归，全部通过。共享 testbench 的扩展没有改变原默认测试行为。

示例：样本 `000_collision_validation` 的最终 collision INT32 为 -16,265，steering INT32 为 1,202，反量化角度为 0.05861660098，sigmoid 风险分数为 0.14087126224，与该模型 golden 一致。完整结果见 `build/dual_task_baseline2_qat/rtl_cnn_software_heads.csv`。

## 周期

全部 30 个样本的同层周期完全相同。按 50 MHz 换算：

| CNN 卷积块 | 周期 | 时间 |
|---|---:|---:|
| Conv1 | 11,375 | 0.22750 ms |
| Conv2 | 19,538 | 0.39076 ms |
| Conv3 | 33,860 | 0.67720 ms |
| 三层总计 | 64,773 | 1.29546 ms |

三层卷积有效吞吐 4.09771 GOPS，771.93 次三层计算/秒，有效 MAC 利用率 32.01%。包含内部参数加载，不含 host 装载/回读、软件 GAP/FC、反量化或系统调度；不是板上实测，也不是完整双任务模型的 FPS。

本次没有修改计算 RTL，没有重新执行 QAT 权重版本的综合、布局布线或动态 SDF。此前资源和时序属于原参数配置，不将它们作为本次 QAT 参数配置的新测量结果。

## 文件和复现

```powershell
& 'D:\programm\anaconda\envs\vision_attention\python.exe' scripts/export_dual_qat_vectors.py
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_sim.ps1 -Test dual_qat
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_sim.ps1 -Test layer
& 'D:\programm\anaconda\envs\vision_attention\python.exe' scripts/verify_dual_qat.py
```

- 原始导出：用户指定目录，只读使用。
- 兼容性检查、格式转换与 golden 再生成：`scripts/export_dual_qat_vectors.py`。
- RTL 测试入口：`sim/tb_dual_qat.sv`，复用 `sim/tb_layer.sv` 的可配置样本数和全样本串接模式。
- 新模型参数和 fixture：`data/dual_task_baseline2_qat/`；`manifest.json` 保存源文件、RTL 和 fixture 哈希。
- 仿真日志：`build/xsim_dual_qat.log`；最终必须出现 `PASS tb_layer: 90 layers`。
- 软件尾部与证据核对：`scripts/verify_dual_qat.py`。
- 机器可读汇总：`build/dual_task_baseline2_qat/verification_summary.json`，含计数、周期和源文件/RTL/fixture/日志/实际回读哈希。

默认硬件顶层和 GUI 工程仍引用原 HNM 参数。新模型仿真使用 `WEIGHT_FILE`、`BIAS_FILE`、`QUANT_FILE` 参数显式指向上述独立目录；没有把两个模型的权重混用。
