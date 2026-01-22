<#
.SYNOPSIS
  SMTP重複チェックスクリプト

.DESCRIPTION
  AD投入前にCSVファイルを検証し、SMTPアドレスの重複を検出します。
  スキーマ拡張後、メール属性投入前に実行してください。

  【検出する問題】
  - CSV内重複:   同じCSV内で同じSMTPが複数行に存在
  - AD競合:      既存ADユーザーと同じSMTPを使おうとしている

  【出力ファイル】
  csv_duplicates.csv    ← CSV内の重複
  ad_conflicts.csv      ← 既存ADとの競合
  validation_errors.csv ← 形式エラー
  summary.txt           ← 結果サマリー

.PARAMETER CsvPath
  投入予定のCSVファイルパス
  必須カラム: UserPrincipalName or SamAccountName, PrimarySmtpAddress
  任意カラム: Aliases（セミコロン区切り）

.PARAMETER AdUsersCsv
  既存AD棚卸しCSV（省略時はADに直接問い合わせ）

.PARAMETER OutDir
  出力先フォルダ

.PARAMETER CheckAdDirect
  ADに直接問い合わせて重複チェック（ADモジュール必要）

.EXAMPLE
  # 棚卸しCSVと突合
  .\Test-SmtpDuplicates.ps1 `
    -CsvPath mail_addresses.csv `
    -AdUsersCsv C:\temp\inventory\ad_*\ad_users_mailattrs.csv

.EXAMPLE
  # ADに直接問い合わせ
  .\Test-SmtpDuplicates.ps1 -CsvPath mail_addresses.csv -CheckAdDirect
#>
param(
  [Parameter(Mandatory=$true)][string]$CsvPath,
  [string]$AdUsersCsv,
  [string]$OutDir = ".\duplicate_check",
  [switch]$CheckAdDirect
)

# 出力先フォルダ作成
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$OutDir = Join-Path $OutDir $ts
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Start-Transcript -Path (Join-Path $OutDir "run.log") -Force

Write-Host "============================================================"
Write-Host " SMTP 重複チェック"
Write-Host "============================================================"
Write-Host "入力CSV: $CsvPath"
Write-Host "出力先:  $OutDir"
Write-Host ""

#----------------------------------------------------------------------
# ヘルパー関数
#----------------------------------------------------------------------
function Normalize-Email([string]$s) {
  if ([string]::IsNullOrWhiteSpace($s)) { return $null }
  return $s.Trim().ToLowerInvariant()
}

function Validate-Email([string]$smtp) {
  if ([string]::IsNullOrWhiteSpace($smtp)) { return $false }
  return ($smtp -match '^[^@\s]+@[^@\s]+\.[^@\s]+$')
}

#----------------------------------------------------------------------
# CSV読み込み
#----------------------------------------------------------------------
Write-Host "[1/4] CSVファイルを読み込み中..."

if (-not (Test-Path $CsvPath)) {
  throw "エラー: CSVファイルが見つかりません: $CsvPath"
}

$rows = Import-Csv $CsvPath
Write-Host "      → 行数: $($rows.Count)"

#----------------------------------------------------------------------
# SMTP→行のマッピング作成
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[2/4] SMTPアドレスを検証中..."

$smtpToRows = @{}  # key: smtp, value: 行識別子のリスト
$validationErrors = New-Object System.Collections.Generic.List[object]

