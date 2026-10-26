"""Audit the complete RTL graph, its controls and final routed implementation."""
import csv
import hashlib
import json
import math
import re
from pathlib import Path


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    build = Path('build/full_network')
    data = Path('data/dual_task_baseline2_qat')
    manifest = json.loads((data / 'manifest.json').read_text(encoding='utf-8'))
    for group in ('source_sha256', 'rtl_sha256'):
        for path, digest in manifest[group].items():
            assert sha(path) == digest, path
    for name, digest in manifest['fixture_sha256'].items():
        assert sha(data / name) == digest, name
    for path, digest in json.loads((build / 'implementation_inputs.json').read_text()).items():
        assert sha(path) == digest, f'Changed since physical implementation: {path}'
    logs = {name: Path(f'build/xsim_{name}.log') for name in ('network', 'gap', 'linear', 'control', 'array', 'post', 'layer')}
    for name, path in logs.items():
        log = path.read_text()
        assert re.search(rf'^PASS tb_{name}:?', log, re.M), path
        assert not re.search(r'^Fatal:|^ERROR:', log, re.M), path
    log = logs['network'].read_text()
    for phase in range(3):
        assert f'PASS network abort phase={phase}' in log
    lines = re.findall(r'^PASS network sample=.*$', log, re.M)
    assert len(lines) == 30
    measurements = [dict((k, int(v)) for k, v in re.findall(r'(\w+)=(-?\d+)', line)) for line in lines]
    assert [p['sample'] for p in measurements] == list(range(30))
    for p in measurements:
        assert p['acc'] == 57344 and p['pool'] == 14336
        assert p['sums'] == 32 and p['gap'] == 32 and p['windows'] == 331776
        assert p['cycles'] == p['conv1'] + p['conv2'] + p['conv3'] + p['tail'] + p['setup']
        assert {k: v for k, v in p.items() if k not in ('sample', 'collision', 'steering')} == {
            k: v for k, v in measurements[0].items() if k not in ('sample', 'collision', 'steering')}
    assert re.search(r'^PASS tb_network: samples=30 acc=1720320 pool=430080 windows=9953280;', log, re.M)
    export = Path(manifest['export_root'])
    q = json.loads((export / 'quant_params.json').read_text(encoding='utf-8'))
    outputs = []
    for row, actual in zip(manifest['samples'], measurements):
        result = dict(sample=actual['sample'], prefix=row['prefix'], task_split=row['task_split'], target=row['target'])
        for head in ('collision', 'steering'):
            assert actual[head] == int(row[head + '_int32']), row['prefix']
            result[head + '_int32'] = actual[head]
            result[head] = actual[head] * q['layers'][head]['logit_scales'][0]
            assert math.isclose(result[head], float(row[head]), rel_tol=1e-12, abs_tol=1e-12)
        result['probability'] = 1 / (1 + math.exp(-max(-700, min(700, result['collision']))))
        assert math.isclose(result['probability'], float(row['probability']), rel_tol=1e-12, abs_tol=1e-12)
        outputs.append(result)
    with (build / 'rtl_predictions.csv').open('w', encoding='utf-8', newline='') as f:
        w = csv.DictWriter(f, fieldnames=list(outputs[0]))
        w.writeheader();w.writerows(outputs)
    timing = dict(re.findall(r'(\w+)=([^\s]+)', (build / 'implementation_status.txt').read_text()))
    assert float(timing['setup_slack_ns']) >= 0 and float(timing['hold_slack_ns']) >= 0
    timing_report = (build / 'timing_route.rpt').read_text()
    assert 'All user specified timing constraints are met.' in timing_report
    assert 'checking unconstrained_internal_endpoints (0)' in timing_report
    assert re.search(r'^PASS implementation timing$', (build / 'implementation.log').read_text(), re.M)
    util = (build / 'utilization_route.rpt').read_text()
    resources = {key: float(re.search(r'\|\s*'+re.escape(label)+r'\s*\|\s*([\d.]+)', util)[1])
                 for key, label in [('lut','Slice LUTs'),('ff','Slice Registers'),('bram_tile','Block RAM Tile'),('dsp','DSPs')]}
    assert 'PASS project configured' in Path('build/configure_full_network.log').read_text()
    xpr = Path('CNN_Accelerator.xpr').read_text(encoding='utf-8')
    assert 'Val="cnn_accelerator"' in xpr and 'Val="tb_network"' in xpr
    source = [p for folder, pattern in [('rtl','*.v'),('sim','*.sv'),('scripts','*.py'),
                                       ('scripts','*.tcl'),('scripts','*.ps1'),('constraints','*.xdc')]
              for p in sorted(Path(folder).glob(pattern))]
    artifacts = list(logs.values()) + [build / p for p in ('implementation.log','implementation_inputs.json',
                    'implementation_status.txt','timing_route.rpt','utilization_route.rpt','drc_route.rpt',
                    'cnn_route.dcp','cnn_timesim.v','cnn_timesim.sdf','rtl_predictions.csv')]
    artifacts += [Path('CNN_Accelerator.xpr'),Path('build/configure_full_network.log'),data / 'manifest.json']
    m = measurements[0]
    report = dict(status='PASS', export_root=str(export), hardware_top='cnn_accelerator',
                  samples=30, complete_rtl_inferences=30, rtl_final_outputs=60,
                  accumulators=1720320,pool_writes=430080,window_bytes=9953280,
                  gap_int32_sums=960,gap_int8_values=960,final_feature_bram_readbacks=61440,
                  active_linear_pes=[0,16],linear_macs_per_inference=64,
                  reset_abort_phases=['convolution read/return','online GAP pipeline','Linear array feed'],
                  controls='PASS: busy start/write isolation, automatic graph, result hold, GAP/layer error abort/recovery',
                  clock_hz=50000000,full_network_cycles=m['cycles'],full_network_ms=m['cycles']/50000,
                  inferences_per_second=50000000/m['cycles'],effective_gops=5308544*0.05/m['cycles'],
                  useful_mac_utilization=2654272/(128*m['cycles']),
                  conv_cycles=[m['conv1'],m['conv2'],m['conv3']],linear_phase_cycles=m['tail'],
                  setup_and_gap_handoff_cycles=m['setup'],timing=timing,resources=resources,
                  scope='All three CNN blocks, online integer GAP and BOTH Linear heads are RTL; PS dequant/sigmoid only',
                  excluded_time='Host image upload/readback, PS dequant/sigmoid, external integration; no board measurement',
                  sdf_status='New full-network netlist/SDF generated; dynamic SDF not executed for this version',
                  measurements=measurements,
                  source_sha256={str(p):sha(p) for p in source},
                  model_source_sha256=manifest['source_sha256'],fixture_sha256=manifest['fixture_sha256'],
                  evidence_sha256={str(p):sha(p) for p in artifacts})
    (build / 'verification_summary.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:v for k,v in report.items() if k not in ('measurements','source_sha256','model_source_sha256','fixture_sha256','evidence_sha256')},indent=2))


if __name__ == '__main__':
    main()
