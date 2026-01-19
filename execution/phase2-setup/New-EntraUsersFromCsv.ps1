<#
.SYNOPSIS
  CSVからEntra IDユーザーを作成（クラウドオンリー）

.DESCRIPTION
  CSVファイルで定義されたユーザーをEntra ID（Azure AD）に直接作成します。
  既存ユーザーはスキップし、指定されたライセンスグループに追加します。

  【用途】
  - ADを使わない環境でのユーザー作成
  - テストドメインでの検証用ユーザー作成
  - クラウドオンリーユーザーの一括作成

  【動作】
  1. CSVからユーザー情報を読み込み
  2. 既存ユーザーをチェック
  3. 新規ユーザーは作成、既存ユーザーはスキップ
  4. 全ユーザー（新規＋既存）をライセンスグループに追加

.PARAMETER CsvPath
  ユーザー定義CSVファイルのパス

.PARAMETER LicenseGroupName
  ライセンス付与用グループ名（グループベースライセンス用）

.PARAMETER LicenseGroupId
  ライセンス付与用グループID（名前より優先）

.PARAMETER SkipGroupAdd
  グループへの追加をスキップ

.PARAMETER DefaultPassword
  初期パスワード（省略時は自動生成）

.PARAMETER WhatIfMode
  実際には作成せず、確認のみ

.PARAMETER OutDir
  出力先フォルダ

.EXAMPLE
  # ユーザー作成＋グループ追加（WhatIfで確認）
  .\New-EntraUsersFromCsv.ps1 -CsvPath test_users.csv -LicenseGroupName "EXO-License-Pilot" -WhatIfMode

  # 本番実行
  .\New-EntraUsersFromCsv.ps1 -CsvPath test_users.csv -LicenseGroupName "EXO-License-Pilot"

  # グループ追加なしでユーザー作成のみ
  .\New-EntraUsersFromCsv.ps1 -CsvPath test_users.csv -SkipGroupAdd

.NOTES
  - Microsoft.Graph モジュールが必要
  - Connect-MgGraph で接続済みであること
  - User.ReadWrite.All, Group.ReadWrite.All スコープが必要
  - グループベースライセンスは Entra ID Premium P1 以上が必要

【CSV形式】
  UserPrincipalName,DisplayName,GivenName,Surname,MailNickname
  user1@test.contoso.co.jp,山田 太郎,太郎,山田,user1
#>

# テスト用途のため、パスワードを平文で扱う必要がある
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '')]
param(
  [Parameter(Mandatory=$true)]
  [string]$CsvPath,
  
  [string]$LicenseGroupName,
  [string]$LicenseGroupId,
  
  [switch]$SkipGroupAdd,
  
  [string]$DefaultPassword,
  
  [switch]$WhatIfMode,
  
  [string]$OutDir = ".\entra_user_creation"
)

# エラーアクションの設定
$ErrorActionPreference = "Stop"

# 出力先フォルダ作成
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$OutDir = Join-Path $OutDir $ts
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Start-Transcript -Path (Join-Path $OutDir "run.log") -Force

Write-Host "============================================================"
Write-Host " Entra ID ユーザー作成"
Write-Host "============================================================"
Write-Host "CSVファイル: $CsvPath"
Write-Host "出力先: $OutDir"
Write-Host ""

if ($WhatIfMode) {
  Write-Host "【WhatIfモード】実際の作成は行いません" -ForegroundColor Yellow
  Write-Host ""
}

#----------------------------------------------------------------------
# Graph接続確認
#----------------------------------------------------------------------
Write-Host "[1/6] Microsoft Graph 接続確認..."

try {
  Import-Module Microsoft.Graph.Users -ErrorAction Stop
  Import-Module Microsoft.Graph.Groups -ErrorAction Stop
  $context = Get-MgContext -ErrorAction Stop
  if (-not $context) {
    throw "Graphに接続されていません"
  }
  Write-Host "      → 接続済み: $($context.Account)"
  Write-Host "      → TenantId: $($context.TenantId)"
} catch {
  throw "Microsoft Graphに接続されていません。Connect-MgGraph -Scopes 'User.ReadWrite.All','Group.ReadWrite.All' を実行してください。"
}

#----------------------------------------------------------------------
# ライセンスグループ確認
#----------------------------------------------------------------------
$targetGroup = $null

