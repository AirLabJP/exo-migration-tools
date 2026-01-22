<#
.SYNOPSIS
    紛れ受信者の対処実行スクリプト

.DESCRIPTION
    Plan-RecipientRemediation.ps1 で作成した対処計画に基づき、
    紛れ受信者の削除/無効化を実行します。
    
    【対処アクション】
    - DELETE: オブジェクトを削除（ソフトデリート）
    - DISABLE: GALから非表示化（HiddenFromAddressLists）
    - KEEP: 何もしない（記録のみ）
    - REVIEW: 未決定（スキップ）

.PARAMETER PlanFile
    Plan-RecipientRemediation.ps1 が出力した remediation_plan.csv のパス
    ※ FinalAction 列が記入されていること

.PARAMETER ActionColumn
    実行するアクションを参照する列名（デフォルト: FinalAction）
    RecommendedAction を使用する場合は指定

.PARAMETER WhatIfMode
    実際には実行せず確認のみ

.PARAMETER Force
    確認プロンプトなしで実行

.EXAMPLE
    # WhatIfで確認
    .\Invoke-RecipientRemediation.ps1 -PlanFile .\remediation_plan\*\remediation_plan.csv -WhatIfMode

    # 本番実行（確認プロンプトあり）
    .\Invoke-RecipientRemediation.ps1 -PlanFile .\remediation_plan\*\remediation_plan.csv

    # 推奨アクションをそのまま実行（テスト用）
    .\Invoke-RecipientRemediation.ps1 -PlanFile .\remediation_plan.csv -ActionColumn RecommendedAction -WhatIfMode

.NOTES
    作成者: AI Assistant
    更新日: 2026-01-20
    
    【前提条件】
    - ExchangeOnlineManagement モジュールがインストール済み
    - Connect-ExchangeOnline で接続済み
    - Exchange管理者権限
    
    【注意事項】
    - DELETE は不可逆操作です（30日間はソフトデリート状態で復元可能）
    - お客様承認済みの計画のみ実行してください
    - FinalAction = REVIEW のものは実行されません
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$PlanFile,

    [Parameter(Mandatory = $false)]
    [string]$ActionColumn = "FinalAction",

    [Parameter(Mandatory = $false)]
    [switch]$WhatIfMode = $false,

    [Parameter(Mandatory = $false)]
    [switch]$Force = $false,

    [Parameter(Mandatory = $false)]
    [string]$OutDir = ".\remediation_execution"
)

# エラーアクションの設定
$ErrorActionPreference = "Continue"

# 出力先フォルダ作成
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$OutDir = Join-Path $OutDir $ts
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Start-Transcript -Path (Join-Path $OutDir "run.log") -Force

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " 紛れ受信者 対処実行スクリプト" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "出力先: $OutDir"

if ($WhatIfMode) {
    Write-Host ""
    Write-Host "【WhatIfモード】実際の操作は行いません" -ForegroundColor Yellow
}

#----------------------------------------------------------------------
# プランファイル読み込み
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[1/4] 対処計画ファイルを読み込み..."

# ワイルドカード対応
$planFiles = Get-ChildItem -Path $PlanFile -ErrorAction SilentlyContinue
if ($planFiles.Count -eq 0) {
    throw "対処計画ファイルが見つかりません: $PlanFile"
}

$planFilePath = $planFiles[0].FullName
Write-Host "      → ファイル: $planFilePath"

$plan = Import-Csv $planFilePath -Encoding UTF8

if (-not ($plan | Get-Member -Name $ActionColumn)) {
    throw "指定されたアクション列が見つかりません: $ActionColumn"
}

Write-Host "      → 対象件数: $($plan.Count)"

# アクション別集計
$actionSummary = $plan | Group-Object $ActionColumn | Select-Object Name, Count
Write-Host ""
Write-Host "【アクション別件数】"
foreach ($g in $actionSummary) {
    Write-Host "  $($g.Name): $($g.Count)"
}

# 実行対象の抽出
$toDelete = $plan | Where-Object { $_.$ActionColumn -eq "DELETE" }
$toDisable = $plan | Where-Object { $_.$ActionColumn -eq "DISABLE" }
$toKeep = $plan | Where-Object { $_.$ActionColumn -eq "KEEP" }
$toReview = $plan | Where-Object { $_.$ActionColumn -eq "REVIEW" -or [string]::IsNullOrWhiteSpace($_.$ActionColumn) }

Write-Host ""
Write-Host "【実行対象】"
Write-Host "  DELETE（削除）:     $($toDelete.Count)"
Write-Host "  DISABLE（非表示）:  $($toDisable.Count)"
Write-Host "  KEEP（保持）:       $($toKeep.Count)"
Write-Host "  REVIEW（スキップ）: $($toReview.Count)"

if ($toReview.Count -gt 0) {
    Write-Host ""
    Write-Host "【警告】REVIEW（未決定）が $($toReview.Count) 件あります。スキップされます。" -ForegroundColor Yellow
}