foreach ($row in $rows) {
  $identity = if ($row.UserPrincipalName) { $row.UserPrincipalName } else { $row.SamAccountName }
  
  # 識別子がない行
  if (-not $identity) {
    $validationErrors.Add([pscustomobject]@{
      種別 = "識別子なし"
      識別子 = "(不明)"
      SMTP = ""
      メッセージ = "UserPrincipalName または SamAccountName が空です"
    })
    continue
  }
  
  # プライマリSMTPが空
  $primary = Normalize-Email $row.PrimarySmtpAddress
  if (-not $primary) {
    $validationErrors.Add([pscustomobject]@{
      種別 = "プライマリSMTP空"
      識別子 = $identity
      SMTP = ""
      メッセージ = "PrimarySmtpAddress が空です"
    })
    continue
  }
  
  # プライマリSMTPの形式チェック
  if (-not (Validate-Email $primary)) {
    $validationErrors.Add([pscustomobject]@{
      種別 = "形式エラー（プライマリ）"
      識別子 = $identity
      SMTP = $primary
      メッセージ = "メールアドレスの形式が不正です"
    })
    continue
  }
  
  # このユーザーの全SMTPを収集
  $smtps = @($primary)
  if ($row.Aliases) {
    $aliases = $row.Aliases -split ';' | ForEach-Object { Normalize-Email $_ } | Where-Object { $_ }
    foreach ($alias in $aliases) {
      if (-not (Validate-Email $alias)) {
        $validationErrors.Add([pscustomobject]@{
          種別 = "形式エラー（エイリアス）"
          識別子 = $identity
          SMTP = $alias
          メッセージ = "メールアドレスの形式が不正です"
        })
      } else {
        $smtps += $alias
      }
    }
  }
  
  # マッピングに追加
  foreach ($smtp in ($smtps | Select-Object -Unique)) {
    if (-not $smtpToRows.ContainsKey($smtp)) {
      $smtpToRows[$smtp] = @()
    }
    $smtpToRows[$smtp] += $identity
  }
}

Write-Host "      → ユニークSMTP数: $($smtpToRows.Count)"
Write-Host "      → 形式エラー: $($validationErrors.Count)"

#----------------------------------------------------------------------
# CSV内重複チェック
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[3/4] ★ CSV内の重複をチェック中..."

$csvDuplicates = New-Object System.Collections.Generic.List[object]

foreach ($smtp in $smtpToRows.Keys) {
  $owners = $smtpToRows[$smtp]
  if ($owners.Count -gt 1) {
    $csvDuplicates.Add([pscustomobject]@{
      SMTP = $smtp
      重複数 = $owners.Count
      所有者 = ($owners -join "; ")
    })
  }
}

if ($csvDuplicates.Count -gt 0) {
  Write-Host "      → 【エラー】$($csvDuplicates.Count) 件の重複を検出！"
  $csvDuplicates | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "csv_duplicates.csv")
} else {
  Write-Host "      → OK: CSV内に重複なし"
}

#----------------------------------------------------------------------
# 既存ADとの競合チェック
#----------------------------------------------------------------------
$adConflicts = New-Object System.Collections.Generic.List[object]

