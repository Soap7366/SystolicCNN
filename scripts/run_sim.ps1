param([ValidateSet('array','post','layer','memory','dual_qat','network','gap','linear','control')][string]$Test='layer')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Set-Location $root
$bin='D:\Vivado\2023.2\bin'
$sources=Get-ChildItem -LiteralPath "$root\rtl" -Filter '*.v' | ForEach-Object FullName
if($Test -eq 'dual_qat'){
    $sources+= "$root\sim\tb_layer.sv"
    New-Item -ItemType Directory -Force -Path "$root\build\dual_task_baseline2_qat\rtl_outputs" | Out-Null
}
& "$bin\xvlog.bat" --sv @sources "$root\sim\tb_$Test.sv" --log "build/xvlog_$Test.log"
if($LASTEXITCODE -ne 0){throw 'xvlog failed'}
& "$bin\xelab.bat" "tb_$Test" -s "sim_$Test" --debug typical --log "build/xelab_$Test.log"
if($LASTEXITCODE -ne 0){throw 'xelab failed'}
& "$bin\xsim.bat" "sim_$Test" -runall --log "build/xsim_$Test.log"
if($LASTEXITCODE -ne 0){throw 'xsim failed'}
$passMarker="PASS tb_$Test"
if($Test -eq 'dual_qat'){$passMarker='PASS tb_layer: 90 layers;'}
if(-not (Select-String -Path "build/xsim_$Test.log" -SimpleMatch $passMarker -Quiet)){throw 'Simulation did not reach PASS'}
