<#
.SYNOPSIS
  ライセンス付与用グループへのユーザー追加スクリプト

.DESCRIPTION
  CSVファイルで指定したユーザーを、ライセンス付与用の静的セキュリティグループに追加します。
  
  【移行中の運用方針】
  - 動的グループではなく静的グループを使用
  - CSVで明示的に指定したユーザーのみがライセンス付与対象
  - 意図しないメールボックス作成を防止
  
  【最終形への移行】
  - 全ドメイン移行完了後、動的グループに切り替え
  - ドメインベースの規則で自動化

.PARAMETER CsvPath
  ユーザー一覧CSVファイル（UserPrincipalName または ObjectId 列が必須）

.PARAMETER GroupName
  追加先のセキュリティグループ名

.PARAMETER GroupId
  追加先のセキュリティグループID（ObjectId）

.PARAMETER WhatIfMode
  実際には追加せず、確認のみ

.PARAMETER RemoveMode
  グループからユーザーを削除するモード

.PARAMETER OutDir
  出力先フォルダ

.EXAMPLE
  # ユーザーをグループに追加（WhatIfで確認）
  .\Add-UsersToLicenseGroup.ps1 -CsvPath users.csv -GroupName "EXO-License-Pilot" -WhatIfMode

  # 本番実行
  .\Add-UsersToLicenseGroup.ps1 -CsvPath users.csv -GroupName "EXO-License-Pilot"

  # グループIDを指定
  .\Add-UsersToLicenseGroup.ps1 -CsvPath users.csv -GroupId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

  # ユーザーをグループから削除
  .\Add-UsersToLicenseGroup.ps1 -CsvPath users.csv -GroupName "EXO-License-Pilot" -RemoveMode

.NOTES
  - Microsoft.Graph モジュールが必要
  - Connect-MgGraph で接続済みであること
  - Group.ReadWrite.All スコープが必要
  - グループベースライセンスはEntra ID Premium P1以上が必要
#>
param(
  [Parameter(Mandatory=$true)]
  [string]$CsvPath,
  
  [string]$GroupName,
  [string]$GroupId,
  
  [switch]$WhatIfMode,
  [switch]$RemoveMode,
  
  [string]$OutDir = ".\license_group_management"
)

# エラーアクションの設定
$ErrorActionPreference = "Stop"

# 出力先フォルダ作成
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$OutDir = Join-Path $OutDir $ts
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Start-Transcript -Path (Join-Path $OutDir "run.log") -Force

$action = if ($RemoveMode) { "削除" } else { "追加" }

Write-Host "============================================================"
Write-Host " ライセンス付与グループへのユーザー$action"
Write-Host "============================================================"
Write-Host "出力先: $OutDir"
Write-Host ""

if ($WhatIfMode) {
  Write-Host "【WhatIfモード】実際の$actionは行いません" -ForegroundColor Yellow
  Write-Host ""
}

#----------------------------------------------------------------------
# Graph接続確認
#----------------------------------------------------------------------
Write-Host "[1/5] Microsoft Graph 接続確認..."

try {
  Import-Module Microsoft.Graph.Groups -ErrorAction Stop
  $context = Get-MgContext -ErrorAction Stop
  if (-not $context) {
    throw "Graphに接続されていません"
  }
  Write-Host "      → 接続済み: $($context.Account)"
  Write-Host "      → TenantId: $($context.TenantId)"
  
  # スコープ確認
  if ($context.Scopes -notcontains "Group.ReadWrite.All" -and $context.Scopes -notcontains "Directory.ReadWrite.All") {
    Write-Host "      → 警告: Group.ReadWrite.All スコープがない可能性があります" -ForegroundColor Yellow
  }
} catch {
  throw "Microsoft Graphに接続されていません。Connect-MgGraph -Scopes 'Group.ReadWrite.All' を実行してください。"
}

#----------------------------------------------------------------------
# グループの特定
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[2/5] 対象グループを特定..."

$targetGroup = $null

if ($GroupId) {
  try {
    $targetGroup = Get-MgGroup -GroupId $GroupId -ErrorAction Stop
    Write-Host "      → グループID: $GroupId"
    Write-Host "      → グループ名: $($targetGroup.DisplayName)"
  } catch {
    throw "グループが見つかりません: $GroupId"
  }
} elseif ($GroupName) {
  try {
    $groups = Get-MgGroup -Filter "displayName eq '$GroupName'" -ErrorAction Stop
    if ($groups.Count -eq 0) {
      throw "グループが見つかりません: $GroupName"
    }
    if ($groups.Count -gt 1) {
      throw "同名のグループが複数存在します: $GroupName（GroupIdを指定してください）"
    }
    $targetGroup = $groups[0]
    Write-Host "      → グループ名: $GroupName"
    Write-Host "      → グループID: $($targetGroup.Id)"
  } catch {
    throw "グループの検索に失敗: $_"
  }
} else {
  throw "-GroupName または -GroupId を指定してください"
}

