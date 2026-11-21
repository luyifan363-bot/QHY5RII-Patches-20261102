$ErrorActionPreference='Stop'
function Hash-File([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Assert-Hash([string]$Path,[string]$Expected) { if ((Hash-File $Path) -ne $Expected) {throw ('Unsupported or changed file: '+$Path)} }
function Read-Json([string]$Path) {Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json}
function Save-Json($Value,[string]$Path) {$Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8}
function Is-Admin { (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Assert-Package([string]$Root) {
    $manifest=Read-Json (Join-Path $Root 'package-manifest.json')
    foreach($entry in $manifest.Files) {
        $file=[IO.Path]::GetFullPath((Join-Path $Root $entry.Name))
        if(-not $file.StartsWith(([IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid package path.'}
        Assert-Hash $file $entry.SHA256
    }
}
function Invoke-AdminScript([string]$Script,[string[]]$Arguments) {
    $parts=@('-NoProfile','-ExecutionPolicy','RemoteSigned','-File',$Script)+$Arguments
    foreach($part in $parts){if($part.Contains('"')){throw 'Invalid double quote in command argument.'}}
    $line=($parts | ForEach-Object {'"'+$_.TrimEnd('\')+'"'}) -join ' '
    $child=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $line -Verb RunAs -WindowStyle Hidden -Wait -PassThru
    if($child.ExitCode -ne 0){throw ('Administrator stage failed with exit code '+$child.ExitCode+'. See the local operation report.')}
}
function Export-Reg([string]$Key,[string]$Path) {
    & (Join-Path $env:SystemRoot 'SysWOW64\reg.exe') export $Key $Path /y | Out-Null
    if($LASTEXITCODE -ne 0 -or -not(Test-Path -LiteralPath $Path)){throw ('Registry backup failed: '+$Key)}
}
function Copy-RegTree([Microsoft.Win32.RegistryKey]$Source,[Microsoft.Win32.RegistryKey]$Destination) {
    foreach($name in $Source.GetValueNames()){$Destination.SetValue($name,$Source.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames),$Source.GetValueKind($name))}
    foreach($name in $Source.GetSubKeyNames()){
        $from=$Source.OpenSubKey($name);$to=$Destination.CreateSubKey($name)
        try{Copy-RegTree $from $to}finally{$from.Close();$to.Close()}
    }
}
function Copy-VerifiedTransaction([object[]]$Files,[string]$RollbackDirectory) {
    New-Item -ItemType Directory -Path $RollbackDirectory -Force | Out-Null
    $saved=@();$index=0
    foreach($file in $Files){
        Assert-Hash $file.Source $file.SHA256
        $previous=Hash-File $file.Target;$backup=Join-Path $RollbackDirectory ($index.ToString()+'.bin');$index++
        Copy-Item -LiteralPath $file.Target -Destination $backup
        Assert-Hash $backup $previous
        $saved+=@([pscustomobject]@{Source=$file.Source;Target=$file.Target;SHA256=$file.SHA256;PreviousHash=$previous;Backup=$backup})
    }
    try {
        foreach($file in $saved){Assert-Hash $file.Target $file.PreviousHash;Copy-Item -LiteralPath $file.Source -Destination $file.Target -Force;Assert-Hash $file.Target $file.SHA256}
    } catch {
        $reason=$_.Exception.Message;$rollbackErrors=@()
        foreach($file in $saved){try{Copy-Item -LiteralPath $file.Backup -Destination $file.Target -Force;Assert-Hash $file.Target $file.PreviousHash}catch{$rollbackErrors+=$_.Exception.Message}}
        if($rollbackErrors.Count){throw ('File transaction failed and rollback needs attention: '+($rollbackErrors -join '; '))}
        throw ('File transaction failed; all previous files were restored. '+$reason)
    }
}
function Show-Result([string]$Message,[bool]$Success,[bool]$Quiet) {
    if($Quiet){Write-Output $Message;return}
    Add-Type -AssemblyName System.Windows.Forms
    $icon=if($Success){[Windows.Forms.MessageBoxIcon]::Information}else{[Windows.Forms.MessageBoxIcon]::Error}
    [Windows.Forms.MessageBox]::Show($Message,'QHY5R-II-C patches',[Windows.Forms.MessageBoxButtons]::OK,$icon)|Out-Null
}
