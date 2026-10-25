param([switch]$FullLayer)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Set-Location $root
$bin='D:\Vivado\2023.2\bin'
& "$bin\xvlog.bat" --sv --work timing build/cnn_timesim.v sim/tb_timing.sv 'D:/Vivado/2023.2/data/verilog/src/glbl.v' --log build/xvlog_timing.log
if($LASTEXITCODE -ne 0){throw 'timing xvlog failed'}
& "$bin\xelab.bat" timing.tb_timing timing.glbl -L simprims_ver -L unisims_ver -L secureip -s sim_timing --debug typical --sdfmax '"/tb_timing/dut=build/cnn_timesim.sdf"' --log build/xelab_timing.log
if($LASTEXITCODE -ne 0){throw 'timing xelab failed'}
if(Select-String -Path build/xelab_timing.log -Pattern 'Returning without back annotation|SDF.*Error|Unable to.*SDF' -Quiet){throw 'SDF annotation failed'}
if(-not (Select-String -Path build/xelab_timing.log -SimpleMatch 'SDF backannotation was successful' -Quiet)){throw 'Missing successful SDF backannotation confirmation'}
if($FullLayer){
    $resultLog='build/xsim_timing.log'
    $passMarker='PASS tb_timing'
    & "$bin\xsim.bat" sim_timing -runall --log $resultLog
}else{
    $resultLog='build/xsim_timing_smoke.log'
    $passMarker='PASS timing_smoke'
    & "$bin\xsim.bat" sim_timing -tclbatch scripts/timing_smoke.tcl -wdb build/timing_smoke.wdb --log $resultLog
}
if($LASTEXITCODE -ne 0){throw 'timing xsim failed'}
if(-not (Select-String -Path $resultLog -Pattern ('^'+[regex]::Escape($passMarker)+':') -Quiet)){throw 'Timing simulation did not reach PASS'}
if(Select-String -Path $resultLog -Pattern 'Timing Violation|\$setuphold|\$recrem' -Quiet){throw 'Timing check violations in simulator log'}