# グループタイプ確認
$groupTypes = $targetGroup.GroupTypes
if ($groupTypes -contains "DynamicMembership") {
  Write-Host "      → 警告: このグループは動的グループです。メンバーの手動追加はできません。" -ForegroundColor Red
  throw "動的グループにはメンバーを手動追加できません。静的セキュリティグループを使用してください。"
}

Write-Host "      → グループタイプ: 静的セキュリティグループ"

#----------------------------------------------------------------------
# 現在のグループメンバー取得
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[3/5] 現在のグループメンバーを取得..."

$currentMembers = @{}
try {
  $members = Get-MgGroupMember -GroupId $targetGroup.Id -All
  foreach ($m in $members) {
    $currentMembers[$m.Id] = $true
  }
  Write-Host "      → 現在のメンバー数: $($currentMembers.Count)"
} catch {
  Write-Host "      → 警告: メンバー取得に失敗: $_" -ForegroundColor Yellow
}

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
$hasUPN = $csvUsers | Get-Member -Name "UserPrincipalName" -MemberType NoteProperty
$hasObjectId = $csvUsers | Get-Member -Name "ObjectId" -MemberType NoteProperty

if (-not $hasUPN -and -not $hasObjectId) {
  throw "CSVに UserPrincipalName または ObjectId 列が必要です"
}

Write-Host "      → 識別子: $(if ($hasUPN) { 'UserPrincipalName' } else { 'ObjectId' })"

#----------------------------------------------------------------------
# ユーザー処理
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[5/5] ★ ユーザーを$action..."

$results = @()
$successCount = 0
$skipCount = 0
$errorCount = 0

foreach ($row in $csvUsers) {
  $userId = $null
  $userIdentifier = $null
  
  # ユーザーIDの取得
  if ($hasObjectId -and $row.ObjectId) {
    $userId = $row.ObjectId
    $userIdentifier = $row.ObjectId
  } elseif ($hasUPN -and $row.UserPrincipalName) {
    $userIdentifier = $row.UserPrincipalName
    try {
      $user = Get-MgUser -UserId $row.UserPrincipalName -ErrorAction Stop
      $userId = $user.Id
    } catch {
      Write-Host "  [エラー] ${userIdentifier}: ユーザーが見つかりません" -ForegroundColor Red
      $results += [PSCustomObject]@{
        UserIdentifier = $userIdentifier
        UserId = "N/A"
        Action = $action
        Status = "ERROR"
        Message = "ユーザーが見つかりません"
      }
      $errorCount++
      continue
    }
  } else {
    continue
  }
  
  # 現在のメンバーシップ確認
  $isMember = $currentMembers.ContainsKey($userId)
  
  if ($RemoveMode) {
    # 削除モード
    if (-not $isMember) {
      Write-Host "  [スキップ] ${userIdentifier}: グループのメンバーではありません"
      $results += [PSCustomObject]@{
        UserIdentifier = $userIdentifier
        UserId = $userId
        Action = "削除"
        Status = "SKIP"
        Message = "グループのメンバーではありません"
      }
      $skipCount++
      continue
    }
    
    if ($WhatIfMode) {
      Write-Host "  [WhatIf] ${userIdentifier}: 削除予定"
      $results += [PSCustomObject]@{
        UserIdentifier = $userIdentifier
        UserId = $userId
        Action = "削除"
        Status = "WHATIF"
        Message = "WhatIfモード"
      }
      $skipCount++
    } else {
      try {
        Remove-MgGroupMemberByRef -GroupId $targetGroup.Id -DirectoryObjectId $userId -ErrorAction Stop
        Write-Host "  [成功] ${userIdentifier}: グループから削除" -ForegroundColor Green
        $results += [PSCustomObject]@{
          UserIdentifier = $userIdentifier
          UserId = $userId
          Action = "削除"
          Status = "SUCCESS"
          Message = "削除完了"
        }
        $successCount++
      } catch {
        Write-Host "  [エラー] ${userIdentifier}: $($_.Exception.Message)" -ForegroundColor Red
        $results += [PSCustomObject]@{
          UserIdentifier = $userIdentifier
          UserId = $userId
          Action = "削除"
          Status = "ERROR"
          Message = $_.Exception.Message
        }
        $errorCount++
      }
    }
  } else {
    # 追加モード
    if ($isMember) {
      Write-Host "  [スキップ] ${userIdentifier}: 既にメンバーです"
      $results += [PSCustomObject]@{
        UserIdentifier = $userIdentifier
        UserId = $userId
        Action = "追加"
        Status = "SKIP"
        Message = "既にメンバーです"
      }
      $skipCount++
      continue
    }
    
    if ($WhatIfMode) {
      Write-Host "  [WhatIf] ${userIdentifier}: 追加予定"
      $results += [PSCustomObject]@{
        UserIdentifier = $userIdentifier
        UserId = $userId
        Action = "追加"
        Status = "WHATIF"
        Message = "WhatIfモード"
      }
      $skipCount++
    } else {
      try {
        $params = @{
          "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$userId"
        }
        New-MgGroupMemberByRef -GroupId $targetGroup.Id -BodyParameter $params -ErrorAction Stop
        Write-Host "  [成功] ${userIdentifier}: グループに追加" -ForegroundColor Green
        $results += [PSCustomObject]@{
          UserIdentifier = $userIdentifier
          UserId = $userId
          Action = "追加"
          Status = "SUCCESS"
          Message = "追加完了"
        }
        $successCount++
      } catch {
        Write-Host "  [エラー] ${userIdentifier}: $($_.Exception.Message)" -ForegroundColor Red
        $results += [PSCustomObject]@{
          UserIdentifier = $userIdentifier
          UserId = $userId
          Action = "追加"
          Status = "ERROR"
          Message = $_.Exception.Message
        }
        $errorCount++
      }
    }
  }
}

