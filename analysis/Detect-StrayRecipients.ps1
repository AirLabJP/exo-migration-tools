<#
.SYNOPSIS
  紛れ（Stray）受信者検出スクリプト

.DESCRIPTION
  EXOの受信者とADユーザーを突合し、Internal Relayを阻害する可能性がある
  「紛れ」受信者を検出します。

  【検出する問題】
  - STRAY_EXO_ONLY:    EXOにいるがADにいない（★最優先で対処）
  - DUPLICATE_IN_AD:   AD側で同じSMTPを複数保持（同期時にエラー）
  - MATCH_AD:          正常（ADと一致）

  【なぜ重要か】
  EXOにInternal Relayドメインを設定しても、EXO側に宛先アドレスを持つ
  受信者（メールボックス等）が存在すると、そこで配送が終了してしまい
  オンプレへ転送されません。これが「紛れ」問題です。

  【出力ファイル】
  stray_candidates.csv       ← 全検出結果
  strays_action_required.csv ← ★重要: STRAY_EXO_ONLYのみ（要対処）
  duplicates_in_ad.csv       ← AD側重複（要確認）
  summary.txt                ← 統計サマリー

.PARAMETER ExoRecipientsCsv
  EXO棚卸しのrecipients.csvパス

.PARAMETER AdUsersCsv
  AD棚卸しのad_users_mailattrs.csvパス

.PARAMETER AdGroupsCsv
  AD棚卸しのad_groups_mailattrs.csvパス（任意）

.PARAMETER TargetDomains
  対象ドメイン配列（例: @("example.co.jp","example.com")）

.PARAMETER TargetDomainsFile
  対象ドメイン一覧ファイル（1行1ドメイン）

.EXAMPLE
  # 単一ドメイン
  .\Detect-StrayRecipients.ps1 `
    -ExoRecipientsCsv C:\temp\inventory\exo_*\recipients.csv `
    -AdUsersCsv C:\temp\inventory\ad_*\ad_users_mailattrs.csv `
    -TargetDomains "example.co.jp"

.EXAMPLE
  # 複数ドメイン（ファイル指定）
  .\Detect-StrayRecipients.ps1 `
    -ExoRecipientsCsv C:\temp\inventory\exo_*\recipients.csv `
    -AdUsersCsv C:\temp\inventory\ad_*\ad_users_mailattrs.csv `
    -TargetDomainsFile domains.txt
#>
param(
  [Parameter(Mandatory=$true)][string]$ExoRecipientsCsv,
  [Parameter(Mandatory=$true)][string]$AdUsersCsv,
  [string]$AdGroupsCsv,
  [string[]]$TargetDomains,
  [string]$TargetDomainsFile,
  [string]$OutDir = ".\stray_report",
  [switch]$IncludeOnMicrosoft
)

#----------------------------------------------------------------------
# ドメインリストの読み込み
#----------------------------------------------------------------------
$domainList = @()
if ($TargetDomainsFile -and (Test-Path $TargetDomainsFile)) {
  $domainList = Get-Content $TargetDomainsFile | Where-Object { $_ -and $_ -notmatch '^\s*#' } | ForEach-Object { $_.Trim().ToLowerInvariant() }
} elseif ($TargetDomains) {
  $domainList = $TargetDomains | ForEach-Object { $_.Trim().ToLowerInvariant() }
} else {
  throw "エラー: -TargetDomains または -TargetDomainsFile を指定してください"
}

# 出力先フォルダ作成
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$OutDir = Join-Path $OutDir $ts
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Start-Transcript -Path (Join-Path $OutDir "run.log") -Force

Write-Host "============================================================"
Write-Host " 紛れ（Stray）受信者検出"
Write-Host "============================================================"
Write-Host "出力先: $OutDir"
Write-Host ""
Write-Host "対象ドメイン: $($domainList.Count) 件"
$domainList | ForEach-Object { Write-Host "  - $_" }
Write-Host ""

# ドメインサフィックスのハッシュテーブル（高速検索用）
$domainSuffixes = @{}
foreach ($d in $domainList) {
  $domainSuffixes["@$d"] = $true
}

#----------------------------------------------------------------------
# ヘルパー関数
#----------------------------------------------------------------------
function Normalize-Email([string]$s) {
  if ([string]::IsNullOrWhiteSpace($s)) { return $null }
  return $s.Trim().ToLowerInvariant()
}

function Extract-SmtpAddresses([string]$emailAddressesField) {
  if ([string]::IsNullOrWhiteSpace($emailAddressesField)) { return @() }
  
  $parts = $emailAddressesField -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
  $smtp = foreach ($p in $parts) {
    if ($p -match '^(smtp|SMTP):(.+)$') {
      Normalize-Email $Matches[2]
    } elseif ($IncludeOnMicrosoft -and $p -match '(.+@.+)$') {
      Normalize-Email $Matches[1]
    }
  }
  $smtp | Where-Object { $_ } | Select-Object -Unique
}