#----------------------------------------------------------------------
# 確認プロンプト
#----------------------------------------------------------------------
if (-not $WhatIfMode -and -not $Force) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host " ⚠️ 警告: 以下の操作を実行します" -ForegroundColor Red
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "  DELETE（削除）:     $($toDelete.Count) 件" -ForegroundColor Red
    Write-Host "  DISABLE（非表示）:  $($toDisable.Count) 件" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "DELETE は不可逆操作です（30日間はソフトデリートで復元可能）" -ForegroundColor Red
    Write-Host ""

    $confirmation = Read-Host "続行しますか？ (yes/no)"
    if ($confirmation -ne "yes") {
        Write-Host "キャンセルされました。"
        Stop-Transcript
        exit 0
    }
}

#----------------------------------------------------------------------
# EXO接続確認
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[2/4] Exchange Online 接続確認..."

try {
    $org = Get-OrganizationConfig -ErrorAction Stop
    Write-Host "      → 接続済み: $($org.Name)"
}
catch {
    throw "Exchange Onlineに接続されていません。Connect-ExchangeOnlineを実行してください。"
}

#----------------------------------------------------------------------
# 対処実行
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[3/4] 対処を実行..."

$results = @()

# DELETE処理
if ($toDelete.Count -gt 0) {
    Write-Host ""
    Write-Host "--- DELETE（削除）処理 ---" -ForegroundColor Red
    
    foreach ($item in $toDelete) {
        $email = $item.PrimarySmtpAddress
        $type = $item.RecipientTypeDetails
        
        Write-Host "  処理中: $email ($type)" -NoNewline

        if ($WhatIfMode) {
            Write-Host " → [WhatIf] スキップ" -ForegroundColor Yellow
            $results += [PSCustomObject]@{
                PrimarySmtpAddress = $email
                RecipientTypeDetails = $type
                Action = "DELETE"
                Status = "WHATIF"
                Message = "WhatIfモード - 実際の削除なし"
                Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            }
            continue
        }

        try {
            # RecipientTypeDetailsに応じた削除コマンド
            switch -Wildcard ($type) {
                "*Mailbox*" {
                    Remove-Mailbox -Identity $email -Confirm:$false -ErrorAction Stop
                }
                "MailUser" {
                    Remove-MailUser -Identity $email -Confirm:$false -ErrorAction Stop
                }
                "MailContact" {
                    Remove-MailContact -Identity $email -Confirm:$false -ErrorAction Stop
                }
                "*DistributionGroup*" {
                    Remove-DistributionGroup -Identity $email -Confirm:$false -ErrorAction Stop
                }
                "*SecurityGroup*" {
                    Remove-DistributionGroup -Identity $email -Confirm:$false -ErrorAction Stop
                }
                "GroupMailbox" {
                    Remove-UnifiedGroup -Identity $email -Confirm:$false -ErrorAction Stop
                }
                default {
                    # 汎用的な試行
                    $recipient = Get-Recipient -Identity $email -ErrorAction SilentlyContinue
                    if ($recipient) {
                        Remove-Mailbox -Identity $email -Confirm:$false -ErrorAction Stop
                    }
                }
            }

            Write-Host " → " -NoNewline
            Write-Host "削除完了" -ForegroundColor Green
            $results += [PSCustomObject]@{
                PrimarySmtpAddress = $email
                RecipientTypeDetails = $type
                Action = "DELETE"
                Status = "SUCCESS"
                Message = "削除完了（ソフトデリート）"
                Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            }
        }
        catch {
            Write-Host " → " -NoNewline
            Write-Host "エラー: $($_.Exception.Message)" -ForegroundColor Red
            $results += [PSCustomObject]@{
                PrimarySmtpAddress = $email
                RecipientTypeDetails = $type
                Action = "DELETE"
                Status = "ERROR"
                Message = $_.Exception.Message
                Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            }
        }
    }
}