# 結果をCSV出力
$results | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "results.csv")

#----------------------------------------------------------------------
# 処理後のメンバー数確認
#----------------------------------------------------------------------
if (-not $WhatIfMode -and $successCount -gt 0) {
  Write-Host ""
  Write-Host "【処理後のグループメンバー】"
  $membersAfter = Get-MgGroupMember -GroupId $targetGroup.Id -All
  Write-Host "  メンバー数: $($membersAfter.Count)"
}

#----------------------------------------------------------------------
# サマリー
#----------------------------------------------------------------------
$summary = @"
#===============================================================================
# ライセンス付与グループ $action サマリー
#===============================================================================

【実行日時】$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
【モード】$(if ($WhatIfMode) { "WhatIf（ドライラン）" } else { "本番実行" })
【操作】$action

【対象グループ】
  名前: $($targetGroup.DisplayName)
  ID:   $($targetGroup.Id)

【処理結果】
  CSV行数:   $($csvUsers.Count)
  成功:      $successCount
  スキップ:  $skipCount
  エラー:    $errorCount

#-------------------------------------------------------------------------------
# グループベースライセンスについて
#-------------------------------------------------------------------------------

このグループにEntra ID管理センターでライセンスを割り当てると、
グループメンバー全員に自動的にライセンスが付与されます。

【設定手順】
1. Entra ID管理センター（https://entra.microsoft.com）にアクセス
2. [グループ] → [$($targetGroup.DisplayName)] を選択
3. [ライセンス] → [割り当て]
4. Exchange Online を含むライセンス（例：Microsoft 365 E3）を選択
5. 必要なサービスを選択して [保存]

【注意事項】
- グループベースライセンスには Entra ID Premium P1 以上が必要
- ライセンス付与後、数分〜数十分でEXOメールボックスが作成される
- メールボックス作成前に AD の mail/proxyAddresses 属性が設定されていること

#-------------------------------------------------------------------------------
# 次のステップ
#-------------------------------------------------------------------------------

"@

if ($WhatIfMode) {
  $summary += @"
  WhatIfモードでした。実際に$actionするには -WhatIfMode なしで再実行してください。

"@
} elseif ($RemoveMode) {
  $summary += @"
  1. グループからのユーザー削除が完了
  2. ライセンスが自動的に解除される（数分〜数時間）
  3. EXOメールボックスはライセンス解除後30日で削除対象

"@
} else {
  $summary += @"
  1. グループへのユーザー追加が完了
  2. グループにライセンスが割り当てられていれば、自動的にライセンス付与
  3. EXOメールボックスが作成されるのを待機（数分〜数十分）
  4. Collect-EXOInventory.ps1 でメールボックス作成を確認

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
