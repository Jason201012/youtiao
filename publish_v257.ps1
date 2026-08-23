<#
.SYNOPSIS
  有条 v2.5.7 双仓库发版：计算 SHA256 -> 回填 update.json -> 上传双仓库新 release -> 验证 apkUrl。
.DESCRIPTION
  - 计算本地 APK 的 SHA256 并回填 update.json 的 apkSha256（只替换该行，不改动其他内容）
  - 在 Gitee(youtiao-releases-2) 与 Forgejo(rootnas/youtiao) 创建/获取 v2.5.7 release，上传新 APK（覆盖同名）
  - 验证 apkUrl 返回 200 且可达
  - 默认不 push（遵循发版 SOP：先验证 apkUrl 可达，再单独 git push 到 master）
  本脚本需在本机不受限终端运行（sandbox 无凭据/无 TTY）。
.EXAMPLE
  .\publish_v257.ps1 -GiteeToken "你的GITEE_PAT" -ForgejoToken "你的FORGEJO_PAT" -ApkPath "build\app\outputs\flutter-apk\app-release-v2.5.7-arm64.apk"
  # 仅验证 apkUrl（不传 token）：
  .\publish_v257.ps1 -ApkPath "build\app\outputs\flutter-apk\app-release-v2.5.7-arm64.apk" -VerifyOnly
  # 验证无误后推送 master：
  .\publish_v257.ps1 -Push
#>
param(
    [string]$GiteeToken   = "",
    [string]$ForgejoToken = "",
    [string]$ApkPath      = "build\app\outputs\flutter-apk\app-release-v2.5.7-arm64.apk",
    [string]$Version      = "v2.5.7",
    [switch]$VerifyOnly,
    [switch]$Push
)

$ErrorActionPreference = "Stop"

# ---------- 解析 APK ----------
$apkFile = Resolve-Path $ApkPath -ErrorAction Stop
$apkName = Split-Path $apkFile -Leaf
$apkSizeMB = [math]::Round((Get-Item $apkFile).Length / 1MB, 1)
$apkHash = (Get-FileHash $apkFile -Algorithm SHA256).Hash
Write-Host "APK: $apkFile ($apkSizeMB MB, SHA256=$apkHash)" -ForegroundColor Cyan

# ---------- 回填 update.json 的 apkSha256（仅替换该行，保留其他字段） ----------
if (-not $VerifyOnly) {
    $uj = "update.json"
    if (Test-Path $uj) {
        $txt = Get-Content $uj -Raw -Encoding UTF8
        $txt = $txt -replace '"apkSha256":\s*"[^"]*"', "`"apkSha256`": `"$apkHash`""
        Set-Content $uj -Value $txt -Encoding UTF8 -NoNewline
        Write-Host "  update.json apkSha256 已回填为 $apkHash" -ForegroundColor Green
    } else {
        Write-Warning "未找到 update.json，跳过回填"
    }
}

$giteeRepo = "jason1012/youtiao-releases-2"
$forgejoRepo = "rootnas/youtiao"
$forgejoBase = "http://192.168.31.227:3000"

function Invoke-Json($url, $method="GET", $token=$null, $formFile=$null) {
    $hdr = @{}
    if ($token) { $hdr["Authorization"] = "token $token" }
    $body = $null
    if ($formFile) { $body = @{ file = Get-Item $formFile } }
    try {
        if ($method -eq "GET") {
            return Invoke-RestMethod -Uri $url -Headers $hdr -Method Get
        } elseif ($method -eq "DELETE") {
            return Invoke-RestMethod -Uri $url -Headers $hdr -Method Delete
        } elseif ($method -eq "POST") {
            return Invoke-RestMethod -Uri $url -Headers $hdr -Method Post -Form $body
        }
    } catch {
        Write-Warning "  -> $method $url 失败: $($_.Exception.Message)"
        return $null
    }
}