if ($AdUsersCsv -and (Test-Path $AdUsersCsv)) {
  Write-Host ""
  Write-Host "[4/4] ★ 既存ADとの競合をチェック中..."
  
  $adUsers = Import-Csv $AdUsersCsv
  
  # ADのSMTPインデックス作成
  $adSmtpIndex = @{}
  foreach ($u in $adUsers) {
    $adIdentity = $u.SamAccountName
    
    if ($u.mail) {
      $mail = Normalize-Email $u.mail
      if ($mail) { $adSmtpIndex[$mail] = $adIdentity }
    }
    
    if ($u.proxyAddresses) {
      $proxies = $u.proxyAddresses -split ';' | ForEach-Object {
        $p = $_.Trim()
        if ($p -match '^(smtp|SMTP):(.+)$') { Normalize-Email $Matches[2] }
      }
      foreach ($proxy in ($proxies | Where-Object { $_ })) {
        $adSmtpIndex[$proxy] = $adIdentity
      }
    }
  }
  
  # 入力CSVの各SMTPをADと照合
  foreach ($smtp in $smtpToRows.Keys) {
    if ($adSmtpIndex.ContainsKey($smtp)) {
      $csvOwners = $smtpToRows[$smtp]
      $adOwner = $adSmtpIndex[$smtp]
      
      # 同一ユーザーの更新かどうか判定
      $isSameUser = $false
      foreach ($csvOwner in $csvOwners) {
        if ($csvOwner -eq $adOwner -or $csvOwner -like "*$adOwner*") {
          $isSameUser = $true
          break
        }
      }
      
      if (-not $isSameUser) {
        $adConflicts.Add([pscustomobject]@{
          SMTP = $smtp
          CSV側所有者 = ($csvOwners -join "; ")
          AD側所有者 = $adOwner
        })
      }
    }
  }
  
  if ($adConflicts.Count -gt 0) {
    Write-Host "      → 【エラー】$($adConflicts.Count) 件の競合を検出！"
    $adConflicts | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "ad_conflicts.csv")
  } else {
    Write-Host "      → OK: 既存ADとの競合なし"
  }
  
} elseif ($CheckAdDirect) {
  Write-Host ""
  Write-Host "[4/4] ★ ADに直接問い合わせて競合チェック中..."
  Import-Module ActiveDirectory
  
  $checked = 0
  foreach ($smtp in $smtpToRows.Keys) {
    $checked++
    if ($checked % 100 -eq 0) {
      Write-Host "      → $checked / $($smtpToRows.Count) 件チェック済み"
    }
    
    $filter = "proxyAddresses -like '*$smtp*' -or mail -eq '$smtp'"
    $existing = Get-ADUser -Filter $filter -Properties mail,proxyAddresses -ErrorAction SilentlyContinue
    
    if ($existing) {
      $csvOwners = $smtpToRows[$smtp]
      $adOwner = $existing.SamAccountName
      
      $isSameUser = $false
      foreach ($csvOwner in $csvOwners) {
        if ($csvOwner -eq $adOwner -or $csvOwner -like "*$adOwner*") {
          $isSameUser = $true
          break
        }
      }
      
      if (-not $isSameUser) {
        $adConflicts.Add([pscustomobject]@{
          SMTP = $smtp
          CSV側所有者 = ($csvOwners -join "; ")
          AD側所有者 = $adOwner
        })
      }
    }
  }
  
  if ($adConflicts.Count -gt 0) {
    Write-Host "      → 【エラー】$($adConflicts.Count) 件の競合を検出！"
    $adConflicts | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "ad_conflicts.csv")
  } else {
    Write-Host "      → OK: ADとの競合なし"
  }
  
} else {
  Write-Host ""
  Write-Host "[4/4] ADチェックをスキップ（-AdUsersCsv または -CheckAdDirect を指定）"
}

#----------------------------------------------------------------------
# サマリー作成
#----------------------------------------------------------------------
$hasErrors = ($validationErrors.Count -gt 0) -or ($csvDuplicates.Count -gt 0) -or ($adConflicts.Count -gt 0)

$summary = @"
#===============================================================================
# SMTP 重複チェックサマリー
#===============================================================================

【実行日時】$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
【入力CSV】$CsvPath

【統計】
  CSV行数:        $($rows.Count)
  ユニークSMTP数: $($smtpToRows.Count)

【検出結果】
  形式エラー:     $($validationErrors.Count)
  CSV内重複:      $($csvDuplicates.Count)
  AD競合:         $($adConflicts.Count)

【判定】
  $(if ($hasErrors) { "❌ エラーあり → AD投入を中止してください" } else { "✓ 問題なし → AD投入を実行できます" })

#-------------------------------------------------------------------------------
# エラーの意味と対処
#-------------------------------------------------------------------------------

  【形式エラー】
  → メールアドレスの形式が不正、または必須項目が空
  → CSVを修正してください

  【CSV内重複】
  → 同じCSV内で同じSMTPアドレスが複数行に存在
  → どちらか一方を修正または削除してください

  【AD競合】
  → 既存ADユーザーが既に使用しているSMTPアドレス
  → 既存ユーザーから削除するか、CSVを修正してください

"@

$summary | Out-File (Join-Path $OutDir "summary.txt") -Encoding UTF8

if ($validationErrors.Count -gt 0) {
  $validationErrors | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "validation_errors.csv")
}

Write-Host ""
Write-Host "============================================================"
Write-Host " 完了"
Write-Host "============================================================"
Write-Host $summary

if ($hasErrors) {
  Write-Host ""
  Write-Host "【重要】エラーが検出されました。AD投入を実行しないでください！"
  Write-Host "        出力ファイルを確認し、問題を解消してから再実行してください。"
  Write-Host ""
}

Stop-Transcript
Write-Host "出力先: $OutDir"

# スクリプト用の終了コード
if ($hasErrors) { exit 1 } else { exit 0 }
