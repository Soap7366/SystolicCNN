"""Export existing HNM integers verbatim; no calibration or quantization."""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np


def hexfile(path, values, bits, depth=None):
    values = [int(v) & ((1 << bits) - 1) for v in np.asarray(values).ravel()]
    if depth is not None:
        assert len(values) <= depth
        values += [0] * (depth - len(values))
    path.write_text(''.join(f'{v:0{bits // 4}x}\n' for v in values), encoding='ascii')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--model-root', default=r'D:\Workspace\FPGA_CNN')
    ap.add_argument('--out', default='data')
    args = ap.parse_args()
    root = Path(args.model_root) / 'artifacts_int8_hnm'
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    q = json.loads((root / 'quant_params.json').read_text(encoding='utf-8'))['quantization']
    weights, biases, mults = [], [], []
    layers = []
    sources = [root / 'quant_params.json']
    for name in ['conv1', 'conv2', 'conv3', 'fc']:
        wp = root / 'weights' / f'{name}_weight_int8.npy'
        bp = root / 'weights' / f'{name}_bias_int32.npy'
        w, b = np.load(wp), np.load(bp)
        assert w.dtype == np.int8 and b.dtype == np.int32
        layers.append(dict(name=name, weight_base=len(weights), bias_base=len(biases), quant_base=len(mults)))
        weights.extend(w.ravel()); biases.extend(b.ravel())
        if name != 'fc':
            for r in q['requant'][name]:
                assert r['shift'] == 31
                mults.append(r['multiplier'])
        sources += [wp, bp]
    hexfile(out / 'weights.hex', weights, 8, 8192)
    hexfile(out / 'bias.hex', biases, 32, 64)
    hexfile(out / 'quant.hex', mults, 32, 64)
    inputs = sorted((root / 'golden_validation').glob('*_input_int8.npy'))
    # Opposite labels, when available, with all intermediate tensors preserved.
    selected = [inputs[0], next(p for p in inputs if '_y1_' in p.name)]
    for sample, path in enumerate(selected):
        stem = path.name.removesuffix('_input_int8.npy')
        for layer in range(1, 4):
            prefix = f's{sample}_conv{layer}'
            names = {'input': 'input_int8' if layer == 1 else f'conv{layer-1}_out_int8',
                     'acc': f'conv{layer}_acc_int32', 'out': f'conv{layer}_out_int8'}
            for kind, suffix in names.items():
                src = path.parent / f'{stem}_{suffix}.npy'
                a = np.load(src, allow_pickle=False)
                hexfile(out / f'{prefix}_{kind}.hex', a, 32 if kind == 'acc' else 8)
                sources.append(src)
    manifest = dict(model_root=str(root), layers=layers,
                    samples=[p.name.removesuffix('_input_int8.npy') for p in selected],
                    sha256={str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources})
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    print(json.dumps(dict(layers=layers, samples=manifest['samples']), indent=2))


if __name__ == '__main__':
    main()
