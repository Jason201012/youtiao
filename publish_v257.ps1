<#
.SYNOPSIS
  youtiao v2.5.7 dual-repo release: compute SHA256 -> patch update.json -> upload to Gitee+Forgejo -> verify apkUrl.
.DESCRIPTION
  - Compute SHA256 of the local APK and patch update.json apkSha256 (only that line, keep others)
  - On Gitee(youtiao-releases-2) and Forgejo(rootnas/youtiao): create/get v2.5.7 release, upload new APK
  - Verify apkUrl returns 200
  - Default does NOT push (per release SOP: verify apkUrl first, then git push separately)
  Run on local unrestricted terminal (sandbox has no creds / no TTY).
  NOTE: uses curl.exe for multipart uploads because PowerShell 5.1 Invoke-RestMethod lacks -Form.
.EXAMPLE
  .\publish_v257.ps1 -GiteeToken "YOUR_GITEE_PAT" -ForgejoToken "YOUR_FORGEJO_PAT" -ApkPath "build\app\outputs\flutter-apk\app-release-v2.5.7-arm64.apk"
  # verify only (no token):
  .\publish_v257.ps1 -ApkPath "build\app\outputs\flutter-apk\app-release-v2.5.7-arm64.apk" -VerifyOnly
  # push master after verification:
  .\publish_v 257.ps1 -Push
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

# ---------- resolve APK ----------
$apkFile = Resolve-Path $ApkPath -ErrorAction Stop
$apkName = Split-Path $apkFile -Leaf
$apkSizeMB = [math]::Round((Get-Item $apkFile).Length / 1MB, 1)
$apkHash = (Get-FileHash $apkFile -Algorithm SHA256).Hash
Write-Host "APK: $apkFile ($apkSizeMB MB, SHA256=$apkHash)" -ForegroundColor Cyan

