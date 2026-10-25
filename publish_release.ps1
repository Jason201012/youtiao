<#
⚠️ 已废弃（L15，v3.0.9 审计）——v2.5.x 时代产物，请勿使用：
  - 目标 Gitee 仓库 jason1012/youtiao-releases-2 已退役（现为 youtiao-releases-4，
    APK only），Forgejo 侧也只保留 rootnas/youtiao 一仓；第三发布站为 NAS GitLab 8567
    （update.json 接入，apkSha256 pinning）。
  - 本脚本不含 update.json 签名 / apkSha256 写入 / 门禁哨兵，跑它只会产出
    「旧仓库上的旧格式资产」，与现行发版防线（_gate / _finalize / 双端验签 /
    _verify_vXXX_release）完全脱节。
  - 现行发版编排：仓库外脚本根目录（E:\TRAE SOLO\14\）按版本生成的 7 件套
    （_make/_build/_gate/_finalize/_push/_publish/_attach_apk_8567/
    create_8567_release/_verify_vXXX.py），见 _build2.py 废弃说明。
  保留本文件仅作历史存档，切勿对新版本执行。

.SYNOPSIS
  有条 v2.5.6 双仓库发版：替换 release 资产 APK + 验证 apkUrl。
.DESCRIPTION
  - 删除 Gitee(youtiao-releases-2) 与 Forgejo(rootnas/youtiao) v2.5.6 release 下已有的同名 APK 资产
  - 上传本地固定签名的新 APK（app-release-vX.Y.Z-arm64.apk）
  - 验证 apkUrl 返回 200
  - 默认不 push（遵循发版 SOP：先验证 apkUrl 可达，再单独 git push）
  本脚本需在本机不受限终端运行（sandbox 无凭据/无 TTY）。
.EXAMPLE
  .\publish_release.ps1 -GiteeToken "你的GITEE_PAT" -ForgejoToken "你的FORGEJO_PAT" -ApkPath "build\app\outputs\flutter-apk\app-release-v2.5.6-arm64.apk"
  # 仅验证（不传，token 留空）：
  .\publish_release.ps1 -ApkPath "build\app\outputs\flutter-apk\app-release-v2.5.6-arm64.apk" -VerifyOnly
#>
param(
    [string]$GiteeToken   = "",
    [string]$ForgejoToken = "",
    [string]$ApkPath      = "build\app\outputs\flutter-apk\app-release-v2.5.6-arm64.apk",
    [string]$Version      = "v2.5.6",
    [switch]$VerifyOnly,
    [switch]$Push
)

$apkFile = Resolve-Path $ApkPath -ErrorAction Stop
$apkName = Split-Path $apkFile -Leaf
$apkSizeMB = [math]::Round((Get-Item $apkFile).Length / 1MB, 1)
Write-Host "APK: $apkFile ($apkSizeMB MB, $((Get-FileHash $apkFile -Algorithm SHA256).Hash))" -ForegroundColor Cyan

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
    $rel = Invoke-RestMethod "https://gitee.com/api/v5/repos/$giteeRepo/releases/tags/$Version" -Headers @{Authorization="token $GiteeToken"}
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
    $rel = Invoke-RestMethod "$forgejoBase/api/v1/repos/$forgejoRepo/releases/tags/$Version" -Headers @{Authorization="token $ForgejoToken"}
    $relId = $rel.id
    foreach ($a in $rel.assets) {
        if ($a.name -eq $apkName) {
            Write-Host "  删除旧资产 id=$($a.id) ($($a.name))"
            Invoke-Json "$forgejoBase/api/v1/repos/$forgejoRepo/releases/$relId/assets/$($a.id)" -method DELETE -token $ForgejoToken | Out-Null
        }
    }
    Write-Host "  上传新 APK -> release id=$relId"
    # Forgejo 上传需要在 query 里带 name
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
    Write-Host "  $apkUrl -> HTTP $($r.StatusCode)" -ForegroundColor $(if($r.StatusCode -eq 200){"Green"}else{"Red"})
} catch {
    Write-Host "  $apkUrl -> 错误: $($_.Exception.Message)" -ForegroundColor Red
}

# ---------- 可选 push ----------
if ($Push) {
    Write-Host "`n[Push] git push origin master" -ForegroundColor Yellow
    git push origin master
}

Write-Host "`n完成。若上传步提示 404/端点错误，请按对应平台官方文档调整删除端点（Gitee 旧版用 /assets/{id} 而非 /attach_files/{id}）。" -ForegroundColor Cyan
