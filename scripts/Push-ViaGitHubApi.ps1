#requires -version 5.1
<#
.SYNOPSIS
    当 `git push` 被网络/代理挡住时，改用 GitHub REST API 推送一个本地提交（内容与本地提交一一对应）。
.DESCRIPTION
    适用场景：本机对 github.com 的 git-over-HTTPS 被阻断（TLS 握手失败/超时），但 api.github.com
    仍然可用。本脚本用 Git Data API 把「本地 HEAD 相对其父提交的改动」重建成远端提交：

        blob(逐文件, 内容取 `git cat-file blob`) -> tree(base_tree + 改动项) -> commit(同一作者/时间/信息) -> 更新 ref

    每步都会与本地 git 对象比对 SHA：
      · blob SHA 相等  => 文件内容完全一致
      · tree SHA 相等  => 目录结构完全一致
      · commit SHA 相等 => 远端提交与本地提交**逐字节等价**（不会产生分叉）

.PARAMETER Repository
    owner/repo，例如 StKGC/VScodeWithSyslab。

.PARAMETER Branch
    目标分支，默认 main。

.PARAMETER Commit
    要推送的本地提交，默认 HEAD。

.PARAMETER Token
    GitHub 令牌；默认取 $env:GITHUB_TOKEN / $env:GH_TOKEN / git 凭据管理器。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\Push-ViaGitHubApi.ps1 -Repository StKGC/VScodeWithSyslab
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repository,
    [string]$Branch = 'main',
    [string]$Commit = 'HEAD',
    [string]$Token
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$kitRoot = Split-Path -Parent $scriptRoot
. (Join-Path $kitRoot 'bin\vscode-kit.ps1')

function Write-Step([string]$Text) { Write-Host ''; Write-Host "=== $Text ===" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "  [OK]   $Text" -ForegroundColor Green }
function Write-Info([string]$Text) { Write-Host "  [信息] $Text" -ForegroundColor Gray }

