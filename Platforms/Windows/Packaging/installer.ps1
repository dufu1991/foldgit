param(
    [ValidateSet('x64', 'ARM64')][string]$Architecture = 'x64',
    [string]$CertificateThumbprint,
    [string]$TimestampServer = 'http://timestamp.digicert.com',
    [string]$CompilerPath = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot/../../..").Path
$project = "$root/Platforms/Windows/src/FoldGit.App/FoldGit.App.csproj"
$destination = "$root/dist/windows/$Architecture/installer"
$publish = "$destination/app"
if (-not (Test-Path $CompilerPath)) { throw 'Install Inno Setup 6 before building the Windows installer.' }
$version = python "$root/Scripts/version.py"
if ($LASTEXITCODE -ne 0) { throw 'Version validation failed.' }

dotnet publish $project -c Release -r "win-$($Architecture.ToLowerInvariant())" "-p:Platform=$Architecture" -p:WindowsPackageType=None `
    -p:GenerateAppxPackageOnBuild=false -p:SelfContained=true -p:WindowsAppSDKSelfContained=true `
    -p:PublishSingleFile=false -p:PublishTrimmed=false -p:ContinuousIntegrationBuild=true -o $publish | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Windows application publishing failed.' }
foreach ($file in @('FoldGit.App.exe', 'FoldGit.App.dll', 'Microsoft.UI.Xaml.dll', 'Assets/MaterialFileIcons.json', 'Assets/LICENSE.txt')) {
    if (-not (Test-Path (Join-Path $publish $file))) { throw "Missing installer content: $file" }
}

if ($CertificateThumbprint) {
    $signTool = Get-ChildItem "${env:ProgramFiles(x86)}/Windows Kits/10/bin/*/x64/signtool.exe" |
        Sort-Object FullName -Descending | Select-Object -First 1
    if (-not $signTool) { throw 'The Windows SDK signing tool is required for signed installers.' }
    & $signTool.FullName sign /sha1 $CertificateThumbprint /fd SHA256 /tr $TimestampServer /td SHA256 "$publish/FoldGit.App.exe" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Windows executable signing failed.' }
}

$allowedArchitecture = if ($Architecture -eq 'ARM64') { 'arm64' } else { 'x64compatible' }
& $CompilerPath "/DAppVersion=$version" "/DArchitecture=$Architecture" "/DAllowedArchitecture=$allowedArchitecture" `
    "/DPublishDirectory=$publish" "/DOutputDirectory=$destination" "$PSScriptRoot/FoldGit.iss" | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Windows installer compilation failed.' }
$installer = "$destination/FoldGit-$version-Windows-$Architecture.exe"
if ($CertificateThumbprint) {
    & $signTool.FullName sign /sha1 $CertificateThumbprint /fd SHA256 /tr $TimestampServer /td SHA256 $installer | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Windows installer signing failed.' }
}
Write-Output $installer
