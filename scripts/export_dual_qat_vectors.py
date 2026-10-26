"""Check and adapt an existing dual-task QAT export to the unchanged CNN RTL.

No training, calibration or quantization is performed here.
"""
import argparse
import csv
import hashlib
import json
import sys
from pathlib import Path

import numpy as np

from export_vectors import hexfile


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--export', default=r'D:\Workspace\FPGA_CNN\artifacts_dual_task_baseline2_int8_qat\export')
    ap.add_argument('--out', default='data/dual_task_baseline2_qat')
    args = ap.parse_args()
    root, out = Path(args.export), Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    q = json.loads((root / 'quant_params.json').read_text(encoding='utf-8'))
    assert q['qrange'] == [-127, 127]
    structure = json.loads((root / 'network_structure.json').read_text(encoding='utf-8'))
    assert structure['input_shape'] == [1, 1, 64, 64]
    rows = list(csv.DictReader((root / 'golden_samples.csv').open(encoding='utf-8')))
    assert len(rows) == 30, 'tb_dual_qat currently covers exactly the 30 exported samples'
    assert len({row['prefix'] for row in rows}) == len(rows)
    source_paths = {p for p in root.glob('*.json')} | {root / 'quantization_spec.md', root / 'golden_samples.csv'}
    # Verify all binary hashes and require .npy payloads to match the exported binaries.
    binary_count = 0
    for manifest_name in ('tensor_manifest.json', 'golden_tensor_manifest.json'):
        for record in json.loads((root / manifest_name).read_text(encoding='utf-8')):
            p = root / record['file']
            assert sha(p) == record['sha256'], p
            assert p.stat().st_size == record['bytes'], p
            a = np.fromfile(p, dtype=np.dtype(record['dtype']).newbyteorder('<')).reshape(record['shape'])
            npy = root / record.get('npy', str(Path(record['file']).with_suffix('.npy')))
            if npy.exists():
                b = np.load(npy, allow_pickle=False)
                assert a.shape == b.shape and a.dtype == b.dtype and a.tobytes() == b.tobytes(), npy
                source_paths.add(npy)
            source_paths.add(p)
            binary_count += 1
    # Imported reference is read-only; use it to independently regenerate all golden traces.
    model_root = root.parent.parent
    sys.path.insert(0, str(model_root))
    from dual_task_int8.integer_model import run_integer
    params = dict(q)
    params['layers'] = {}
    for name, p in q['layers'].items():
        params['layers'][name] = dict(p)
        for key in ('weight_int8', 'bias_int32'):
            path = root / p[key]
            params['layers'][name][key] = np.load(path, allow_pickle=False)
            source_paths.add(path)
    for relative in ('dual_task_int8/integer_model.py', 'int8_reference.py'):
        source_paths.add(model_root / relative)
    weights, biases, multipliers, layers = [], [], [], []
    for i, (ci, co) in enumerate(((1, 8), (8, 16), (16, 32)), 1):
        name = f'conv{i}'
        p = params['layers'][name]
        w, b = p['weight_int8'], p['bias_int32']
        assert w.dtype == np.int8 and w.shape == (co, ci, 3, 3)
        assert b.dtype == np.int32 and b.shape == (co,)
        assert int(w.min()) >= -127 and int(w.max()) <= 127
        bounds = np.abs(w.astype(np.int64)).sum(axis=(1, 2, 3)) * 127 + np.abs(b.astype(np.int64))
        assert np.all(bounds < 2**31)
        assert bounds.tolist() == p['worst_case_accumulator_abs_bound']
        requants = q['requant'][name]
        assert len(requants) == co
        assert all(r['shift'] == 31 and 0 <= r['multiplier'] < 2**31 for r in requants)
        assert max(int(bound) * r['multiplier'] + 2**30 for bound, r in zip(bounds, requants)) < 2**63
        layers.append(dict(name=name, weight_base=len(weights), bias_base=len(biases), quant_base=len(multipliers),
                           weight_shape=list(w.shape), multiplier_min=min(r['multiplier'] for r in requants),
                           multiplier_max=max(r['multiplier'] for r in requants), shift=31,
                           accumulator_abs_bound_max=int(bounds.max())))
        weights.extend(w.ravel())
        biases.extend(b.ravel())
        multipliers.extend(r['multiplier'] for r in requants)
    assert [x['weight_base'] for x in layers] == [0, 72, 1224]
    assert [x['bias_base'] for x in layers] == [0, 8, 24]
    hexfile(out / 'weights.hex', weights, 8, 8192)
    hexfile(out / 'bias.hex', biases, 32, 64)
    hexfile(out / 'quant.hex', multipliers, 32, 64)
    trace_count = 0
    for sample, row in enumerate(rows):
        prefix = row['prefix']
        fp = np.load(root / 'golden' / f'{prefix}_input_fp32.npy', allow_pickle=False)
        result = run_integer(fp, params, save_layers=True)
        for name, actual in result['trace'].items():
            path = root / 'golden' / f'{prefix}_{name}.npy'
            expected = np.load(path, allow_pickle=False)
            assert actual.dtype == expected.dtype and np.array_equal(actual, expected), path
            trace_count += 1
        for head in ('collision', 'steering'):
            assert result[head + '_int32'] == int(row[head + '_int32'])
        for layer, (ci, co, h) in enumerate(((1, 8, 64), (8, 16, 32), (16, 32, 16)), 1):
            suffixes = dict(input='input_int8' if layer == 1 else f'conv{layer-1}_pool_int8',
                            acc=f'conv{layer}_acc_int32', out=f'conv{layer}_pool_int8')
            shapes = dict(input=(ci, h, h), acc=(co, h, h), out=(co, h//2, h//2))
            for kind, suffix in suffixes.items():
                a = np.load(root / 'golden' / f'{prefix}_{suffix}.npy', allow_pickle=False)
                assert a.shape == shapes[kind]
                assert a.dtype == (np.int32 if kind == 'acc' else np.int8)
                hexfile(out / f's{sample}_conv{layer}_{kind}.hex', a, 32 if kind == 'acc' else 8)
    manifest = dict(export_root=str(root), samples=rows, layers=layers,
                    scope='Unchanged RTL Conv/Bias/Requant/ReLU/MaxPool; GAP and dual FC are software only',
                    binary_manifest_entries_verified=binary_count, golden_reference_traces_verified=trace_count,
                    rtl_sha256={str(p): sha(p) for p in sorted(Path('rtl').glob('*.v'))},
                    source_sha256={str(p): sha(p) for p in sorted(source_paths)},
                    fixture_sha256={p.name: sha(p) for p in sorted(out.glob('*.hex'))})
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(dict(samples=len(rows), binaries_checked=binary_count, reference_traces=trace_count,
                          layers=layers, out=str(out)), indent=2))


if __name__ == '__main__':
    main()
