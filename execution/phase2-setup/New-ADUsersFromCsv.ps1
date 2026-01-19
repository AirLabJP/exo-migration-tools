<#
.SYNOPSIS
  CSVからActive Directoryユーザーを作成

.DESCRIPTION
  CSVファイルで定義されたユーザーをActive Directoryに作成します。
  本番環境・検証環境どちらでも使用できる汎用スクリプトです。

  【機能】
  - CSVからユーザーを一括作成
  - 既存ユーザーはスキップ（上書きしない）
  - mail/proxyAddresses属性も同時に設定可能
  - OUを指定可能

  【検証環境での使い方】
  テスト用CSVを用意して実行すれば、検証環境にテストユーザーを作成できます。
  Entra ID Connectで同期すれば、EXOにメールボックスが作成されます。

.PARAMETER CsvPath
  ユーザー定義CSVファイルのパス

.PARAMETER TargetOU
  ユーザーを作成するOU（例: "OU=Users,OU=Corp,DC=contoso,DC=local"）

.PARAMETER DefaultPassword
  初期パスワード（省略時は自動生成）

.PARAMETER SetMailAttributes
  mail/proxyAddresses属性も設定する

.PARAMETER WhatIfMode
  実際には作成せず、確認のみ

.PARAMETER OutDir
  出力先フォルダ

.EXAMPLE
  # 本番用CSV
  .\New-ADUsersFromCsv.ps1 -CsvPath production_users.csv -TargetOU "OU=Users,DC=contoso,DC=local"

  # 検証用CSV（WhatIfで確認）
  .\New-ADUsersFromCsv.ps1 -CsvPath test_users.csv -TargetOU "OU=TestUsers,DC=lab,DC=local" -WhatIfMode

  # メール属性も設定
  .\New-ADUsersFromCsv.ps1 -CsvPath users.csv -TargetOU "OU=Users,DC=contoso,DC=local" -SetMailAttributes

.NOTES
  - ActiveDirectory モジュールが必要
  - ドメイン管理者権限が必要
  - ADスキーマ拡張済みの場合のみ mail/proxyAddresses 設定可能

【CSV形式】
  UserPrincipalName,SamAccountName,DisplayName,GivenName,Surname,PrimarySmtpAddress,Aliases
  user1@contoso.local,user1,山田 太郎,太郎,山田,user1@contoso.co.jp,alias1@contoso.co.jp;alias2@contoso.co.jp
#>

# ユーザー作成用途のため、パスワードを平文で扱う必要がある（自動生成してファイル出力するため）
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '')]
param(
  [Parameter(Mandatory=$true)]
  [string]$CsvPath,
  
  [Parameter(Mandatory=$true)]
  [string]$TargetOU,
  
  [string]$DefaultPassword,
  
  [switch]$SetMailAttributes,
  [switch]$WhatIfMode,
  
  [string]$OutDir = ".\ad_user_creation"
)

# エラーアクションの設定
$ErrorActionPreference = "Stop"

# 出力先フォルダ作成
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$OutDir = Join-Path $OutDir $ts
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Start-Transcript -Path (Join-Path $OutDir "run.log") -Force

Write-Host "============================================================"
Write-Host " Active Directory ユーザー作成"
Write-Host "============================================================"
Write-Host "CSVファイル: $CsvPath"
Write-Host "作成先OU: $TargetOU"
Write-Host "出力先: $OutDir"
Write-Host ""

if ($WhatIfMode) {
  Write-Host "【WhatIfモード】実際の作成は行いません" -ForegroundColor Yellow
  Write-Host ""
}

#----------------------------------------------------------------------
# AD接続確認
#----------------------------------------------------------------------
Write-Host "[1/5] Active Directory 接続確認..."

try {
  Import-Module ActiveDirectory -ErrorAction Stop
  $domain = Get-ADDomain -ErrorAction Stop
  Write-Host "      → ドメイン: $($domain.DNSRoot)"
  Write-Host "      → フォレスト: $($domain.Forest)"
} catch {
  throw "Active Directoryに接続できません: $_"
}