function Is-TargetDomain([string]$addr) {
  if ([string]::IsNullOrWhiteSpace($addr)) { return $false }
  $addrLower = $addr.ToLowerInvariant()
  foreach ($suffix in $domainSuffixes.Keys) {
    if ($addrLower.EndsWith($suffix)) { return $true }
  }
  return $false
}

function Get-MatchingDomain([string]$addr) {
  if ([string]::IsNullOrWhiteSpace($addr)) { return $null }
  $addrLower = $addr.ToLowerInvariant()
  foreach ($suffix in $domainSuffixes.Keys) {
    if ($addrLower.EndsWith($suffix)) { return $suffix.Substring(1) }
  }
  return $null
}

#----------------------------------------------------------------------
# CSV読み込み
#----------------------------------------------------------------------
Write-Host "[1/4] CSVファイルを読み込み中..."

$exo = Import-Csv $ExoRecipientsCsv
Write-Host "      → EXO受信者: $($exo.Count)"

$adUsers = Import-Csv $AdUsersCsv
Write-Host "      → ADユーザー: $($adUsers.Count)"

$adGroups = @()
if ($AdGroupsCsv -and (Test-Path $AdGroupsCsv)) {
  $adGroups = Import-Csv $AdGroupsCsv
  Write-Host "      → ADグループ: $($adGroups.Count)"
}

#----------------------------------------------------------------------
# ADアドレスインデックス作成
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[2/4] ADアドレスインデックスを作成中..."

$adIndex = @{}

function Add-ToIndex($key, $obj) {
  if (-not $adIndex.ContainsKey($key)) { $adIndex[$key] = @() }
  $adIndex[$key] += $obj
}

# ユーザーのインデックス作成
foreach ($u in $adUsers) {
  $keys = @()
  
  if ($u.mail) { $keys += (Normalize-Email $u.mail) }
  if ($u.proxyAddresses) {
    $keys += ( ($u.proxyAddresses -split ';') | ForEach-Object {
      $p = $_.Trim()
      if ($p -match '^(smtp|SMTP):(.+)$') { Normalize-Email $Matches[2] }
    })
  }
  
  foreach ($k in ($keys | Where-Object { $_ } | Select-Object -Unique)) {
    Add-ToIndex $k ([pscustomobject]@{
      Source="ADUser"
      SamAccountName=$u.SamAccountName
      UPN=$u.UserPrincipalName
      DisplayName=$u.DisplayName
      Enabled=$u.Enabled
    })
  }
}

# グループのインデックス作成
foreach ($g in $adGroups) {
  $keys = @()
  if ($g.mail) { $keys += (Normalize-Email $g.mail) }
  if ($g.proxyAddresses) {
    $keys += ( ($g.proxyAddresses -split ';') | ForEach-Object {
      $p = $_.Trim()
      if ($p -match '^(smtp|SMTP):(.+)$') { Normalize-Email $Matches[2] }
    })
  }
  
  foreach ($k in ($keys | Where-Object { $_ } | Select-Object -Unique)) {
    Add-ToIndex $k ([pscustomobject]@{
      Source="ADGroup"
      SamAccountName=$g.SamAccountName
      Name=$g.Name
      GroupCategory=$g.GroupCategory
      GroupScope=$g.GroupScope
    })
  }
}

Write-Host "      → インデックス済みアドレス: $($adIndex.Count)"

#----------------------------------------------------------------------
# EXO受信者のスキャン
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[3/4] ★ EXO受信者をスキャン中..."
Write-Host "      → 対象ドメインのアドレスを持つ受信者を検査"

$findings = New-Object System.Collections.Generic.List[object]