function Invoke-GitHub {
    param([string]$Method, [string]$Uri, $Body)
    $headers = Get-GitHubHeaders -Token $script:Token
    if ($null -ne $Body) {
        $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 -Compress }
        # 必须发 UTF-8 字节，否则中文提交信息会破坏 JSON
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        return Invoke-RestMethod -Uri $Uri -Method $Method -Headers $headers -Body $bytes `
            -ContentType 'application/json; charset=utf-8' -TimeoutSec 300
    }
    return Invoke-RestMethod -Uri $Uri -Method $Method -Headers $headers -TimeoutSec 300
}

$script:Token = Get-GitHubToken -Token $Token
if (-not $script:Token) { throw '未找到 GitHub 令牌（-Token / $env:GITHUB_TOKEN / git 凭据管理器）' }

$repoRoot = (& git rev-parse --show-toplevel 2>$null)
if (-not $repoRoot) { throw '当前目录不是 git 仓库' }
$repoRoot = $repoRoot.Trim()

Write-Step "1/5 读取本地提交 $Commit"
$headSha = (& git -C $repoRoot rev-parse $Commit).Trim()
$parentSha = (& git -C $repoRoot rev-parse "$Commit~1").Trim()
$headTree = (& git -C $repoRoot rev-parse "$Commit^{tree}").Trim()
$parentTree = (& git -C $repoRoot rev-parse "$Commit~1^{tree}").Trim()
$message = (& git -C $repoRoot log -1 --format=%B $Commit) -join "`n"
$authorName = (& git -C $repoRoot log -1 --format=%an $Commit).Trim()
$authorEmail = (& git -C $repoRoot log -1 --format=%ae $Commit).Trim()
$authorDate = (& git -C $repoRoot log -1 --format=%aI $Commit).Trim()
$committerName = (& git -C $repoRoot log -1 --format=%cn $Commit).Trim()
$committerEmail = (& git -C $repoRoot log -1 --format=%ce $Commit).Trim()
$committerDate = (& git -C $repoRoot log -1 --format=%cI $Commit).Trim()
Write-Ok "本地提交 : $headSha"
Write-Ok "父提交   : $parentSha"
Write-Ok "主题     : $((& git -C $repoRoot log -1 --format=%s $Commit).Trim())"

Write-Step '2/5 校验远端状态'
$ref = Invoke-GitHub -Method Get -Uri "https://api.github.com/repos/$Repository/git/ref/heads/$Branch"
$remoteSha = $ref.object.sha
Write-Info "远端 $Branch : $remoteSha"
if ($remoteSha -ne $parentSha) {
    throw "远端 $Branch 不在本地提交的父提交上（远端 $remoteSha != 本地父 $parentSha）。请先对齐历史再推送。"
}
$remoteCommit = Invoke-GitHub -Method Get -Uri "https://api.github.com/repos/$Repository/git/commits/$remoteSha"
if ($remoteCommit.tree.sha -ne $parentTree) {
    throw "远端 tree($($remoteCommit.tree.sha)) 与本地父 tree($parentTree) 不一致，停止推送。"
}
Write-Ok '远端 HEAD 与本地父提交完全一致，可以推送'

Write-Step '3/5 上传改动文件为 blob'
$nameStatus = & git -C $repoRoot diff-tree -r --no-commit-id --name-status "$Commit~1" $Commit
$tempDir = Join-Path $env:TEMP ('gh-api-push-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
$entries = @()
try {
    foreach ($line in $nameStatus) {
        if (-not $line) { continue }
        $parts = $line -split "`t"
        $status = $parts[0]
        $path = $parts[-1]

        if ($status -eq 'D') {
            $entries += @{ path = $path; mode = '100644'; type = 'blob'; sha = $null }
            Write-Info "删除 $path"
            continue
        }

        $blobSha = (& git -C $repoRoot rev-parse "$Commit`:$path").Trim()
        $tempFile = Join-Path $tempDir ($blobSha)
        # 用 cmd 重定向取出 blob 原始字节（PowerShell 管道会改动换行）
        cmd /c "git -C `"$repoRoot`" cat-file blob $blobSha > `"$tempFile`"" | Out-Null
        $base64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($tempFile))
        $created = Invoke-GitHub -Method Post -Uri "https://api.github.com/repos/$Repository/git/blobs" -Body @{
            content  = $base64
            encoding = 'base64'
        }
        if ($created.sha -ne $blobSha) {
            throw "blob SHA 不一致（$path）：远端 $($created.sha) != 本地 $blobSha"
        }
        $entries += @{ path = $path; mode = '100644'; type = 'blob'; sha = $blobSha }
        Write-Ok ("{0} {1}" -f $status, $path)
    }
}
finally {
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Step '4/5 创建 tree 与 commit（与本地逐字节等价）'
$tree = Invoke-GitHub -Method Post -Uri "https://api.github.com/repos/$Repository/git/trees" -Body @{
    base_tree = $parentTree
    tree      = $entries
}
if ($tree.sha -ne $headTree) {
    throw "tree SHA 不一致：远端 $($tree.sha) != 本地 $headTree（可能有文件被 .gitattributes 改写，或漏了改动）"
}
Write-Ok "tree 一致：$($tree.sha)"

$commitBody = @{
    message   = $message
    tree      = $tree.sha
    parents   = @($parentSha)
    author    = @{ name = $authorName; email = $authorEmail; date = $authorDate }
    committer = @{ name = $committerName; email = $committerEmail; date = $committerDate }
}
$newCommit = Invoke-GitHub -Method Post -Uri "https://api.github.com/repos/$Repository/git/commits" -Body $commitBody
if ($newCommit.sha -ne $headSha) {
    Write-Host ''
    Write-Warn2 "提交 SHA 与本地不同：远端 $($newCommit.sha) / 本地 $headSha"
    Write-Warn2 "内容一致但哈希不同（通常是作者/时间字段差异）。远端已可正常使用，"
    Write-Warn2 "网络恢复后执行：git fetch origin && git reset --hard origin/$Branch 对齐本地。"
}
else {
    Write-Ok "commit 一致：$($newCommit.sha)"
}

Write-Step "5/5 更新 refs/heads/$Branch"
$updated = Invoke-GitHub -Method Patch -Uri "https://api.github.com/repos/$Repository/git/refs/heads/$Branch" -Body @{
    sha   = $newCommit.sha
    force = $false
}
Write-Ok "远端 $Branch -> $($updated.object.sha)"
Write-Host ''
Write-Host "推送完成：https://github.com/$Repository/commit/$($newCommit.sha)" -ForegroundColor Green
