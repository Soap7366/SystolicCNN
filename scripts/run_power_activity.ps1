$ErrorActionPreference='Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
$bin='D:\Vivado\2023.2\bin'
$sources=Get-ChildItem rtl -Filter '*.v' | ForEach-Object FullName
& "$bin\xvlog.bat" --sv @sources sim/tb_power.sv --log build/full_network/xvlog_power.log
if($LASTEXITCODE -ne 0){throw 'Power stimulus compile failed'}
& "$bin\xelab.bat" tb_power -s sim_power --debug typical --log build/full_network/xelab_power.log
if($LASTEXITCODE -ne 0){throw 'Power stimulus elaboration failed'}
& "$bin\xsim.bat" sim_power -tclbatch scripts/power_activity.tcl --log build/full_network/xsim_power.log
if($LASTEXITCODE -ne 0){throw 'Power activity simulation failed'}
if(-not (Select-String -Path build/full_network/xsim_power.log -SimpleMatch 'PASS inference SAIF' -Quiet)){throw 'Incomplete power activity capture'}
