$ErrorActionPreference = 'Stop'
$root = Join-Path $env:USERPROFILE 'foldgit-cloud-debug'
$repo = Join-Path $root 'demo'
$git = Join-Path $root 'tools/git/cmd/git.exe'
$manifest = Join-Path $root 'logs/complex-demo.json'
$utf8 = New-Object Text.UTF8Encoding($false)
function DemoGit([string[]]$Arguments) {
    & $script:git -C $script:repo -c commit.gpgsign=false -c core.autocrlf=false @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Git failed: $Arguments" }
}
if (-not (Test-Path (Join-Path $repo '.git'))) { throw 'The cloud demo repository is missing.' }
if ((DemoGit -Arguments @('config', 'user.email')) -ne 'demo@foldgit.local') { throw 'This script only accepts the FoldGit cloud demo.' }
$version = & $git -C $repo config --get foldgit.complexDemoVersion
if ($version -eq '1') {
    Write-Host 'The complex demo already exists.'
    Get-Content $manifest
    return
}
if ((DemoGit -Arguments @('branch', '--show-current')) -ne 'main') { throw 'Select main before expanding the demo.' }
$names = @('develop', 'feature/history-search', 'feature/diff-review', 'feature/workspace-groups', 'release/0.2', 'hotfix/path-unicode', 'feature/accessibility')
$existing = @(DemoGit -Arguments @('for-each-ref', '--format=%(refname:short)', 'refs/heads'))
foreach ($name in $names) { if ($existing -contains $name) { throw "Branch already exists: $name" } }
foreach ($tag in @('v0.1.1-demo', 'v0.2.0-rc1-demo', 'v0.2.0-demo')) {
    & $git -C $repo show-ref --verify --quiet "refs/tags/$tag"
    if ($LASTEXITCODE -eq 0) { throw "Tag already exists: $tag" }
}
$gitDirectory = (DemoGit -Arguments @('rev-parse', '--absolute-git-dir')).Trim()
foreach ($state in @('MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'rebase-merge', 'rebase-apply')) {
    if (Test-Path (Join-Path $gitDirectory $state)) { throw 'Finish the current Git operation first.' }
}
Get-Process -Name 'FoldGit.App' -ErrorAction SilentlyContinue | Stop-Process
$backup = Join-Path $root ('backups/demo-before-complex-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item (Split-Path $backup) -ItemType Directory -Force | Out-Null
Copy-Item -LiteralPath $repo -Destination $backup -Recurse
$before = @(DemoGit -Arguments @('status', '--porcelain=v1', '--untracked-files=all')) -join "`n"
$base = (DemoGit -Arguments @('rev-parse', 'HEAD')).Trim()
$pending = $null
if ($before.Length -gt 0) {
    DemoGit -Arguments @('stash', 'push', '--include-untracked', '-m', 'FoldGit complex demo safety snapshot') | Out-Host
    $pending = (DemoGit -Arguments @('rev-parse', 'refs/stash')).Trim()
}
@{ backup = $backup; originalHead = $base; pendingSnapshot = $pending; originalStatus = $before } |
    ConvertTo-Json | Set-Content (Join-Path $root 'logs/complex-demo-recovery.json') -Encoding UTF8
$script:demoTime = [DateTimeOffset]::Now.AddHours(-2)
$script:step = 0
$authors = @('Alex Chen <alex@example.com>', 'Maya Patel <maya@example.com>', 'Sam Rivera <sam@example.com>', 'Lin Wang <lin@example.com>')
function Clock {
    $script:step++
    $stamp = $script:demoTime.AddMinutes($script:step * 2).ToString('o')
    $env:GIT_AUTHOR_DATE = $stamp
    $env:GIT_COMMITTER_DATE = $stamp
}
function CommitFile([string]$Path, [string]$Content, [string]$Message) {
    $destination = Join-Path $script:repo ('demo-history/' + $Path)
    New-Item (Split-Path $destination) -ItemType Directory -Force | Out-Null
    [IO.File]::WriteAllText($destination, $Content + "`n", $script:utf8)
    DemoGit -Arguments @('add', '--', ('demo-history/' + $Path)) | Out-Host
    Clock
    DemoGit -Arguments @('commit', '--author', $authors[($script:step - 1) % $authors.Length], '-m', $Message) | Out-Host
}
function MergeBranch([string]$Branch, [string]$Message) {
    Clock
    DemoGit -Arguments @('merge', '--no-ff', '--no-edit', '-m', $Message, '--', $Branch) | Out-Host
}
function SwitchBranch([string]$Branch) { DemoGit -Arguments @('switch', $Branch) | Out-Host }
function NewBranch([string]$Branch, [string]$Start) { DemoGit -Arguments @('switch', '-c', $Branch, $Start) | Out-Host }
NewBranch 'develop' $base
CommitFile 'development.json' '{"version":"0.2.0","channel":"development"}' 'chore: begin the 0.2 development cycle'
$fork = (DemoGit -Arguments @('rev-parse', 'HEAD')).Trim()
NewBranch 'feature/history-search' $fork
CommitFile 'SearchService.cs' 'public sealed class SearchService { public bool Matches(string text, string query) => text.Contains(query); }' 'feat: add author and message search'
CommitFile 'search-tests.md' 'Search scenarios: author, email, exact phrase, Unicode.' 'test: cover multilingual history queries'
NewBranch 'feature/diff-review' $fork
CommitFile 'DiffOptions.cs' 'public record DiffOptions(bool SideBySide, bool WordWrap);' 'feat: introduce side-by-side diff review'
CommitFile 'diff-tests.md' 'Verify renamed files, CRLF, binary content and stale hunks.' 'test: cover diff alignment and line endings'
NewBranch 'feature/workspace-groups' $fork
CommitFile 'WorkspaceGroup.cs' 'public record WorkspaceGroup(string Name, string[] Repositories);' 'feat: add workspace repository groups'
CommitFile 'workspace-tests.md' 'Verify group sorting, drag and drop, and session restore.' 'test: cover workspace group ordering'
SwitchBranch 'develop'
CommitFile 'integration.md' 'Integration checklist for search, diff review and workspace groups.' 'docs: prepare feature integration checklist'
MergeBranch 'feature/history-search' 'merge: integrate history search into develop'
SwitchBranch 'feature/history-search'
MergeBranch 'develop' 'merge: sync develop into history search'
CommitFile 'search-cancellation.md' 'Cancel superseded queries before presenting their results.' 'fix: cancel stale history search requests'
SwitchBranch 'develop'
MergeBranch 'feature/history-search' 'merge: finish history search cancellation'
SwitchBranch 'feature/diff-review'
MergeBranch 'develop' 'merge: sync search changes into diff review'
CommitFile 'diff-virtualization.md' 'Load visible file hunks on demand and retain scroll position.' 'perf: load diff hunks on demand'
SwitchBranch 'feature/workspace-groups'
CommitFile 'workspace-keyboard.md' 'Support keyboard selection and repository group navigation.' 'feat: add keyboard navigation for repository groups'
SwitchBranch 'develop'
MergeBranch 'feature/workspace-groups' 'merge: integrate workspace groups'
SwitchBranch 'feature/diff-review'
MergeBranch 'feature/workspace-groups' 'merge: align diff review with grouped workspaces'
SwitchBranch 'develop'
MergeBranch 'feature/diff-review' 'merge: integrate the native diff review workflow'
NewBranch 'release/0.2' 'develop'
CommitFile 'release-notes.md' '# Version 0.2 release candidate' 'docs: prepare 0.2 release notes'
CommitFile 'release-validation.md' 'Validate x64, ARM64, keyboard navigation and high DPI.' 'test: record release candidate validation'
DemoGit -Arguments @('tag', 'v0.2.0-rc1-demo') | Out-Host
SwitchBranch 'main'
CommitFile 'pipeline.md' 'Build native clients from the same shared resource revision.' 'ci: prepare native client release checks'
NewBranch 'hotfix/path-unicode' 'main'
CommitFile 'PathRules.cs' 'public static class PathRules { public static string Preserve(string path) => path; }' 'fix: preserve Unicode repository paths'
SwitchBranch 'main'
MergeBranch 'hotfix/path-unicode' 'merge: ship the Unicode path hotfix'
DemoGit -Arguments @('tag', 'v0.1.1-demo') | Out-Host
SwitchBranch 'release/0.2'
MergeBranch 'hotfix/path-unicode' 'merge: backport the path hotfix to release 0.2'
SwitchBranch 'develop'
CommitFile 'changelog.md' 'Search cancellation, grouped workspaces and native diff review are ready.' 'docs: summarize integrated workbench improvements'
NewBranch 'feature/accessibility' 'develop'
CommitFile 'AccessibilityLabels.cs' 'public record AccessibilityLabels(string Name, string HelpText);' 'feat: draft screen reader labels'
CommitFile 'accessibility-review.md' 'Pending review: focus order, high contrast and keyboard hints.' 'docs: outline accessibility review scenarios'
SwitchBranch 'release/0.2'
MergeBranch 'develop' 'merge: finalize development changes for release 0.2'
SwitchBranch 'main'
MergeBranch 'release/0.2' 'merge: release the native workbench 0.2'
DemoGit -Arguments @('tag', 'v0.2.0-demo') | Out-Host
if ($pending) { DemoGit -Arguments @('stash', 'apply', '--index', $pending) | Out-Host }
$after = @(DemoGit -Arguments @('status', '--porcelain=v1', '--untracked-files=all')) -join "`n"
if ($before -cne $after) { throw "Working changes differ from the backup. See $backup and logs/complex-demo-recovery.json." }
DemoGit -Arguments @('config', 'foldgit.complexDemoVersion', '1') | Out-Host
$result = @{
    repository = $repo
    backup = $backup
    originalHead = $base
    head = (DemoGit -Arguments @('rev-parse', 'HEAD')).Trim()
    mainCommits = [int](DemoGit -Arguments @('rev-list', '--count', 'HEAD'))
    allCommits = [int](DemoGit -Arguments @('rev-list', '--all', '--count'))
    merges = [int](DemoGit -Arguments @('rev-list', '--merges', '--count', 'HEAD'))
    branches = @(DemoGit -Arguments @('for-each-ref', '--format=%(refname:short)', 'refs/heads'))
    tags = @(DemoGit -Arguments @('tag', '--list'))
    workingChangesPreserved = $true
    pendingSnapshot = $pending
}
$result | ConvertTo-Json -Depth 5 | Set-Content $manifest -Encoding UTF8
Remove-Item Env:GIT_AUTHOR_DATE, Env:GIT_COMMITTER_DATE
DemoGit -Arguments @('log', '--graph', '--oneline', '--decorate', '--max-count=40') | Out-Host
Get-Content $manifest
