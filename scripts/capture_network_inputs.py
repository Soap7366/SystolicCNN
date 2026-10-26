"""Snapshot the exact inputs before running implement_full_network.tcl."""
import argparse
import hashlib
import json
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument('--out', default='build/full_network/implementation_inputs.json')
args = ap.parse_args()
files = list(Path('rtl').glob('*.v')) + list(Path('data/dual_task_baseline2_qat').glob('*.hex'))
files += [Path(p) for p in ('scripts/implement.tcl', 'scripts/implement_full_network.tcl',
                            'scripts/pre_opt.tcl', 'constraints/core_50mhz.xdc')]
out = Path(args.out)
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps({str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}, indent=2))
print(f'Captured {len(files)} implementation input hashes in {out}')