foreach ($r in $exo) {
  $primary = Normalize-Email $r.PrimarySmtpAddress
  # CSVのカラム名が日本語の場合も対応
  $emailAddressesRaw = if ($r.EmailAddresses) { $r.EmailAddresses } else { $r.PSObject.Properties["EmailAddresses"].Value }
  $emails = Extract-SmtpAddresses $emailAddressesRaw
  
  $all = @()
  if ($primary) { $all += $primary }
  $all += $emails
  $all = $all | Where-Object { $_ } | Select-Object -Unique
  
  $targetAddrs = $all | Where-Object { Is-TargetDomain $_ }
  
  if (-not $targetAddrs -or $targetAddrs.Count -eq 0) { continue }
  
  foreach ($addr in $targetAddrs) {
    $adHits = @()
    if ($adIndex.ContainsKey($addr)) { $adHits = $adIndex[$addr] }
    
    $status = if ($adHits.Count -eq 0) { 
      "STRAY_EXO_ONLY"       # EXOだけに存在（★地雷候補）
    } elseif ($adHits.Count -eq 1) { 
      "MATCH_AD"             # ADと一致（基本OK）
    } else { 
      "DUPLICATE_IN_AD"      # AD側で重複（事故候補）
    }
    
    # IsDirSynced判定
    $isDirSynced = $null
    if ($r.PSObject.Properties.Name -contains "IsDirSynced") {
      $isDirSynced = $r.IsDirSynced
    }
    
    $findings.Add([pscustomobject]@{
      ステータス = $status
      ドメイン = (Get-MatchingDomain $addr)
      対象アドレス = $addr
      EXO表示名 = $r.DisplayName
      EXO受信者タイプ = $r.RecipientType
      EXO受信者タイプ詳細 = $r.RecipientTypeDetails
      EXOプライマリSMTP = $primary
      EXO外部アドレス = $r.ExternalEmailAddress
      EXOIdentity = $r.Identity
      DirSync同期 = $isDirSynced
      ADヒット数 = $adHits.Count
      ADヒット詳細 = ($adHits | ConvertTo-Json -Compress -Depth 4)
    })
  }
}

#----------------------------------------------------------------------
# 結果出力
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[4/4] 結果を出力中..."

$findings | Sort-Object ステータス,対象アドレス |
  Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "stray_candidates.csv")

# ステータス別集計
$grp = $findings | Group-Object ステータス | Sort-Object Name
$grpByDomain = $findings | Group-Object ドメイン | Sort-Object Name

# STRAY_EXO_ONLYを別ファイルに出力（要対処）
$strays = $findings | Where-Object { $_.ステータス -eq "STRAY_EXO_ONLY" }
if ($strays.Count -gt 0) {
  $strays | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "strays_action_required.csv")
}

# DUPLICATE_IN_ADを別ファイルに出力（要確認）
$duplicates = $findings | Where-Object { $_.ステータス -eq "DUPLICATE_IN_AD" }
if ($duplicates.Count -gt 0) {
  $duplicates | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "duplicates_in_ad.csv")
}

#----------------------------------------------------------------------
# サマリー作成
#----------------------------------------------------------------------
$summary = @"
#===============================================================================
# 紛れ（Stray）受信者検出サマリー
#===============================================================================

【実行日時】$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
【対象ドメイン】$($domainList.Count) 件

【検出結果】
  総検出数: $($findings.Count)

  ステータス別:
$($grp | ForEach-Object { "    $($_.Name): $($_.Count)" } | Out-String)
  ドメイン別:
$($grpByDomain | ForEach-Object { 
  $strayCount = ($_.Group | Where-Object { $_.ステータス -eq "STRAY_EXO_ONLY" }).Count
  "    $($_.Name): $($_.Count) 件 (STRAY: $strayCount)"
} | Out-String)

#-------------------------------------------------------------------------------
# ステータスの意味
#-------------------------------------------------------------------------------

  ★ STRAY_EXO_ONLY（$($strays.Count) 件）
     → EXOにいるがADにいない
     → 【最優先で対処が必要】
     → このままだとInternal Relayが機能しない

  ⚠ DUPLICATE_IN_AD（$($duplicates.Count) 件）
     → AD側で同じSMTPを複数のオブジェクトが保持
     → Entra Connect同期でエラーになる可能性

  ✓ MATCH_AD
     → 正常（ADと一致している）

#-------------------------------------------------------------------------------
# 対処方法
#-------------------------------------------------------------------------------

  【STRAY_EXO_ONLYの場合】
  1. 削除: 不要なメールボックス/受信者ならEXOから削除
  2. 修正: 必要ならADにユーザーを作成してmail属性を設定
  3. 残す: 意図的にEXOのみで管理する場合は内部リレー対象外とする

  【DUPLICATE_IN_ADの場合】
  1. AD側で重複を解消（どちらか一方のproxyAddressesを修正）

#-------------------------------------------------------------------------------
# 確認すべきファイル
#-------------------------------------------------------------------------------

  ★ strays_action_required.csv
     → STRAY_EXO_ONLYのみ抽出（要対処）

  ★ duplicates_in_ad.csv
     → AD側重複（要確認）

  stray_candidates.csv
     → 全検出結果

"@

$summary | Out-File (Join-Path $OutDir "summary.txt") -Encoding UTF8

Write-Host ""
Write-Host "============================================================"
Write-Host " 完了"
Write-Host "============================================================"
Write-Host $summary

if ($strays.Count -gt 0) {
  Write-Host ""
  Write-Host "【警告】STRAY_EXO_ONLY が $($strays.Count) 件検出されました！"
  Write-Host "        → strays_action_required.csv を確認してください"
}

Stop-Transcript
Write-Host ""
Write-Host "出力先: $OutDir"