#----------------------------------------------------------------------
# OU確認
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[2/5] 作成先OUを確認..."

try {
  $ou = Get-ADOrganizationalUnit -Identity $TargetOU -ErrorAction Stop
  Write-Host "      → OU確認OK: $($ou.DistinguishedName)"
} catch {
  throw "OUが見つかりません: $TargetOU"
}

#----------------------------------------------------------------------
# パスワード準備
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[3/5] パスワードを準備..."

if (-not $DefaultPassword) {
  # ランダムパスワード生成（16文字）
  $chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*"
  $DefaultPassword = -join ((1..16) | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
  Write-Host "      → パスワードを自動生成しました"
  Write-Host "      → パスワードは出力ファイルに記録されます"
} else {
  Write-Host "      → パスワードを指定"
}

$securePassword = ConvertTo-SecureString $DefaultPassword -AsPlainText -Force

#----------------------------------------------------------------------
# CSV読み込み
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[4/5] CSVファイルを読み込み..."

if (-not (Test-Path $CsvPath)) {
  throw "CSVファイルが見つかりません: $CsvPath"
}

$csvUsers = Import-Csv $CsvPath -Encoding UTF8
Write-Host "      → CSV行数: $($csvUsers.Count)"

# 必須列の確認
$requiredColumns = @("SamAccountName", "DisplayName")
foreach ($col in $requiredColumns) {
  if (-not ($csvUsers | Get-Member -Name $col -MemberType NoteProperty)) {
    throw "CSVに必須列がありません: $col"
  }
}

# UPN列の確認
$hasUPN = $csvUsers | Get-Member -Name "UserPrincipalName" -MemberType NoteProperty
if (-not $hasUPN) {
  Write-Host "      → UserPrincipalName列がないため、SamAccountName@ドメインで生成します"
}

#----------------------------------------------------------------------
# ユーザー作成
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[5/5] ★ ユーザーを作成..."

$results = @()
$createdCount = 0
$existingCount = 0
$errorCount = 0

foreach ($row in $csvUsers) {
  $sam = $row.SamAccountName
  $displayName = $row.DisplayName
  
  # UPN生成
  $upn = if ($hasUPN -and $row.UserPrincipalName) {
    $row.UserPrincipalName
  } else {
    "$sam@$($domain.DNSRoot)"
  }
  
  Write-Host ""
  Write-Host "  [$sam] $displayName"
  
  # 既存ユーザー確認
  $existingUser = $null
  try {
    $existingUser = Get-ADUser -Identity $sam -ErrorAction SilentlyContinue
  } catch {
    # ユーザーが存在しない場合は例外が発生するが無視
  }
  
  if ($existingUser) {
    Write-Host "    → スキップ: 既に存在します" -ForegroundColor Yellow
    $results += [PSCustomObject]@{
      SamAccountName = $sam
      UserPrincipalName = $upn
      DisplayName = $displayName
      Password = "N/A"
      Status = "EXISTING"
      Message = "既に存在するためスキップ"
    }
    $existingCount++
    continue
  }
  
  if ($WhatIfMode) {
    Write-Host "    → [WhatIf] 作成予定"
    $results += [PSCustomObject]@{
      SamAccountName = $sam
      UserPrincipalName = $upn
      DisplayName = $displayName
      Password = $DefaultPassword
      Status = "WHATIF"
      Message = "WhatIfモード"
    }
    continue
  }
  
  try {
    # ユーザー作成パラメータ
    $newUserParams = @{
      SamAccountName = $sam
      UserPrincipalName = $upn
      Name = $displayName
      DisplayName = $displayName
      Path = $TargetOU
      AccountPassword = $securePassword
      Enabled = $true
      PasswordNeverExpires = $false
      ChangePasswordAtLogon = $false
    }
    
    # オプション属性
    if ($row.GivenName) { $newUserParams.GivenName = $row.GivenName }
    if ($row.Surname) { $newUserParams.Surname = $row.Surname }
    if ($row.Description) { $newUserParams.Description = $row.Description }
    
    # ユーザー作成
    New-ADUser @newUserParams -ErrorAction Stop
    Write-Host "    → ユーザー作成完了" -ForegroundColor Green
    
    # メール属性設定
    if ($SetMailAttributes -and $row.PrimarySmtpAddress) {
      try {
        $mailAttrs = @{
          mail = $row.PrimarySmtpAddress
        }
        
        # proxyAddresses構築
        $proxyAddresses = @("SMTP:$($row.PrimarySmtpAddress)")
        if ($row.Aliases) {
          $aliases = $row.Aliases -split ";"
          foreach ($alias in $aliases) {
            if ($alias.Trim()) {
              $proxyAddresses += "smtp:$($alias.Trim())"
            }
          }
        }
        $mailAttrs.proxyAddresses = $proxyAddresses
        
        Set-ADUser -Identity $sam -Replace $mailAttrs -ErrorAction Stop
        Write-Host "    → メール属性設定完了" -ForegroundColor Green
      } catch {
        Write-Host "    → メール属性設定失敗: $_" -ForegroundColor Yellow
      }
    }
    
    $results += [PSCustomObject]@{
      SamAccountName = $sam
      UserPrincipalName = $upn
      DisplayName = $displayName
      Password = $DefaultPassword
      Status = "CREATED"
      Message = "作成完了"
    }
    $createdCount++
    
  } catch {
    Write-Host "    → エラー: $($_.Exception.Message)" -ForegroundColor Red
    $results += [PSCustomObject]@{
      SamAccountName = $sam
      UserPrincipalName = $upn
      DisplayName = $displayName
      Password = "N/A"
      Status = "ERROR"
      Message = $_.Exception.Message
    }
    $errorCount++
  }
}

# 結果をCSV出力（パスワード含む - 取り扱い注意）
$results | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "results.csv")