# DISABLE処理
if ($toDisable.Count -gt 0) {
    Write-Host ""
    Write-Host "--- DISABLE（非表示）処理 ---" -ForegroundColor Yellow
    
    foreach ($item in $toDisable) {
        $email = $item.PrimarySmtpAddress
        $type = $item.RecipientTypeDetails
        
        Write-Host "  処理中: $email ($type)" -NoNewline

        if ($WhatIfMode) {
            Write-Host " → [WhatIf] スキップ" -ForegroundColor Yellow
            $results += [PSCustomObject]@{
                PrimarySmtpAddress = $email
                RecipientTypeDetails = $type
                Action = "DISABLE"
                Status = "WHATIF"
                Message = "WhatIfモード - 実際の非表示化なし"
                Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            }
            continue
        }

        try {
            # RecipientTypeDetailsに応じた非表示コマンド
            switch -Wildcard ($type) {
                "*Mailbox*" {
                    Set-Mailbox -Identity $email -HiddenFromAddressListsEnabled $true -ErrorAction Stop
                }
                "MailUser" {
                    Set-MailUser -Identity $email -HiddenFromAddressListsEnabled $true -ErrorAction Stop
                }
                "MailContact" {
                    Set-MailContact -Identity $email -HiddenFromAddressListsEnabled $true -ErrorAction Stop
                }
                "*DistributionGroup*" {
                    Set-DistributionGroup -Identity $email -HiddenFromAddressListsEnabled $true -ErrorAction Stop
                }
                "*SecurityGroup*" {
                    Set-DistributionGroup -Identity $email -HiddenFromAddressListsEnabled $true -ErrorAction Stop
                }
                "GroupMailbox" {
                    Set-UnifiedGroup -Identity $email -HiddenFromAddressListsEnabled $true -ErrorAction Stop
                }
                default {
                    # 汎用的な試行
                    Set-Mailbox -Identity $email -HiddenFromAddressListsEnabled $true -ErrorAction Stop
                }
            }

            Write-Host " → " -NoNewline
            Write-Host "非表示化完了" -ForegroundColor Green
            $results += [PSCustomObject]@{
                PrimarySmtpAddress = $email
                RecipientTypeDetails = $type
                Action = "DISABLE"
                Status = "SUCCESS"
                Message = "GALから非表示化完了"
                Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            }
        }
        catch {
            Write-Host " → " -NoNewline
            Write-Host "エラー: $($_.Exception.Message)" -ForegroundColor Red
            $results += [PSCustomObject]@{
                PrimarySmtpAddress = $email
                RecipientTypeDetails = $type
                Action = "DISABLE"
                Status = "ERROR"
                Message = $_.Exception.Message
                Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            }
        }
    }
}

# KEEP処理（記録のみ）
foreach ($item in $toKeep) {
    $results += [PSCustomObject]@{
        PrimarySmtpAddress = $item.PrimarySmtpAddress
        RecipientTypeDetails = $item.RecipientTypeDetails
        Action = "KEEP"
        Status = "SKIP"
        Message = "保持（操作なし）"
        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }
}

# REVIEW処理（記録のみ）
foreach ($item in $toReview) {
    $results += [PSCustomObject]@{
        PrimarySmtpAddress = $item.PrimarySmtpAddress
        RecipientTypeDetails = $item.RecipientTypeDetails
        Action = "REVIEW"
        Status = "SKIP"
        Message = "未決定（スキップ）"
        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }
}

#----------------------------------------------------------------------
# 結果出力
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[4/4] 結果を出力..."

$results | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "execution_results.csv")

# ステータス別集計
$successCount = ($results | Where-Object { $_.Status -eq "SUCCESS" }).Count
$errorCount = ($results | Where-Object { $_.Status -eq "ERROR" }).Count
$skipCount = ($results | Where-Object { $_.Status -eq "SKIP" }).Count
$whatifCount = ($results | Where-Object { $_.Status -eq "WHATIF" }).Count

#----------------------------------------------------------------------
# サマリー
#----------------------------------------------------------------------
$summary = @"
#===============================================================================
# 紛れ受信者 対処実行サマリー
#===============================================================================

【実行日時】$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
【モード】$(if ($WhatIfMode) { "WhatIf（ドライラン）" } else { "本番実行" })
【入力ファイル】$planFilePath
【アクション列】$ActionColumn

【処理結果】
  成功:      $successCount
  エラー:    $errorCount
  スキップ:  $skipCount
  WhatIf:    $whatifCount

【アクション別】
  DELETE実行:  $($toDelete.Count)
  DISABLE実行: $($toDisable.Count)
  KEEP（保持）: $($toKeep.Count)
  REVIEW（未決定）: $($toReview.Count)

【出力ファイル】
  execution_results.csv ← 実行結果の詳細

#-------------------------------------------------------------------------------
# 次のステップ
#-------------------------------------------------------------------------------

1. 実行結果の確認
   - execution_results.csv でエラーがないか確認
   - エラーがある場合は原因を調査

2. 紛れ検出の再実行
   - Detect-StrayRecipients.ps1 を再実行
   - STRAY_EXO_ONLY がゼロになっていることを確認

3. 削除したオブジェクトの復元（必要な場合）
   - 30日以内であればソフトデリートから復元可能
   - Undo-SoftDeletedMailbox / Restore-SoftDeletedMailbox

"@

if ($WhatIfMode) {
    $summary += @"

【WhatIfモード】
  実際の操作は行われていません。
  問題がなければ -WhatIfMode なしで再実行してください。

"@
}

if ($errorCount -gt 0) {
    $summary += @"

【警告】
  $errorCount 件のエラーが発生しました。
  execution_results.csv を確認してください。

"@
}

$summary | Out-File (Join-Path $OutDir "summary.txt") -Encoding UTF8

Write-Host ""
Write-Host "============================================================"
Write-Host " 完了"
Write-Host "============================================================"
Write-Host $summary

Stop-Transcript
Write-Host ""
Write-Host "出力先: $OutDir"

# 終了コード
if ($errorCount -gt 0) { exit 1 } else { exit 0 }
