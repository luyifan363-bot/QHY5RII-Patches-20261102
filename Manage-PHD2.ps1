param([ValidateSet('Install','Restore','Check')][string]$Action='Install',[string]$TargetDirectory,[string]$StateDirectory,[int]$SourceProfileId=0,[switch]$Quiet)
. (Join-Path $PSScriptRoot 'Common.ps1')
if(-not $TargetDirectory){$TargetDirectory=Join-Path ${env:ProgramFiles(x86)} 'PHDGuiding2'}
if(-not $StateDirectory){$StateDirectory=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'QHY5RII-Patches\PHD2'}
$StateDirectory=[IO.Path]::GetFullPath($StateDirectory).TrimEnd('\');$TargetDirectory=[IO.Path]::GetFullPath($TargetDirectory).TrimEnd('\')
New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null
$statePath=Join-Path $StateDirectory 'state.json';$operation=[ordered]@{Action=$Action;Status='starting';At=[DateTimeOffset]::Now.ToString('o')}
try {
    Assert-Package $PSScriptRoot
    Assert-Hash (Join-Path $TargetDirectory 'phd2.exe') '2A509227FA529865E2B046468564B28362F04ED8FDF05CF6D53AD52448C3C18B'
    if($Action -ne 'Check' -and @(Get-Process -Name phd2 -ErrorAction SilentlyContinue).Count){throw 'Exit PHD2 before configuring or restoring its profile.'}
    $user=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser,[Microsoft.Win32.RegistryView]::Registry32)
    $config=$user.OpenSubKey('Software\StarkLabs\PHDGuidingV2',($Action -ne 'Check'))
    if(-not $config){throw 'Start PHD2 and create or select your QHY profile first.'}
    if($Action -eq 'Restore') {
        $state=Read-Json $statePath;$old=$config.OpenSubKey(('profile\'+$state.OriginalProfileId))
        if(-not $old -or $old.GetValue('name') -ne $state.OriginalProfileName){throw 'Original profile no longer matches the saved state.'}
        $old.Close();$config.SetValue('currentProfile',[int]$state.OriginalProfileId,[Microsoft.Win32.RegistryValueKind]::DWord)
        $operation.Status='original_profile_selected';$operation.Message='Original PHD2 profile selected. The separate driver and test profile are retained for an optional later return.'
    } elseif(Test-Path -LiteralPath $statePath) {
        $state=Read-Json $statePath
        if($state.Status -ne 'configured_verified'){throw 'An incomplete setup state exists. See the local reports.'}
        Assert-Hash $state.Driver $state.DriverSHA256
        $machine=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry32)
        $registration=$machine.OpenSubKey('SOFTWARE\Classes\CLSID\{D54D716C-9C15-4FDE-B034-BB54CB4D3021}\InprocServer32')
        if(-not $registration){throw 'The separate ASCOM driver is no longer registered.'}
        $registeredPath=([Uri][string]$registration.GetValue('CodeBase','')).LocalPath
        if([IO.Path]::GetFullPath($registeredPath) -ne [IO.Path]::GetFullPath($state.Driver) -or $registration.GetValue('RuntimeVersion') -ne 'v4.0.30319'){throw 'The COM registration differs from the installed driver.'}
        $registration.Close();$machine.Close()
        $profile=$config.OpenSubKey(('profile\'+$state.NewProfileId));$camera=$profile.OpenSubKey('camera')
        if($profile.GetValue('name') -ne $state.NewProfileName -or $camera.GetValue('LastMenuchoice') -ne 'QHY5RII-C Fast Transition TEST (ASCOM)' -or [int]$profile.GetValue('NoiseReductionMethod',-1) -ne 1){throw 'The configured PHD2 profile changed.'}
        $camera.Close();$profile.Close()
        if($Action -eq 'Install'){$config.SetValue('currentProfile',[int]$state.NewProfileId,[Microsoft.Win32.RegistryValueKind]::DWord)}
        $operation.Status='configured_verified';$operation.ProfileId=$state.NewProfileId;$operation.CurrentProfile=[int]$config.GetValue('currentProfile');$operation.DefaultActive=($operation.CurrentProfile -eq [int]$state.NewProfileId)
        $operation.Message=if($operation.DefaultActive){'PHD2 fast-transition profile is the default. Use the normal PHD2 shortcut.'}else{'The test profile is installed but another profile is selected. Run Install to select the patched profile.'}
    } else {
        if($Action -eq 'Check'){throw 'This package has not configured PHD2 yet.'}
        if($SourceProfileId -eq 0){$SourceProfileId=[int]$config.GetValue('currentProfile',0)}
        $source=$config.OpenSubKey(('profile\'+$SourceProfileId));if(-not $source){throw 'Selected PHD2 source profile does not exist.'}
        $originalName=[string]$source.GetValue('name','');$sourceCamera=$source.OpenSubKey('camera')
        if(-not $sourceCamera -or $sourceCamera.GetValue('LastMenuchoice') -notin @('QHY Camera','QHYCCD-Cameras-Capture (ASCOM)')){throw 'Select the QHY camera profile before running this package.'}
        $sourceCamera.Close()
        $vendor=Join-Path ${env:CommonProgramFiles(x86)} 'ASCOM\Camera\ASCOM.QHYCCD.Camera.dll';$sdk=Join-Path (Split-Path -Parent $vendor) 'x86\qhyccd1.dll'
        Assert-Hash $vendor '4348F80FD2156C3E9A980100BC57AB67E5E874BECB84875C675FB894400F65F3';Assert-Hash $sdk '5028947E1FFA52E5098ADE1DD0CEF7E7462C29ADBAEDA24CE713DD1D682AECBE'
        $machine=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry32)
        $ascom=$machine.OpenSubKey('SOFTWARE\ASCOM\Camera Drivers\ASCOM.QHYCCD.Camera');$id=[string]$ascom.GetValue('LastCamId','')
        if(-not $id.StartsWith('QHY5RII-C-',[StringComparison]::Ordinal)){throw 'Select QHY5R-II-C in official ASCOM camera settings first.'};$ascom.Close();$machine.Close()
        $backup=Join-Path $StateDirectory ('backup-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'));$build=Join-Path $StateDirectory 'generated'
        New-Item -ItemType Directory -Path $backup,$build -Force | Out-Null
        Export-Reg 'HKCU\Software\StarkLabs\PHDGuidingV2' (Join-Path $backup 'PHD2.reg')
        Export-Reg 'HKLM\Software\ASCOM\Camera Drivers\ASCOM.QHYCCD.Camera' (Join-Path $backup 'ASCOM-QHY.reg')
        foreach($entry in @(@((Join-Path $TargetDirectory 'phd2.exe'),'phd2.exe'),@((Join-Path $TargetDirectory 'qhyccd.dll'),'phd2-qhyccd.dll'),@($vendor,'ASCOM.QHYCCD.Camera.dll'),@($sdk,'qhyccd1-x86.dll'))){Copy-Item -LiteralPath $entry[0] -Destination (Join-Path $backup $entry[1]);if((Hash-File $entry[0]) -ne (Hash-File (Join-Path $backup $entry[1]))){throw 'Backup verification failed.'}}
        $generated=Join-Path $build 'ASCOM.QHY5RII.FastTransition.Camera.dll'
        & (Join-Path $PSScriptRoot 'tools\Phd2PatchBuilder.exe') $vendor $generated 2>&1 | Out-File (Join-Path $StateDirectory 'build.txt') -Encoding UTF8
        if($LASTEXITCODE -ne 0){throw 'Separate ASCOM patch generation failed.'}
        & (Join-Path $PSScriptRoot 'tools\DriverCheck.exe') metadata $generated (Join-Path $StateDirectory 'metadata-check.json')
        if($LASTEXITCODE -ne 0){throw 'Separate driver metadata validation failed.'}
        $plan=[ordered]@{InstallDirectory=(Join-Path ${env:CommonProgramFiles(x86)} 'ASCOM\Camera\QHY5RII-FastTransition-v0.1');OriginalDriver=$vendor;OriginalSDK=$sdk;GeneratedDriver=$generated;GeneratedSHA256=(Hash-File $generated);StateDirectory=$StateDirectory}
        $planPath=Join-Path $StateDirectory 'admin-plan.json';Save-Json $plan $planPath
        Invoke-AdminScript (Join-Path $PSScriptRoot 'Install-PHD2-Driver-Admin.ps1') @('-PlanPath',$planPath)
        $installed=Read-Json (Join-Path $StateDirectory 'admin-result.json');if($installed.Status -ne 'installed_verified'){throw 'Separate ASCOM registration did not verify.'}
        $profiles=$config.OpenSubKey('profile');$ids=@($profiles.GetSubKeyNames() | ForEach-Object {[int]$_});$profiles.Close();$newId=[int](($ids|Measure-Object -Maximum).Maximum)+1
        $newName=$originalName+' [QHY5RII fast switch]';$destination=$config.CreateSubKey(('profile\'+$newId))
        try {
            Copy-RegTree $source $destination;$destination.SetValue('name',$newName,[Microsoft.Win32.RegistryValueKind]::String);$destination.SetValue('NoiseReductionMethod',1,[Microsoft.Win32.RegistryValueKind]::DWord)
            $camera=$destination.CreateSubKey('camera')
            try {$camera.SetValue('LastMenuchoice','QHY5RII-C Fast Transition TEST (ASCOM)',[Microsoft.Win32.RegistryValueKind]::String);foreach($name in @('AutoLoadDarks','AutoLoadDefectMap','SaturationByADU')){$camera.SetValue($name,0,[Microsoft.Win32.RegistryValueKind]::DWord)};$camera.SetValue('binning',1,[Microsoft.Win32.RegistryValueKind]::DWord)}finally{$camera.Close()}
        }finally{$destination.Close();$source.Close()}
        $state=[ordered]@{Status='configured_verified';OriginalProfileId=$SourceProfileId;OriginalProfileName=$originalName;NewProfileId=$newId;NewProfileName=$newName;Driver=$installed.Driver;DriverSHA256=$installed.SHA256;ProgID=$installed.ProgID;Backup=$backup;ExposureValidation='pending_unsaturated_stable_light';At=[DateTimeOffset]::Now.ToString('o')}
        Save-Json $state $statePath
        $config.SetValue('currentProfile',$newId,[Microsoft.Win32.RegistryValueKind]::DWord)
        if([int]$config.GetValue('currentProfile') -ne $newId){throw 'Default PHD2 profile did not persist.'}
        $operation.Status='configured_verified';$operation.ProfileId=$newId;$operation.DefaultActive=$true;$operation.Message='Separate PHD2 ASCOM patch registered and selected as the default profile. The original driver and original profile remain available. Actual first-frame integration still needs a non-saturated image check.'
    }
    $config.Close();$user.Close();Save-Json $operation (Join-Path $StateDirectory 'operation.json');Show-Result $operation.Message $true $Quiet
} catch {$operation.Status='failed';$operation.Error=$_.Exception.Message;Save-Json $operation (Join-Path $StateDirectory 'operation.json');Show-Result $_.Exception.Message $false $Quiet;exit 1}