#----------------------------------------------------------------------
# サマリー
#----------------------------------------------------------------------
$summary = @"
#===============================================================================
# Active Directory ユーザー作成 サマリー
#===============================================================================

【実行日時】$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
【モード】$(if ($WhatIfMode) { "WhatIf（ドライラン）" } else { "本番実行" })

【入力】
  CSVファイル: $CsvPath
  CSV行数:     $($csvUsers.Count)

【作成先】
  ドメイン: $($domain.DNSRoot)
  OU:       $TargetOU

【処理結果】
  作成:     $createdCount
  既存:     $existingCount（スキップ）
  エラー:   $errorCount

【出力ファイル】
  results.csv  ← 作成結果（パスワード含む！取り扱い注意）

#-------------------------------------------------------------------------------
# 次のステップ
#-------------------------------------------------------------------------------

"@

if ($WhatIfMode) {
  $summary += @"
  WhatIfモードでした。実際に作成するには -WhatIfMode なしで再実行してください。

"@
} else {
  $summary += @"
  1. results.csv でパスワードを確認（安全に管理）
  
  2. Entra ID Connect 同期を実行（検証環境の場合）:
     Start-ADSyncSyncCycle -PolicyType Delta
  
  3. 同期完了後、EXOにメールボックスが作成されることを確認:
     Get-Mailbox -ResultSize 10 | Sort-Object WhenCreated -Descending
  
  4. または、ライセンスグループにユーザーを追加してメールボックス作成:
     .\Add-UsersToLicenseGroup.ps1 -CsvPath results.csv -GroupName "EXO-License-Pilot"

"@
}

$summary | Out-File (Join-Path $OutDir "summary.txt") -Encoding UTF8

Write-Host ""
Write-Host "============================================================"
Write-Host " 完了"
Write-Host "============================================================"
Write-Host $summary

if ($errorCount -gt 0) {
  Write-Host "【警告】$errorCount 件のエラーが発生しました" -ForegroundColor Red
}

Stop-Transcript
Write-Host ""
Write-Host "出力先: $OutDir"

# 終了コード
if ($errorCount -gt 0) { exit 1 } else { exit 0 }
