param([Parameter(Mandatory=$true)][string]$PlanPath)
. (Join-Path $PSScriptRoot 'Common.ps1')
$result=[ordered]@{Status='starting';At=[DateTimeOffset]::Now.ToString('o')};$registered=$false
try {
    if(-not(Is-Admin)){throw 'Administrator rights are required to register the separate ASCOM driver.'}
    Assert-Package $PSScriptRoot
    $plan=Read-Json $PlanPath
    $expected=Join-Path ${env:CommonProgramFiles(x86)} 'ASCOM\Camera\QHY5RII-FastTransition-v0.1'
    if([IO.Path]::GetFullPath($plan.InstallDirectory).TrimEnd('\') -ne [IO.Path]::GetFullPath($expected).TrimEnd('\')){throw 'Unexpected installation destination.'}
    Assert-Hash $plan.OriginalDriver '4348F80FD2156C3E9A980100BC57AB67E5E874BECB84875C675FB894400F65F3'
    Assert-Hash $plan.OriginalSDK '5028947E1FFA52E5098ADE1DD0CEF7E7462C29ADBAEDA24CE713DD1D682AECBE'
    Assert-Hash $plan.GeneratedDriver $plan.GeneratedSHA256
    $assembly=[Reflection.AssemblyName]::GetAssemblyName($plan.GeneratedDriver)
    if($assembly.Name -ne 'ASCOM.QHY5RII.FastTransition.Camera' -or $assembly.Version.ToString() -ne '25.3.24.1001' -or -not $assembly.GetPublicKey().Length){throw 'Unexpected generated ASCOM assembly.'}
    $machine=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry32)
    $old=$machine.OpenSubKey('SOFTWARE\ASCOM\Camera Drivers\ASCOM.QHYCCD.Camera')
    if(-not $old){throw 'Official QHY ASCOM settings are unavailable.'}
    $id=[string]$old.GetValue('LastCamId','')
    if(-not $id.StartsWith('QHY5RII-C-',[StringComparison]::Ordinal)){throw 'Select QHY5R-II-C in the official ASCOM driver first.'}
    $collision=$machine.OpenSubKey('SOFTWARE\Classes\CLSID\{D54D716C-9C15-4FDE-B034-BB54CB4D3021}')
    if($collision){$collision.Close();throw 'The separate driver is already registered. Use Check or Restore from its original installation.'}
    if((Test-Path -LiteralPath $expected) -and @(Get-ChildItem -LiteralPath $expected -Force).Count){throw 'The installation directory is not empty; no file was overwritten.'}
    New-Item -ItemType Directory -Path (Join-Path $expected 'x86') -Force | Out-Null
    $dll=Join-Path $expected 'ASCOM.QHY5RII.FastTransition.Camera.dll'
    Copy-Item -LiteralPath $plan.GeneratedDriver -Destination $dll
    Copy-Item -LiteralPath $plan.OriginalSDK -Destination (Join-Path $expected 'x86\qhyccd1.dll')
    Assert-Hash $dll $plan.GeneratedSHA256
    & (Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\RegAsm.exe') $dll /nologo /codebase 2>&1 | Out-File (Join-Path $plan.StateDirectory 'registration.txt') -Encoding UTF8
    if($LASTEXITCODE -ne 0){throw 'ASCOM registration failed.'};$registered=$true
    $created=$machine.CreateSubKey('SOFTWARE\ASCOM\Camera Drivers\ASCOM.QHY5RII.FastTransition.Camera')
    try {
        Copy-RegTree $old $created
        $created.SetValue('','QHY5RII-C Fast Transition TEST',[Microsoft.Win32.RegistryValueKind]::String)
        $device=$created.OpenSubKey($id,$true)
        if(-not $device){throw 'The selected camera has no existing ASCOM settings.'}
        try {foreach($pair in @(@('Speed','1'),@('USBTraffic','30'),@('TransferBits','16'))){$device.SetValue($pair[0],$pair[1],[Microsoft.Win32.RegistryValueKind]::String)}}finally{$device.Close()}
    } finally {$created.Close();$old.Close();$machine.Close()}
    & (Join-Path $PSScriptRoot 'tools\DriverCheck.exe') com $dll (Join-Path $plan.StateDirectory 'com-check.json')
    if($LASTEXITCODE -ne 0){throw 'Separate COM activation did not pass. See com-check.json.'}
    Assert-Hash $plan.OriginalDriver '4348F80FD2156C3E9A980100BC57AB67E5E874BECB84875C675FB894400F65F3'
    $result.Status='installed_verified';$result.Driver=$dll;$result.SHA256=$plan.GeneratedSHA256;$result.ProgID='ASCOM.QHY5RII.FastTransition.Camera'
} catch {
    $result.Status='failed';$result.Error=$_.Exception.Message
    if($registered){try{& (Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\RegAsm.exe') $dll /nologo /unregister 2>&1 | Out-File (Join-Path $plan.StateDirectory 'rollback-registration.txt') -Encoding UTF8;$result.NewDriverUnregistered=($LASTEXITCODE -eq 0)}catch{$result.RollbackError=$_.Exception.Message}}
}
Save-Json $result (Join-Path (Split-Path -Parent $PlanPath) 'admin-result.json')
if($result.Status -ne 'installed_verified'){exit 1}