if (-not $SkipGroupAdd) {
  Write-Host ""
  Write-Host "[2/6] ライセンスグループを確認..."
  
  if ($LicenseGroupId) {
    try {
      $targetGroup = Get-MgGroup -GroupId $LicenseGroupId -ErrorAction Stop
      Write-Host "      → グループID: $LicenseGroupId"
      Write-Host "      → グループ名: $($targetGroup.DisplayName)"
    } catch {
      throw "グループが見つかりません: $LicenseGroupId"
    }
  } elseif ($LicenseGroupName) {
    try {
      $groups = Get-MgGroup -Filter "displayName eq '$LicenseGroupName'" -ErrorAction Stop
      if ($groups.Count -eq 0) {
        throw "グループが見つかりません: $LicenseGroupName"
      }
      if ($groups.Count -gt 1) {
        throw "同名のグループが複数存在します: $LicenseGroupName（GroupIdを指定してください）"
      }
      $targetGroup = $groups[0]
      Write-Host "      → グループ名: $LicenseGroupName"
      Write-Host "      → グループID: $($targetGroup.Id)"
    } catch {
      throw "グループの検索に失敗: $_"
    }
  } else {
    Write-Host "      → グループ未指定: ユーザー作成のみ行います" -ForegroundColor Yellow
    $SkipGroupAdd = $true
  }
  
  # 動的グループチェック
  if ($targetGroup -and $targetGroup.GroupTypes -contains "DynamicMembership") {
    Write-Host "      → 警告: このグループは動的グループです。手動追加できません。" -ForegroundColor Red
    throw "動的グループにはメンバーを手動追加できません。静的セキュリティグループを指定してください。"
  }
} else {
  Write-Host ""
  Write-Host "[2/6] グループ追加: スキップ"
}

#----------------------------------------------------------------------
# 現在のグループメンバー取得
#----------------------------------------------------------------------
$currentMembers = @{}

if ($targetGroup) {
  Write-Host ""
  Write-Host "[3/6] 現在のグループメンバーを取得..."
  
  try {
    $members = Get-MgGroupMember -GroupId $targetGroup.Id -All
    foreach ($m in $members) {
      $currentMembers[$m.Id] = $true
    }
    Write-Host "      → 現在のメンバー数: $($currentMembers.Count)"
  } catch {
    Write-Host "      → メンバー取得に失敗: $_" -ForegroundColor Yellow
  }
} else {
  Write-Host ""
  Write-Host "[3/6] グループメンバー取得: スキップ"
}

#----------------------------------------------------------------------
# パスワード準備
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[4/6] パスワードを準備..."

