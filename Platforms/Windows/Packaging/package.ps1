param(
    [ValidateSet('x64', 'ARM64')][string]$Architecture = 'x64',
    [string]$CertificateThumbprint,
    [string]$TimestampServer = 'http://timestamp.digicert.com',
    [string]$UpdateUri,
    [switch]$Unsigned
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot/../../..").Path
$project = "$root/Platforms/Windows/src/FoldGit.App/FoldGit.App.csproj"
$destination = "$root/dist/windows/$Architecture/"
[xml]$manifest = Get-Content "$root/Platforms/Windows/src/FoldGit.App/Package.appxmanifest"
$identity = $manifest.Package.Identity
if (-not $Unsigned -and -not $CertificateThumbprint) {
    throw 'Supply a trusted signing certificate thumbprint, or use -Unsigned for build validation only.'
}
if (-not $Unsigned) {
    $certificate = Get-Item "Cert:/CurrentUser/My/$CertificateThumbprint"
    if ($certificate.Subject -ne $identity.Publisher) {
        throw "The certificate subject must match the fixed MSIX Publisher identity $($identity.Publisher)."
    }
}
python "$root/Scripts/generate-resources.py" --check
if ($LASTEXITCODE -ne 0) { throw 'Shared resource validation failed.' }
$arguments = @('build', $project, '-c', 'Release', "-p:Platform=$Architecture",
    "-p:RuntimeIdentifier=win-$($Architecture.ToLowerInvariant())", '-p:GenerateAppxPackageOnBuild=true',
    '-p:UapAppxPackageBuildMode=SideloadOnly', "-p:AppxPackageDir=$destination", '-p:ContinuousIntegrationBuild=true')
if (-not $Unsigned) {
    $arguments += @('-p:AppxPackageSigningEnabled=true', "-p:PackageCertificateThumbprint=$CertificateThumbprint", "-p:AppxPackageSigningTimestampServerUrl=$TimestampServer")
}
dotnet @arguments
if ($LASTEXITCODE -ne 0) { throw 'MSIX build failed.' }
$package = Get-ChildItem $destination -Filter '*.msix' -Recurse | Select-Object -First 1
if (-not $package) { throw 'No MSIX package was produced.' }
Get-FileHash $package.FullName -Algorithm SHA256 | Format-List | Out-File "$destination/SHA256.txt" -Encoding utf8
if ($UpdateUri) {
    if ($Unsigned) { throw 'An App Installer feed requires a signed MSIX package.' }
    $uri = [Uri]$UpdateUri
    if ($uri.Scheme -ne 'https') { throw 'UpdateUri must use HTTPS.' }
    $feed = [System.Xml.XmlDocument]::new()
    $feed.LoadXml(@"
<?xml version="1.0" encoding="utf-8"?>
<AppInstaller xmlns="http://schemas.microsoft.com/appx/appinstaller/2018" Version="$($identity.Version)" Uri="$($uri.AbsoluteUri.TrimEnd('/'))/FoldGit-$Architecture.appinstaller">
  <MainPackage Name="$($identity.Name)" Publisher="$($identity.Publisher)" Version="$($identity.Version)" ProcessorArchitecture="$($Architecture.ToLowerInvariant())" Uri="$($uri.AbsoluteUri.TrimEnd('/'))/$($package.Name)" />
  <UpdateSettings><OnLaunch HoursBetweenUpdateChecks="12" ShowPrompt="true" UpdateBlocksActivation="false" /></UpdateSettings>
</AppInstaller>
"@)
    $feed.Save("$destination/FoldGit-$Architecture.appinstaller")
}
Write-Output $package.FullName