# ---------- patch update.json apkSha256 (only that line) ----------
if (-not $VerifyOnly) {
    $uj = "update.json"
    if (Test-Path $uj) {
        $txt = Get-Content $uj -Raw -Encoding UTF8
        $txt = $txt -replace '"apkSha256":\s*"[^"]*"', ("`"apkSha256`": `"$apkHash`"")
        Set-Content $uj -Value $txt -Encoding UTF8 -NoNewline
        Write-Host "  update.json apkSha256 patched to $apkHash" -ForegroundColor Green
    } else {
        Write-Warning "update.json not found, skip patch"
    }
}

$giteeRepo = "jason1012/youtiao-releases-2"
$forgejoRepo = "rootnas/youtiao"
$forgejoBase = "http://192.168.31.227:3000"

# curl-based helper: GET json, POST json, or POST multipart file
function Invoke-Curl($method, $url, $token, $jsonBody=$null, $filePath=$null, $formField="file") {
    $argsList = @("-sS", "-X", $method, $url)
    if ($token) { $argsList += "-H"; $argsList += "Authorization: token $token" }
    if ($jsonBody) {
        $argsList += "-H"; $argsList += "Content-Type: application/json"
        $argsList += "-d"; $argsList += $jsonBody
    }
    if ($filePath) {
        $argsList += "-F"; $argsList += "$formField=@$filePath"
    }
    $raw = & curl.exe @argsList 2>&1
    return $raw
}

function Parse-Json($raw) {
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

# ---------- Gitee ----------
if (-not $VerifyOnly -and $GiteeToken) {
    Write-Host "`n[Gitee] handle $giteeRepo @ $Version" -ForegroundColor Yellow
    $rel = $null
    $raw = Invoke-Curl "GET" "https://gitee.com/api/v5/repos/$giteeRepo/releases/tags/$Version" $GiteeToken
    $rel = Parse-Json $raw
    if (-not $rel -or -not $rel.id) {
        Write-Host "  tag $Version missing, create tag + release" -ForegroundColor DarkYellow
        # Gitee requires the tag to exist before creating a release.
        # The create-tag endpoint expects formData fields: tag_name + refs (not JSON).
        $tagRaw = & curl.exe -sS -X POST "https://gitee.com/api/v5/repos/$giteeRepo/tags" `
            -F "access_token=$GiteeToken" -F "tag_name=$Version" -F "refs=master"
        $tagObj = Parse-Json $tagRaw
        if (-not $tagObj -or -not $tagObj.name) {
            Write-Warning "  FAILED to create tag. Raw response: $tagRaw"
        } else {
            Write-Host "  tag $Version created" -ForegroundColor Green
        }
        $body = "{`"tag_name`":`"$Version`",`"name`":`"$Version`",`"body`":`"v2.5.7 release`",`"target_commitish`":`"master`"}"
        $raw = Invoke-Curl "POST" "https://gitee.com/api/v5/repos/$giteeRepo/releases" $GiteeToken $body
        $rel = Parse-Json $raw
    }
    $relId = $rel.id
    if (-not $relId) {
        Write-Warning "  FAILED to get/create Gitee release. Raw response: $raw"
    } else {
        foreach ($a in $rel.assets) {
            if ($a.name -eq $apkName) {
                Write-Host "  delete old asset id=$($a.id) ($($a.name))"
                Invoke-Curl "DELETE" "https://gitee.com/api/v5/repos/$giteeRepo/releases/$relId/attach_files/$($a.id)?access_token=$GiteeToken" $GiteeToken | Out-Null
            }
        }
        Write-Host "  upload new APK -> release id=$relId"
        $up = Invoke-Curl "POST" "https://gitee.com/api/v5/repos/$giteeRepo/releases/$relId/attach_files?access_token=$GiteeToken" $GiteeToken $null $apkFile
        if ($up -match "error" -or $up -match "message") { Write-Warning "  Gitee upload response: $up" } else { Write-Host "  Gitee upload done" -ForegroundColor Green }
    }
} elseif (-not $VerifyOnly) {
    Write-Host "`n[Gitee] no -GiteeToken, skip upload (upload manually or provide token)" -ForegroundColor DarkYellow
}

# ---------- Forgejo ----------
if (-not $VerifyOnly -and $ForgejoToken) {
    Write-Host "`n[Forgejo] handle $forgejoRepo @ $Version" -ForegroundColor Yellow
    $rel = $null
    $raw = Invoke-Curl "GET" "$forgejoBase/api/v1/repos/$forgejoRepo/releases/tags/$Version" $ForgejoToken
    $rel = Parse-Json $raw
    if (-not $rel -or -not $rel.id) {
        Write-Host "  tag $Version missing, create new release" -ForegroundColor DarkYellow
        $body = "{`"tag_name`":`"$Version`",`"name`":`"$Version`",`"body`":`"v2.5.7 release`"}"
        $raw = Invoke-Curl "POST" "$forgejoBase/api/v1/repos/$forgejoRepo/releases" $ForgejoToken $body
        $rel = Parse-Json $raw
    }
    $relId = $rel.id
    if (-not $relId) {
        Write-Warning "  FAILED to get/create Forgejo release. Response: $raw"
    } else {
        foreach ($a in $rel.assets) {
            if ($a.name -eq $apkName) {
                Write-Host "  delete old asset id=$($a.id) ($($a.name))"
                Invoke-Curl "DELETE" "$forgejoBase/api/v1/repos/$forgejoRepo/releases/$relId/assets/$($a.id)" $ForgejoToken | Out-Null
            }
        }
        Write-Host "  upload new APK -> release id=$relId"
        $up = Invoke-Curl "POST" "$forgejoBase/api/v1/repos/$forgejoRepo/releases/$relId/assets?name=$apkName" $ForgejoToken $null $apkFile "attachment"
        if ($up -match "error" -or $up -match "message") { Write-Warning "  Forgejo upload response: $up" } else { Write-Host "  Forgejo upload done" -ForegroundColor Green }
    }
} elseif (-not $VerifyOnly) {
    Write-Host "`n[Forgejo] no -ForgejoToken,A skip upload (upload manually or provide token)" -ForegroundColor DarkYellow
}

# ---------- verify apkUrl ----------
Write-Host "`n[verify] apkUrl reachability" -ForegroundColor Yellow
$urls = @(
    "https://gitee.com/$giteeRepo/releases/download/$Version/$apkName",
    "$forgejoBase/releases/download/$Version/$apkName"
)
foreach ($apkUrl in $urls) {
    try {
        $r = Invoke-WebRequest -Uri $apkUrl -Method Head -MaximumRedirection 5 -ErrorAction Stop
        $ok = $r.StatusCode -eq 200
        Write-Host "  $apkUrl -> HTTP $($r.StatusCode)" -ForegroundColor $(if($ok){"Green"}else{"Red"})
        if ($ok) {
            $remoteSize = [long]$r.Headers['Content-Length']
            $localSize = (Get-Item $apkFile).Length
            Write-Host "    size: remote $([math]::Round($remoteSize/1MB,1)) MB vs local $apkSizeMB MB" -ForegroundColor $(if($remoteSize -eq $localSize){"Green"}else{"Red"})
        }
    } catch {
        Write-Host "  $apkUrl -> error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ---------- optional push ----------
if ($Push) {
    Write-Host "`n[Push] git push origin master" -ForegroundColor Yellow
    git -C (Resolve-Path .) push origin master
}

Write-Host "`nDone." -ForegroundColor Cyan
