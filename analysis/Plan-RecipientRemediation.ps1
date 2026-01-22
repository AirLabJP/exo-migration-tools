<#
.SYNOPSIS
  紛れ受信者の対処計画スクリプト

.DESCRIPTION
  Detect-StrayRecipients.ps1 の結果を元に、紛れ受信者の対処計画を作成します。
  実際の削除/無効化は行わず、対処方針を整理してレポートします。

  【対処カテゴリ】
  - DELETE: 削除推奨（完全に不要なオブジェクト）
  - DISABLE: 無効化推奨（念のため残す）
  - REVIEW: 要確認（判断できない、お客様確認が必要）
  - KEEP: 保持（正当な理由あり）

.PARAMETER StrayReportPath
  Detect-StrayRecipients.ps1 が出力した strays_action_required.csv のパス

.PARAMETER AutoClassify
  自動分類を有効化（RecipientTypeDetails に基づく推奨）

.PARAMETER OutDir
  出力先フォルダ

.EXAMPLE
  # 自動分類で対処計画作成
  .\Plan-RecipientRemediation.ps1 -StrayReportPath .\stray_report\20260117\strays_action_required.csv -AutoClassify

  # 手動分類（全てREVIEW）
  .\Plan-RecipientRemediation.ps1 -StrayReportPath .\stray_report\20260117\strays_action_required.csv

.NOTES
  - このスクリプトは計画のみ作成し、実際の操作は行いません
  - 対処実行は Invoke-RecipientRemediation.ps1（別途）または手動で行います
#>
param(
  [Parameter(Mandatory=$true)]
  [string]$StrayReportPath,
  
  [switch]$AutoClassify,
  
  [string]$OutDir = ".\remediation_plan"
)

# エラーアクションの設定
$ErrorActionPreference = "Continue"

# 出力先フォルダ作成
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$OutDir = Join-Path $OutDir $ts
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Start-Transcript -Path (Join-Path $OutDir "run.log") -Force

Write-Host "============================================================"
Write-Host " 紛れ受信者 対処計画"
Write-Host "============================================================"
Write-Host "出力先: $OutDir"
Write-Host ""

#----------------------------------------------------------------------
# レポート読み込み
#----------------------------------------------------------------------
Write-Host "[1/3] 紛れレポートを読み込み..."

if (-not (Test-Path $StrayReportPath)) {
  throw "紛れレポートが見つかりません: $StrayReportPath"
}

$strays = Import-Csv $StrayReportPath -Encoding UTF8
Write-Host "      → 紛れ受信者数: $($strays.Count)"

if ($strays.Count -eq 0) {
  Write-Host ""
  Write-Host "紛れ受信者がありません。対処計画は不要です。" -ForegroundColor Green
  Stop-Transcript
  exit 0
}

#----------------------------------------------------------------------
# 分類
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[2/3] 対処方針を分類..."

# RecipientTypeDetailsごとの推奨対処
$typeRecommendations = @{
  # 削除推奨
  "UserMailbox" = @{ Action = "DELETE"; Reason = "意図しないメールボックス。ADに対応ユーザーがない。" }
  "SharedMailbox" = @{ Action = "REVIEW"; Reason = "共有メールボックス。使用状況を確認。" }
  "RoomMailbox" = @{ Action = "REVIEW"; Reason = "会議室メールボックス。使用状況を確認。" }
  "EquipmentMailbox" = @{ Action = "REVIEW"; Reason = "備品メールボックス。使用状況を確認。" }
  
  # 無効化推奨
  "MailUser" = @{ Action = "DISABLE"; Reason = "外部連絡先。必要性を確認。" }
  "MailContact" = @{ Action = "DISABLE"; Reason = "メール連絡先。必要性を確認。" }
  "GuestMailUser" = @{ Action = "REVIEW"; Reason = "ゲストユーザー。招待元を確認。" }
  
  # 要確認
  "MailUniversalDistributionGroup" = @{ Action = "REVIEW"; Reason = "配布グループ。メンバーと使用状況を確認。" }
  "MailUniversalSecurityGroup" = @{ Action = "REVIEW"; Reason = "メール有効セキュリティグループ。使用状況を確認。" }
  "DynamicDistributionGroup" = @{ Action = "REVIEW"; Reason = "動的配布グループ。ルールを確認。" }
  "GroupMailbox" = @{ Action = "REVIEW"; Reason = "M365グループ。使用状況を確認。" }
  
  # デフォルト
  "Default" = @{ Action = "REVIEW"; Reason = "種別不明。要確認。" }
}

$plans = @()
$actionCounts = @{
  "DELETE" = 0
  "DISABLE" = 0
  "REVIEW" = 0
  "KEEP" = 0
}

