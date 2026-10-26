"""Audit both ordered Prep changes against exported golden and measured logs."""
import hashlib
import json
import re
from pathlib import Path


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def measurements(path):
    log = Path(path).read_text()
    assert re.search(r'^PASS tb_layer:', log, re.M), path
    assert not re.search(r'^Fatal:|^ERROR:', log, re.M), path
    passes = re.findall(r'^PASS sample=.*$', log, re.M)
    assert len(passes) == 6
    assert sum(int(re.search(r'acc=(\d+)', p)[1]) for p in passes) == 114688
    assert sum(int(re.search(r'pool=(\d+)', p)[1]) for p in passes) == 28672
    profiles = [dict((k, int(v)) for k, v in re.findall(r'(\w+)=(\d+)', line))
                for line in re.findall(r'^PROFILE .*$', log, re.M)]
    assert len(profiles) == 6
    for a, b in zip(profiles[:3], profiles[3:]):
        assert {k: v for k, v in a.items() if k != 'sample'} == {k: v for k, v in b.items() if k != 'sample'}
    cycles = sum(p['total'] for p in profiles[:3])
    return dict(profiles=profiles, total_cycles=cycles, total_ms=cycles / 50000,
                frames_per_second=50000000 / cycles,
                effective_gops=5308416 * 0.05 / cycles,
                useful_mac_utilization=2654208 / (128 * cycles))


manifest = json.loads(Path('data/manifest.json').read_text())
for path, digest in json.loads(Path('build/column_implementation_sources.json').read_text()).items():
    assert sha(path) == digest, f'RTL changed since implementation launch: {path}'
for path, digest in manifest['sha256'].items():
    assert sha(path) == digest, path
assert len(list(Path('data').glob('*.hex'))) == 21
for p in Path('data').glob('*.hex'):
    assert sha(p) == sha(Path('build/golden_reexport_column') / p.name), p
single = Path('build/column_stream_single')
first = measurements(single / 'xsim_layer.log')
final = measurements('build/xsim_layer.log')
assert first['total_cycles'] == 127008
assert final['total_cycles'] < first['total_cycles']
for name in ('array', 'post', 'memory'):
    assert re.search(rf'^PASS tb_{name}', Path(f'build/xsim_{name}.log').read_text(), re.M)
layer_log = Path('build/xsim_layer.log').read_text()
assert 'PASS window bytes: 663552 exact comparisons' in layer_log
assert 'PASS tb_memory: 34816 exact byte comparisons' in Path('build/xsim_memory.log').read_text()
status = dict(re.findall(r'(\w+)=([^\s]+)', Path('build/implementation_status.txt').read_text()))
assert float(status['setup_slack_ns']) >= 0 and float(status['hold_slack_ns']) >= 0
impl_log = Path('build/column_stream_four_implement.log')
assert re.search(r'^PASS implementation timing$', impl_log.read_text(), re.M)
timing_report = Path('build/timing_route.rpt').read_text()
assert 'All user specified timing constraints are met.' in timing_report
assert 'checking unconstrained_internal_endpoints (0)' in timing_report
utilization = Path('build/utilization_route.rpt').read_text()
resources = {key: int(re.search(r'\|\s*' + re.escape(label) + r'\s*\|\s*(\d+)', utilization)[1])
             for key, label in [('lut', 'Slice LUTs'), ('ff', 'Slice Registers'),
                                ('bram_tile', 'Block RAM Tile'), ('dsp', 'DSPs')]}
current_files = [p for d, pattern in [('rtl', '*.v'), ('sim', '*.sv'), ('scripts', '*.ps1'),
                                     ('scripts', '*.tcl'), ('scripts', '*.py'), ('constraints', '*.xdc')]
                 for p in sorted(Path(d).glob(pattern))]
evidence = [Path(f'build/xsim_{n}.log') for n in ('array', 'post', 'memory', 'layer')]
evidence += [impl_log, Path('build/implementation_status.txt'), Path('build/utilization_route.rpt'),
             Path('build/timing_route.rpt'), Path('build/cnn_route.dcp'), Path('build/cnn_timesim.v'),
             Path('build/cnn_timesim.sdf')]
report = dict(clock_hz=50000000, baseline=measurements('build/before_column_stream/xsim_layer.log'),
              single_read_column_stream=first, four_bank_column_stream=final,
              timing=status, resources=resources, golden_samples=manifest['samples'],
              exact_accumulators_checked=114688, exact_pool_values_checked=28672,
              exact_window_bytes_checked=663552, exact_memory_bytes_checked=34816,
              source_sha256={str(p): sha(p) for p in current_files},
              fixture_sha256={str(p): sha(p) for p in sorted(Path('data').glob('*.hex'))},
              single_phase_sha256={str(p): sha(p) for p in sorted(single.rglob('*')) if p.is_file()},
              evidence_sha256={str(p): sha(p) for p in evidence},
              scope='Three Conv/Bias/Requant/ReLU/MaxPool blocks, RTL cycles; no host transfer, GAP/FC or board measurement',
              sdf_status='New routed netlist/SDF generated; dynamic SDF simulation not rerun for this change')
Path('build/column_stream_summary.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({k: {key: value for key, value in report[k].items() if key != 'profiles'}
                  for k in ('single_read_column_stream', 'four_bank_column_stream', 'timing')}, indent=2))