if (-not $DefaultPassword) {
  $chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*"
  $DefaultPassword = -join ((1..16) | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
  Write-Host "      → パスワードを自動生成しました"
} else {
  Write-Host "      → パスワードを指定"
}

#----------------------------------------------------------------------
# CSV読み込み
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[5/6] CSVファイルを読み込み..."

if (-not (Test-Path $CsvPath)) {
  throw "CSVファイルが見つかりません: $CsvPath"
}

$csvUsers = Import-Csv $CsvPath -Encoding UTF8
Write-Host "      → CSV行数: $($csvUsers.Count)"

# 必須列の確認
if (-not ($csvUsers | Get-Member -Name "UserPrincipalName" -MemberType NoteProperty)) {
  throw "CSVに必須列がありません: UserPrincipalName"
}

#----------------------------------------------------------------------
# ユーザー作成＆グループ追加
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[6/6] ★ ユーザーを作成..."

$results = @()
$createdCount = 0
$existingCount = 0
$groupAddedCount = 0
$errorCount = 0

foreach ($row in $csvUsers) {
  $upn = $row.UserPrincipalName
  $displayName = if ($row.DisplayName) { $row.DisplayName } else { $upn.Split("@")[0] }
  $mailNickname = if ($row.MailNickname) { $row.MailNickname } else { $upn.Split("@")[0] }
  
  Write-Host ""
  Write-Host "  [$upn]"
  
  # 既存ユーザー確認
  $existingUser = $null
  try {
    $existingUser = Get-MgUser -UserId $upn -ErrorAction SilentlyContinue
  } catch {
    # ユーザーが存在しない場合
  }
  
  $userId = $null
  $userStatus = ""
  
  if ($existingUser) {
    Write-Host "    → 既存ユーザー: スキップ（作成しない）" -ForegroundColor Yellow
    $userId = $existingUser.Id
    $userStatus = "EXISTING"
    $existingCount++
  } elseif ($WhatIfMode) {
    Write-Host "    → [WhatIf] 作成予定"
    $userStatus = "WHATIF"
  } else {
    # ユーザー作成
    try {
      $passwordProfile = @{
        Password = $DefaultPassword
        ForceChangePasswordNextSignIn = $false
      }
      
      $newUserParams = @{
        UserPrincipalName = $upn
        DisplayName = $displayName
        MailNickname = $mailNickname
        AccountEnabled = $true
        PasswordProfile = $passwordProfile
        UsageLocation = "JP"
      }
      
      if ($row.GivenName) { $newUserParams.GivenName = $row.GivenName }
      if ($row.Surname) { $newUserParams.Surname = $row.Surname }
      
      $newUser = New-MgUser @newUserParams -ErrorAction Stop
      $userId = $newUser.Id
      Write-Host "    → ユーザー作成完了: $userId" -ForegroundColor Green
      $userStatus = "CREATED"
      $createdCount++
    } catch {
      Write-Host "    → エラー: $($_.Exception.Message)" -ForegroundColor Red
      $results += [PSCustomObject]@{
        UserPrincipalName = $upn
        DisplayName = $displayName
        ObjectId = "N/A"
        Password = "N/A"
        UserStatus = "ERROR"
        GroupStatus = "N/A"
        Message = $_.Exception.Message
      }
      $errorCount++
      continue
    }
  }
  
  # グループ追加
  $groupStatus = "N/A"
  
  if ($targetGroup -and $userId) {
    if ($currentMembers.ContainsKey($userId)) {
      Write-Host "    → グループ: 既にメンバー" -ForegroundColor Yellow
      $groupStatus = "ALREADY_MEMBER"
    } elseif ($WhatIfMode) {
      Write-Host "    → [WhatIf] グループ追加予定"
      $groupStatus = "WHATIF"
    } else {
      try {
        $params = @{
          "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$userId"
        }
        New-MgGroupMemberByRef -GroupId $targetGroup.Id -BodyParameter $params -ErrorAction Stop
        Write-Host "    → グループ追加完了" -ForegroundColor Green
        $groupStatus = "ADDED"
        $groupAddedCount++
      } catch {
        Write-Host "    → グループ追加失敗: $($_.Exception.Message)" -ForegroundColor Yellow
        $groupStatus = "ERROR: $($_.Exception.Message)"
      }
    }
  } elseif ($targetGroup -and -not $userId) {
    $groupStatus = "SKIPPED (WhatIf)"
  }
  
  $results += [PSCustomObject]@{
    UserPrincipalName = $upn
    DisplayName = $displayName
    ObjectId = if ($userId) { $userId } else { "N/A" }
    Password = if ($userStatus -eq "CREATED") { $DefaultPassword } else { "N/A" }
    UserStatus = $userStatus
    GroupStatus = $groupStatus
    Message = ""
  }
}

# 結果をCSV出力
$results | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "results.csv")

#----------------------------------------------------------------------
# サマリー
#----------------------------------------------------------------------
$summary = @"
#===============================================================================
# Entra ID ユーザー作成 サマリー
#===============================================================================

【実行日時】$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
【モード】$(if ($WhatIfMode) { "WhatIf（ドライラン）" } else { "本番実行" })

【入力】
  CSVファイル: $CsvPath
  CSV行数:     $($csvUsers.Count)

【ライセンスグループ】
$(if ($targetGroup) {
"  グループ名: $($targetGroup.DisplayName)
  グループID: $($targetGroup.Id)"
} else {
"  グループ未指定"
})

【処理結果】
  ユーザー作成:   $createdCount
  既存スキップ:   $existingCount
  グループ追加:   $groupAddedCount
  エラー:         $errorCount

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
  
  2. グループにライセンスが割り当てられていれば、自動でメールボックスが作成されます
     （ライセンス付与後、数分〜数十分でEXOメールボックスが作成）
  
  3. メールボックス作成を確認:
     Get-Mailbox -ResultSize 10 | Sort-Object WhenCreated -Descending

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
