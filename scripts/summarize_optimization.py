"""Summarize measured simulation cycles, with traceable source/fixture hashes."""
import argparse
import hashlib
import json
import re
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument('--out', required=True)
ap.add_argument('--require-sdf', action='store_true')
ap.add_argument('--implementation-log', default='build/implementation.log')
args = ap.parse_args()
build = Path('build')
log = (build / 'xsim_layer.log').read_text()
assert re.search(r'^PASS tb_layer:', log, re.M)
assert len(re.findall(r'^PASS sample=', log, re.M)) == 6
assert not re.search(r'^Fatal:|^ERROR:', log, re.M)
profiles = []
for line in re.findall(r'^PROFILE .*$', log, re.M):
    profiles.append({k: int(v) for k, v in re.findall(r'(\w+)=(\d+)', line)})
assert len(profiles) == 6
for a, b in zip(profiles[:3], profiles[3:]):
    assert {k: v for k, v in a.items() if k != 'sample'} == {k: v for k, v in b.items() if k != 'sample'}
for name in ('array', 'post'):
    assert re.search(rf'^PASS tb_{name}', (build / f'xsim_{name}.log').read_text(), re.M)
manifest = json.loads(Path('data/manifest.json').read_text())
for p, digest in manifest['sha256'].items():
    assert hashlib.sha256(Path(p).read_bytes()).hexdigest() == digest, p
status = dict(re.findall(r'(\w+)=([^\s]+)', (build / 'implementation_status.txt').read_text()))
assert float(status['setup_slack_ns']) >= 0 and float(status['hold_slack_ns']) >= 0
implementation_log = Path(args.implementation_log)
assert re.search(r'^PASS implementation timing$', implementation_log.read_text(), re.M)
sdf_status = 'Not required for this snapshot'
if args.require_sdf:
    sdf_log = (build / 'xsim_timing_smoke.log').read_text()
    assert re.search(r'^PASS timing_smoke:.*32 exact pool', sdf_log, re.M)
    assert re.search(r'^SMOKE input BRAM: 27 exact', sdf_log, re.M)
    assert len(re.findall(r'^SMOKE write \d+ addr=', sdf_log, re.M)) == 32
    assert not re.search(r'Timing Violation|\$setuphold|\$recrem|^ERROR:|^Fatal:', sdf_log, re.M)
    assert 'SDF backannotation was successful' in (build / 'xelab_timing.log').read_text()
    sdf_status = 'PASS: routed Conv1 first tile, 27 actual input bytes, 32 pool writes and BRAM readback, guarded host protocol'
cycles = sum(p['total'] for p in profiles[:3])
result = dict(
    clock_hz=50_000_000, profiles=profiles, total_cycles=cycles,
    total_ms=cycles / 50_000, frames_per_second=50_000_000 / cycles,
    effective_gops=5_308_416 / (cycles / 50_000_000) / 1e9,
    useful_mac_utilization=2_654_208 / (128 * cycles),
    timing=status, sdf_status=sdf_status, golden_samples=manifest['samples'],
    exact_accumulators_checked=114688, exact_pool_values_checked=28672,
    scope='Three Conv/Bias/Requant/ReLU/MaxPool blocks; no host transfer, GAP or FC; RTL cycles, not board measurement',
    source_sha256={str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                   for d, glob in [('rtl','*.v'), ('sim','*.sv'), ('scripts','*.tcl'), ('scripts','*.ps1'), ('constraints','*.xdc')]
                   for p in sorted(Path(d).glob(glob))},
    fixture_sha256={str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(Path('data').glob('*.hex'))},
    implementation_sha256={str(build / name): hashlib.sha256((build / name).read_bytes()).hexdigest()
                           for name in ('cnn_route.dcp','cnn_timesim.v','cnn_timesim.sdf')},
    evidence_sha256={str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in [implementation_log] + [build / f'xsim_{name}.log' for name in ('array','post','layer')]
                     + ([build / 'xelab_timing.log', build / 'xsim_timing_smoke.log'] if args.require_sdf else [])},
    known_host_limit='Continuous pin-level host writes are not verified; guarded writes are required for the verified SDF input protocol',
)
Path(args.out).write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({k: result[k] for k in ('total_cycles','total_ms','frames_per_second','effective_gops','useful_mac_utilization','timing')}, indent=2))
