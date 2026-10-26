"""Combine verified cycle/resource results and explicitly estimated on-chip power."""
import hashlib
import json
import re
from pathlib import Path


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def power_fields(path):
    s = path.read_text()
    result = {}
    for key, label in [('total_w','Total On-Chip Power (W)'),('dynamic_w','Dynamic (W)'),
                       ('static_w','Device Static (W)'),('confidence','Confidence Level'),
                       ('nets_matched','Design Nets Matched'),('ambient_c','Ambient Temp (C)'),
                       ('junction_c','Junction Temperature (C)')]:
        m = re.search(r'\|\s*'+re.escape(label)+r'\s*\|\s*([^|\r\n]+)',s)
        assert m, label
        text = m[1].strip()
        result[key] = float(text) if key.endswith(('_w','_c')) else text
    return result


build = Path('build/full_network')
verified = json.loads((build / 'verification_summary.json').read_text(encoding='utf-8'))
for key in ('source_sha256','evidence_sha256'):
    for path, digest in verified[key].items():
        assert sha(path) == digest, path
power_log = (build / 'xsim_power.log').read_text()
assert re.search(r'^PASS tb_power: sample=0 cycles=65116 collision=-16265 steering=1202$', power_log, re.M)
assert 'PASS inference SAIF:' in power_log
assert not re.search(r'^Fatal:|^ERROR:',power_log,re.M)
assert re.search(r'^PASS network power estimate$',(build/'power_activity.log').read_text(),re.M)
activity = power_fields(build / 'power_activity.rpt')
vectorless = power_fields(build / 'power_vectorless.rpt')
duration = int(re.search(r'\(DURATION\s+(\d+)\)',(build/'inference_rtl.saif').read_text())[1])
assert duration == 1302340000  # ps, includes one 20 ns control margin.
latency_s = verified['full_network_cycles'] / verified['clock_hz']
gops = verified['effective_gops']
for p in (activity, vectorless):
    p['estimated_gops_per_w_total'] = gops / p['total_w']
    p['estimated_gops_per_w_dynamic_only'] = gops / p['dynamic_w']
    p['estimated_energy_uj_per_inference_total'] = p['total_w'] * latency_s * 1e6
    p['estimated_energy_uj_per_inference_dynamic_only'] = p['dynamic_w'] * latency_s * 1e6
    p['estimated_inferences_per_j_total'] = verified['inferences_per_second'] / p['total_w']
files = [build/name for name in ('verification_summary.json','cnn_route.dcp','power_activity.rpt',
          'power_activity.log','power_vectorless.rpt','inference_rtl.saif','xsim_power.log')]
files += [Path(name) for name in ('sim/tb_power.sv','scripts/run_power_activity.ps1',
          'scripts/power_activity.tcl','scripts/report_network_power.tcl',
          'scripts/report_network_activity_power.tcl','scripts/summarize_performance.py')]
report = dict(model='baseline_2 dual-task QAT INT8',device='xc7z020clg400-1',clock_mhz=50,
              sample_count=30,correctness='PASS: all 60 final RTL INT32 outputs and intermediate tensors match golden',
              cycles=verified['full_network_cycles'],latency_ms=latency_s*1000,
              throughput_inferences_s=verified['inferences_per_second'],macs_per_inference=2654272,
              effective_gops=gops,effective_tops=gops/1000,peak_gops=12.8,
              useful_pe_mac_utilization=verified['useful_mac_utilization'],
              resources=verified['resources'],kluts=verified['resources']['lut']/1000,
              timing=verified['timing'],activity_power_estimate=activity,
              vectorless_power_estimate=vectorless,activity_capture_duration_ns=duration/1000,
              power_method='Post-route Vivado report_power, RTL SAIF from one verified sample-0 inference; unmatched nets estimated by Vivado',
              limitations='On-chip tool estimate, not measured board power. No active PS/DDR/platform/host power. RTL activity omits post-route glitches. Default thermal conditions. One sample is not a dataset power average.',
              latency_excludes='Host upload/readback, PS dequant/sigmoid, platform integration',
              evidence_sha256={str(p):sha(p) for p in files})
(build/'performance_summary.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
print(json.dumps({k:v for k,v in report.items() if k!='evidence_sha256'},indent=2))