foreach ($stray in $strays) {
  $recipientType = $stray.RecipientTypeDetails
  
  if ($AutoClassify) {
    $rec = if ($typeRecommendations.ContainsKey($recipientType)) {
      $typeRecommendations[$recipientType]
    } else {
      $typeRecommendations["Default"]
    }
    $action = $rec.Action
    $reason = $rec.Reason
  } else {
    $action = "REVIEW"
    $reason = "手動確認が必要"
  }
  
  $actionCounts[$action]++
  
  $plans += [PSCustomObject]@{
    PrimarySmtpAddress = $stray.PrimarySmtpAddress
    DisplayName = $stray.DisplayName
    RecipientTypeDetails = $recipientType
    RecommendedAction = $action
    Reason = $reason
    FinalAction = ""  # お客様/担当者が記入
    FinalReason = ""  # お客様/担当者が記入
    ApprovedBy = ""   # 承認者
    ApprovedDate = "" # 承認日
  }
}

Write-Host ""
Write-Host "【分類結果】"
Write-Host "  DELETE（削除推奨）:  $($actionCounts['DELETE'])"
Write-Host "  DISABLE（無効化推奨）: $($actionCounts['DISABLE'])"
Write-Host "  REVIEW（要確認）:    $($actionCounts['REVIEW'])"

#----------------------------------------------------------------------
# 出力
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[3/3] 対処計画を出力..."

# 対処計画CSV（編集用）
$plans | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "remediation_plan.csv")

# アクション別CSV
$plans | Where-Object { $_.RecommendedAction -eq "DELETE" } |
  Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "plan_delete.csv")
$plans | Where-Object { $_.RecommendedAction -eq "DISABLE" } |
  Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "plan_disable.csv")
$plans | Where-Object { $_.RecommendedAction -eq "REVIEW" } |
  Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "plan_review.csv")

#----------------------------------------------------------------------
# サマリー
#----------------------------------------------------------------------
$summary = @"
#===============================================================================
# 紛れ受信者 対処計画サマリー
#===============================================================================

【実行日時】$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
【入力ファイル】$StrayReportPath
【自動分類】$(if ($AutoClassify) { "有効" } else { "無効（全てREVIEW）" })

【分類結果】
  紛れ受信者総数:      $($strays.Count)
  DELETE（削除推奨）:  $($actionCounts['DELETE'])
  DISABLE（無効化推奨）: $($actionCounts['DISABLE'])
  REVIEW（要確認）:    $($actionCounts['REVIEW'])

【出力ファイル】
  remediation_plan.csv  ← 対処計画（編集用：FinalAction列を記入）
  plan_delete.csv       ← DELETE推奨の一覧
  plan_disable.csv      ← DISABLE推奨の一覧
  plan_review.csv       ← REVIEW（要確認）の一覧

#-------------------------------------------------------------------------------
# 対処アクションの意味
#-------------------------------------------------------------------------------

  DELETE:  オブジェクトを完全に削除
           Remove-Mailbox, Remove-MailUser, Remove-MailContact 等

  DISABLE: オブジェクトを無効化（非表示化）
           Set-Mailbox -HiddenFromAddressListsEnabled $true 等
           削除せずに残すが、GALには表示しない

  REVIEW:  お客様/担当者による確認が必要
           使用状況、所有者、作成目的を確認して判断

  KEEP:    正当な理由があり保持
           理由を FinalReason 列に記載

#-------------------------------------------------------------------------------
# 次のステップ
#-------------------------------------------------------------------------------

1. remediation_plan.csv を確認
   - RecommendedAction（推奨）を参考に FinalAction を決定
   - 理由を FinalReason に記載
   - 承認者と日付を記入

2. お客様に確認が必要なもの（REVIEW）を説明
   - 特に共有メールボックス、配布グループは使用状況確認

3. 対処実行
   - FinalAction = DELETE の場合:
     Remove-Mailbox -Identity "xxx@example.co.jp" -Confirm:$false
   - FinalAction = DISABLE の場合:
     Set-Mailbox -Identity "xxx@example.co.jp" -HiddenFromAddressListsEnabled $true

4. Detect-StrayRecipients.ps1 を再実行して STRAY_EXO_ONLY = 0 を確認

#-------------------------------------------------------------------------------
# 注意事項
#-------------------------------------------------------------------------------

- 削除は不可逆操作。必ず事前にバックアップ/確認
- メールボックス削除後、30日間はソフトデリート状態で復元可能
- 完全削除（パージ）は避け、まずソフトデリートで様子を見る
- お客様承認なしに DELETE を実行しない

"@

$summary | Out-File (Join-Path $OutDir "summary.txt") -Encoding UTF8

Write-Host ""
Write-Host "============================================================"
Write-Host " 完了"
Write-Host "============================================================"
Write-Host $summary

Stop-Transcript
Write-Host ""
Write-Host "出力先: $OutDir"
