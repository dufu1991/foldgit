param(
    [ValidateSet('Build', 'Compile', 'Launch')][string]$Phase = 'Build',
    [string]$SdkDirectory,
    [switch]$ServerCompatibility
)
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:USERPROFILE 'foldgit-cloud-debug'
$source = Join-Path $root 'source'
$app = Join-Path $root 'app'
$tools = Join-Path $root 'tools'
$logs = Join-Path $root 'logs'
$demo = Join-Path $root 'demo'
New-Item $tools, $logs -ItemType Directory -Force | Out-Null
$statusPath = Join-Path $root 'status.json'
function Status([string]$stage, [string]$detail) {
    @{ stage = $stage; detail = $detail; time = [DateTimeOffset]::Now.ToString('O') } |
        ConvertTo-Json | Set-Content $statusPath -Encoding UTF8
    Write-Host "[$stage] $detail"
}
function Git([string[]]$Arguments, [string]$Directory = $demo) {
    Push-Location $Directory
    try {
        & $script:git @Arguments
        if ($LASTEXITCODE -ne 0) { throw "Git failed: $Arguments" }
    }
    finally { Pop-Location }
}
function DotNet([string[]]$Arguments, [string]$Log) {
    $process = Start-Process $script:dotnet -ArgumentList $Arguments -WorkingDirectory $source `
        -RedirectStandardOutput $Log -RedirectStandardError "$Log.stderr" -NoNewWindow -Wait -PassThru
    Get-Content "$Log.stderr" -Encoding UTF8 | Add-Content $Log -Encoding UTF8
    if ($process.ExitCode -ne 0) { throw "dotnet exited with code $($process.ExitCode). See $Log." }
}
try {
    $os = Get-CimInstance Win32_OperatingSystem
    $environment = @{ caption = $os.Caption; version = $os.Version; build = $os.BuildNumber; architecture = $os.OSArchitecture; compatibility = [bool]$ServerCompatibility }
    $environment | ConvertTo-Json | Set-Content (Join-Path $logs 'environment.json') -Encoding UTF8
    if ([int]$os.BuildNumber -lt 26100 -and -not $ServerCompatibility) {
        throw 'The standard build requires OS Build 26100 or later. Use -ServerCompatibility only for the older Server Debug session.'
    }
    if (-not $SdkDirectory) {
        $SdkDirectory = Join-Path $tools 'dotnet'
        if (-not (Test-Path (Join-Path $SdkDirectory 'dotnet.exe'))) {
            $installedDotnet = Get-Command dotnet.exe -ErrorAction SilentlyContinue
            if ($installedDotnet) { $SdkDirectory = Split-Path $installedDotnet.Source }
        }
    }
    $script:dotnet = Join-Path $SdkDirectory 'dotnet.exe'
    if (-not (Test-Path $dotnet)) { throw 'Supply the directory of an existing .NET 10 SDK with -SdkDirectory.' }
    $env:DOTNET_ROOT = $SdkDirectory
    $env:DOTNET_CLI_HOME = Join-Path $root 'dotnet-home'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $env:DOTNET_NOLOGO = '1'
    $env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
    $env:MSBUILDDISABLENODEREUSE = '1'
    if (-not $env:NUGET_PACKAGES) { $env:NUGET_PACKAGES = Join-Path $root 'nuget' }
    $script:git = Join-Path $tools 'git/cmd/git.exe'
    $env:PATH = (Split-Path $script:git) + ';' + $env:PATH
    if ($Phase -eq 'Launch') {
        $executable = Join-Path $app 'FoldGit.App.exe'
        if (-not (Test-Path $executable)) { throw 'Build the current sources before launching.' }
        Get-Process -Name 'FoldGit.App' -ErrorAction SilentlyContinue | Stop-Process
        $env:FOLDGIT_DEBUG_REPOSITORY = $demo
        $process = Start-Process $executable -WorkingDirectory $app -PassThru
        Start-Sleep -Seconds 3
        if ($process.HasExited) { throw "FoldGit exited with code $($process.ExitCode)." }
        Status 'running' "PID $($process.Id), $executable"
        return
    }
    Status 'tools' 'Preparing a portable Git installation.'
    if (-not (Test-Path $script:git)) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $archive = Join-Path $tools 'mingit.zip'
        Invoke-WebRequest 'https://github.com/git-for-windows/git/releases/download/v2.56.0.windows.4/MinGit-2.56.0.4-64-bit.zip' -OutFile $archive -UseBasicParsing
        $expected = 'e3bf78351fe777fba47ddee5950082f8a98bb0f02604fdc7ba3ee2cb68ffa877'
        if ((Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) { throw 'Portable Git checksum mismatch.' }
        Expand-Archive $archive (Join-Path $tools 'git') -Force
    }
    & $script:git --version
    Push-Location $source
    try {
        if ($Phase -eq 'Build') {
            Status 'tests' 'Running real-repository C# behavior tests.'
            DotNet -Arguments @('run', '--project', 'Platforms/Windows/tests/FoldGit.Core.Tests', '-p:UseSharedCompilation=false') -Log (Join-Path $logs 'core-tests.log')
            DotNet -Arguments @('run', '--project', 'Platforms/Windows/tests/FoldGit.Workbench.Tests', '-p:UseSharedCompilation=false') -Log (Join-Path $logs 'workbench-tests.log')
        }
        Status 'build' "Compiling WinUI and XAML on $($os.Caption), Build $($os.BuildNumber); older-Server compatibility: $ServerCompatibility."
        DotNet -Arguments @('publish', 'Platforms/Windows/src/FoldGit.App', '-c', 'Debug', '-p:Platform=x64', '-r', 'win-x64',
            '-p:FoldGitCloudDebug=true', "-p:FoldGitCloudCompatibility=$($ServerCompatibility.IsPresent.ToString().ToLowerInvariant())", '-p:SkipResourceValidation=true', '-p:UseSharedCompilation=false', '-o', $app) -Log (Join-Path $logs 'build.log')
        if (-not (Test-Path (Join-Path $app 'FoldGit.App.pri'))) { throw 'The published application is missing its XAML resource index.' }
    }
    finally { Pop-Location }
    Status 'demo' 'Preparing the demo repository.'
    if (-not (Test-Path (Join-Path $demo '.git'))) {
        New-Item (Join-Path $demo 'src/components'), (Join-Path $demo 'docs') -ItemType Directory -Force | Out-Null
        Git -Arguments @('init', '--initial-branch=main')
        Git -Arguments @('config', 'user.name', 'FoldGit Demo')
        Git -Arguments @('config', 'user.email', 'demo@foldgit.local')
        Git -Arguments @('config', 'commit.gpgsign', 'false')
        Git -Arguments @('config', 'core.autocrlf', 'false')
        $utf8 = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText((Join-Path $demo 'README.md'), "# FoldGit Windows Demo`n`nA native Git workbench demonstration.`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $demo 'src/Greeting.cs'), "namespace Demo;`npublic static class Greeting { public static string Hello() => `"Hello, Windows!`"; }`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $demo 'package.json'), '{"name":"foldgit-demo","version":"0.1.0"}', $utf8)
        [IO.File]::WriteAllText((Join-Path $demo 'src/components/Button.vue'), '<template><button>FoldGit</button></template>', $utf8)
        Copy-Item (Join-Path $source 'Shared/Resources/Branding/Images/FoldGit.png') (Join-Path $demo 'docs/preview.png')
        Git -Arguments @('add', '--all'); Git -Arguments @('commit', '-m', 'feat: create native Windows demo')
        for ($i = 1; $i -le 5; $i++) {
            [IO.File]::AppendAllText((Join-Path $demo 'README.md'), "`nDemo checkpoint $i.`n", $utf8)
            Git -Arguments @('add', '--all'); Git -Arguments @('commit', '-m', "docs: add checkpoint $i")
        }
        Git -Arguments @('switch', '-c', 'feature/sidebar')
        [IO.File]::WriteAllText((Join-Path $demo 'src/sidebar.ts'), "export const sidebar = ['History', 'Branches', 'Worktrees'];`n", $utf8)
        Git -Arguments @('add', '--all'); Git -Arguments @('commit', '-m', 'feat: add repository sidebar')
        Git -Arguments @('switch', 'main')
        [IO.File]::AppendAllText((Join-Path $demo 'README.md'), "`nThe workbench supports grouped repositories.`n", $utf8)
        Git -Arguments @('add', '--all'); Git -Arguments @('commit', '-m', 'docs: describe grouped repositories')
        Git -Arguments @('merge', '--no-ff', 'feature/sidebar', '-m', 'feat: merge sidebar navigation')
        Git -Arguments @('tag', 'v0.1.0-demo')
        [IO.File]::WriteAllText((Join-Path $demo 'docs/saved-notes.md'), 'Saved work for the stash preview.', $utf8)
        Git -Arguments @('stash', 'push', '--include-untracked', '--message', 'Demo saved work')
        $linked = Join-Path $root 'demo-linked'
        Git -Arguments @('worktree', 'add', '-b', 'feature/worktree', '--', $linked)
        [IO.File]::WriteAllText((Join-Path $linked 'worktree.txt'), 'Worktree sample', $utf8)
        Git -Arguments @('add', '--all') -Directory $linked; Git -Arguments @('commit', '-m', 'feat: add linked worktree sample') -Directory $linked
        [IO.File]::WriteAllText((Join-Path $demo 'src/Greeting.cs'), "namespace Demo;`npublic static class Greeting { public static string Hello() => `"Hello, FoldGit!`"; }`n", $utf8)
        Git -Arguments @('add', '--', 'src/Greeting.cs')
        [IO.File]::AppendAllText((Join-Path $demo 'README.md'), "`nUnstaged changes are ready for review.`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $demo 'src/new-file.ts'), "export const platform = 'Windows';`n", $utf8)
    }
    Status 'ready' "Build passed. Demo: $demo. Run this script with -Phase Launch."
}
catch {
    Status 'failed' $_.Exception.Message
    throw
}
