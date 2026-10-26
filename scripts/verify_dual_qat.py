"""Audit RTL CNN results and run a clearly separate software GAP/dual-FC tail."""
import csv
import hashlib
import json
import math
import re
from pathlib import Path

import numpy as np


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    data = Path('data/dual_task_baseline2_qat')
    build = Path('build/dual_task_baseline2_qat')
    manifest = json.loads((data / 'manifest.json').read_text(encoding='utf-8'))
    export = Path(manifest['export_root'])
    for group in ('source_sha256', 'rtl_sha256'):
        for path, digest in manifest[group].items():
            assert sha(path) == digest, path
    for name, digest in manifest['fixture_sha256'].items():
        assert sha(data / name) == digest, name
    rows = manifest['samples']
    count = len(rows)
    log_path = Path('build/xsim_dual_qat.log')
    log = log_path.read_text()
    assert re.search(rf'^PASS tb_layer: {count*3} layers;', log, re.M)
    assert not re.search(r'^Fatal:|^ERROR:', log, re.M)
    passes = re.findall(r'^PASS sample=.*$', log, re.M)
    assert len(passes) == count * 3
    assert sum(int(re.search(r'acc=(\d+)', p)[1]) for p in passes) == count * 57344
    assert sum(int(re.search(r'pool=(\d+)', p)[1]) for p in passes) == count * 14336
    assert f'PASS window bytes: {count*331776} exact comparisons' in log
    original_log = Path('build/xsim_layer.log')
    assert re.search(r'^PASS tb_layer: 6 layers;', original_log.read_text(), re.M)
    profiles = [dict((k, int(v)) for k, v in re.findall(r'(\w+)=(\d+)', line))
                for line in re.findall(r'^PROFILE .*$', log, re.M)]
    assert len(profiles) == count * 3
    assert {(p['sample'], p['layer']) for p in profiles} == {(s, l) for s in range(count) for l in (1, 2, 3)}
    for p in profiles:
        expected = profiles[p['layer'] - 1]
        assert {k: v for k, v in p.items() if k != 'sample'} == {k: v for k, v in expected.items() if k != 'sample'}
    q = json.loads((export / 'quant_params.json').read_text(encoding='utf-8'))
    results, dumps = [], []
    for sample, row in enumerate(rows):
        for layer, shape in enumerate(((8, 32, 32), (16, 16, 16), (32, 8, 8)), 1):
            path = build / 'rtl_outputs' / f's{sample}_conv{layer}_out.hex'
            a = np.array([int(v, 16) for v in path.read_text().split()], dtype=np.uint8).view(np.int8)
            assert a.size == int(np.prod(shape)), path
            actual = a.reshape(shape)
            expected = np.load(export / 'golden' / f"{row['prefix']}_conv{layer}_pool_int8.npy")
            assert np.array_equal(actual, expected), path
            dumps.append(path)
        # 'actual' is the real Conv3 feature map read back from RTL BRAM.
        # The operations below are SOFTWARE, not hardware GAP/FC implementation.
        sums = actual.astype(np.int64).sum(axis=(1, 2))
        golden = export / 'golden' / row['prefix']
        assert np.array_equal(sums, np.load(str(golden) + '_gap_sum_int32.npy'))
        m, shift = q['requant']['gap']
        product = sums * np.int64(m)
        rounded = np.sign(product) * ((np.abs(product) + (1 << (shift-1))) >> shift)
        gap = np.clip(rounded, -127, 127).astype(np.int8)
        assert np.array_equal(gap, np.load(str(golden) + '_gap_int8.npy'))
        result = dict(sample=sample, prefix=row['prefix'], task_split=row['task_split'], target=row['target'])
        for head in ('collision', 'steering'):
            p = q['layers'][head]
            w = np.load(export / p['weight_int8']).astype(np.int64)
            b = np.load(export / p['bias_int32']).astype(np.int64)
            acc = w @ gap.astype(np.int64) + b
            assert np.all(acc >= -2**31) and np.all(acc < 2**31)
            assert np.array_equal(acc, np.load(str(golden) + f'_{head}_int32.npy'))
            value = int(acc[0])
            assert value == int(row[head + '_int32'])
            result[head + '_int32'] = value
            result[head] = value * p['logit_scales'][0]
            assert math.isclose(result[head], float(row[head]), rel_tol=1e-12, abs_tol=1e-12)
        result['probability'] = 1 / (1 + math.exp(-max(-700, min(700, result['collision']))))
        assert math.isclose(result['probability'], float(row['probability']), rel_tol=1e-12, abs_tol=1e-12)
        results.append(result)
    with (build / 'rtl_cnn_software_heads.csv').open('w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=list(results[0]))
        writer.writeheader()
        writer.writerows(results)
    total = sum(p['total'] for p in profiles[:3])
    evidence = [log_path, original_log, Path('build/xelab_dual_qat.log'), Path('build/xvlog_dual_qat.log'),
                Path('sim/tb_layer.sv'), Path('sim/tb_dual_qat.sv'), Path('scripts/run_sim.ps1'),
                Path('scripts/export_dual_qat_vectors.py'), Path('scripts/verify_dual_qat.py'),
                data / 'manifest.json', build / 'rtl_cnn_software_heads.csv'] + dumps
    report = dict(status='PASS', model_export=str(export), sample_count=count,
                  original_hnm_six_layer_regression='PASS',
                  rtl_layers_checked=count*3, actual_three_layer_chains=count,
                  exact_accumulators=count*57344, exact_pool_writes=count*14336,
                  exact_bram_readbacks=count*14336, exact_window_bytes=count*331776,
                  exact_software_gap_sums=count*32, exact_software_gap_int8=count*32,
                  exact_software_fc_outputs=count*2,
                  rtl_scope='Conv1/2/3, Bias, Requant, ReLU, MaxPool, actual BRAM chain/readback',
                  software_scope='GAP and collision/steering FC from actual RTL Conv3 readback; not RTL heads',
                  clock_hz=50000000, cycles_per_layer=[p['total'] for p in profiles[:3]],
                  three_conv_cycles=total, three_conv_ms=total/50000,
                  three_conv_runs_per_second=50000000/total,
                  effective_gops=5308416*0.05/total,
                  useful_mac_utilization=2654208/(128*total),
                  timing_scope='RTL cycle conversion only, no host transfer, software tail or board measurement',
                  profiles=profiles, source_sha256=manifest['source_sha256'],
                  rtl_sha256=manifest['rtl_sha256'], fixture_sha256=manifest['fixture_sha256'],
                  evidence_sha256={str(p): sha(p) for p in evidence})
    (build / 'verification_summary.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({k: v for k, v in report.items() if k not in
                      ('source_sha256', 'rtl_sha256', 'fixture_sha256', 'evidence_sha256', 'profiles')}, indent=2))


if __name__ == '__main__':
    main()