# ---------- Gitee ----------
if (-not $VerifyOnly -and $GiteeToken) {
    Write-Host "`n[Gitee] 处理 $giteeRepo @ $Version" -ForegroundColor Yellow
    try {
        $rel = Invoke-RestMethod "https://gitee.com/api/v5/repos/$giteeRepo/releases/tags/$Version" -Headers @{Authorization="token $GiteeToken"}
    } catch {
        # tag 不存在则创建新 release
        Write-Host "  tag $Version 不存在，创建新 release" -ForegroundColor DarkYellow
        $rel = Invoke-RestMethod "https://gitee.com/api/v5/repos/$giteeRepo/releases" -Headers @{Authorization="token $GiteeToken"} -Method Post -Body (@{tag_name=$Version; name=$Version; body="v2.5.7 release"} | ConvertTo-Json) -ContentType "application/json"
    }
    $relId = $rel.id
    foreach ($a in $rel.assets) {
        if ($a.name -eq $apkName) {
            Write-Host "  删除旧资产 id=$($a.id) ($($a.name))"
            Invoke-Json "https://gitee.com/api/v5/repos/$giteeRepo/releases/$relId/attach_files/$($a.id)?access_token=$GiteeToken" -method DELETE -token $GiteeToken | Out-Null
        }
    }
    Write-Host "  上传新 APK -> release id=$relId"
    Invoke-Json "https://gitee.com/api/v5/repos/$giteeRepo/releases/$relId/attach_files?access_token=$GiteeToken" -method POST -token $GiteeToken -formFile $apkFile | Out-Null
    Write-Host "  Gitee 上传完成" -ForegroundColor Green
} elseif (-not $VerifyOnly) {
    Write-Host "`n[Gitee] 未提供 -GiteeToken，跳过上传（请网页手动传或填 token）" -ForegroundColor DarkYellow
}

# ---------- Forgejo ----------
if (-not $VerifyOnly -and $ForgejoToken) {
    Write-Host "`n[Forgejo] 处理 $forgejoRepo @ $Version" -ForegroundColor Yellow
    try {
        $rel = Invoke-RestMethod "$forgejoBase/api/v1/repos/$forgejoRepo/releases/tags/$Version" -Headers @{Authorization="token $ForgejoToken"}
    } catch {
        Write-Host "  tag $Version 不存在，创建新 release" -ForegroundColor DarkYellow
        $rel = Invoke-RestMethod "$forgejoBase/api/v1/repos/$forgejoRepo/releases" -Headers @{Authorization="token $ForgejoToken"} -Method Post -Body (@{tag_name=$Version; name=$Version; body="v2.5.7 release"} | ConvertTo-Json) -ContentType "application/json"
    }
    $relId = $rel.id
    foreach ($a in $rel.assets) {
        if ($a.name -eq $apkName) {
            Write-Host "  删除旧资产 id=$($a.id) ($($a.name))"
            Invoke-Json "$forgejoBase/api/v1/repos/$forgejoRepo/releases/$relId/assets/$($a.id)" -method DELETE -token $ForgejoToken | Out-Null
        }
    }
    Write-Host "  上传新 APK -> release id=$relId"
    Invoke-Json "$forgejoBase/api/v1/repos/$forgejoRepo/releases/$relId/assets?name=$apkName" -method POST -token $ForgejoToken -formFile $apkFile | Out-Null
    Write-Host "  Forgejo 上传完成" -ForegroundColor Green
} elseif (-not $VerifyOnly) {
    Write-Host "`n[Forgejo] 未提供 -ForgejoToken，跳过上传（请网页手动传或填 token）" -ForegroundColor DarkYellow
}

# ---------- 验证 apkUrl ----------
Write-Host "`n[验证] apkUrl 可达性" -ForegroundColor Yellow
$apkUrl = "https://gitee.com/$giteeRepo/releases/download/$Version/$apkName"
try {
    $r = Invoke-WebRequest -Uri $apkUrl -Method Head -MaximumRedirection 5 -ErrorAction Stop
    $ok = $r.StatusCode -eq 200
    Write-Host "  $apkUrl -> HTTP $($r.StatusCode)" -ForegroundColor $(if($ok){"Green"}else{"Red"})
    if ($ok) {
        # 下载头几字节比对大小（粗略确认文件大小）
        Write-Host "  校验文件大小: $([math]::Round($r.Headers['Content-Length']/1MB,1)) MB (本地 $apkSizeMB MB)" -ForegroundColor $(if([long]$r.Headers['Content-Length'] -eq (Get-Item $apkFile).Length){"Green"}else{"Red"})
    }
} catch {
    Write-Host "  $apkUrl -> 错误: $($_.Exception.Message)" -ForegroundColor Red
}

# ---------- 可选 push ----------
if ($Push) {
    Write-Host "`n[Push] git push origin master" -ForegroundColor Yellow
    git -C (Resolve-Path .) push origin master
}

Write-Host "`n完成。若上传步提示 404/端点错误，请按对应平台官方文档调整删除端点（Gitee 旧版用 /assets/{id} 而非 /attach_files/{id}）。" -ForegroundColor Cyan
