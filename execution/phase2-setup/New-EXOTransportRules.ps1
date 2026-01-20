<#
.SYNOPSIS
    Exchange Online トランスポートルール一括作成スクリプト

.DESCRIPTION
    EXO移行に必要なトランスポートルールを作成します：
    
    1. Route-External-Via-GWC: 外部宛メールをGuardianWall Cloud経由でルーティング
    2. Block-External-Forwarding: 外部への自動転送をブロック
    3. Add-EXO-Loop-Marker: フォールバック経路のループ防止用ヘッダ付与
    
    【設計思想】
    - 外部宛メールは添付ファイルURL化のためGWC経由
    - 情報漏洩防止のため外部転送をブロック
    - メールループを設計段階で防止（偶然に頼らない）

.PARAMETER GwcConnectorName
    GuardianWall Cloud向けOutbound Connector名

.PARAMETER FallbackConnectorName
    内部DMZ SMTP向けOutbound Connector名（フォールバック用）

.PARAMETER WhatIfMode
    実際には作成せず確認のみ

.EXAMPLE
    # WhatIfで確認
    .\New-EXOTransportRules.ps1 -WhatIfMode

    # 本番実行
    .\New-EXOTransportRules.ps1

    # コネクタ名をカスタマイズ
    .\New-EXOTransportRules.ps1 `
        -GwcConnectorName "To-GuardianWall-Cloud" `
        -FallbackConnectorName "To-OnPrem-DMZ-Fallback"

.NOTES
    作成者: AI Assistant
    更新日: 2026-01-20
    
    【前提条件】
    - ExchangeOnlineManagement モジュールがインストール済み
    - Connect-ExchangeOnline で接続済み
    - Exchange管理者権限
    - Outbound Connectorが作成済み
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$GwcConnectorName = "To-GuardianWall-Cloud",

    [Parameter(Mandatory = $false)]
    [string]$FallbackConnectorName = "To-OnPrem-DMZ-Fallback",

    [Parameter(Mandatory = $false)]
    [switch]$WhatIfMode = $false,

    [Parameter(Mandatory = $false)]
    [string]$OutDir = ".\transport_rules_setup"
)

# ============================================================
# 日本語メッセージ出力用関数
# ============================================================
function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "=== $Message ===" -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Message)
    Write-Host "[情報] $Message" -ForegroundColor Gray
}

function Write-Success {
    param([string]$Message)
    Write-Host "[成功] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[警告] $Message" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Message)
    Write-Host "[エラー] $Message" -ForegroundColor Red
}

# ============================================================
# メイン処理
# ============================================================

# 出力先フォルダ作成
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$OutDir = Join-Path $OutDir $ts
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Start-Transcript -Path (Join-Path $OutDir "run.log") -Force

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Exchange Online トランスポートルール作成スクリプト" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "出力先: $OutDir"

if ($WhatIfMode) {
    Write-Warn "WhatIfMode が有効です。実際の作成は行いません。"
}

# ------------------------------------------------------------
# EXO接続確認
# ------------------------------------------------------------
Write-Step "Exchange Online 接続確認"

try {
    $org = Get-OrganizationConfig -ErrorAction Stop
    Write-Success "接続済み: $($org.Name)"
}
catch {
    Write-Err "Exchange Online に接続されていません。"
    Write-Err "Connect-ExchangeOnline を実行してから再度お試しください。"
    Stop-Transcript
    exit 1
}

# ------------------------------------------------------------
# Outbound Connector 存在確認
# ------------------------------------------------------------
Write-Step "Outbound Connector 存在確認"

$gwcConnector = Get-OutboundConnector -Identity $GwcConnectorName -ErrorAction SilentlyContinue
$fallbackConnector = Get-OutboundConnector -Identity $FallbackConnectorName -ErrorAction SilentlyContinue

if ($gwcConnector) {
    Write-Success "GWCコネクタ確認済み: $GwcConnectorName"
} else {
    Write-Warn "GWCコネクタが見つかりません: $GwcConnectorName"
    Write-Warn "GWCルーティングルールはスキップされます。"
}

if ($fallbackConnector) {
    Write-Success "フォールバックコネクタ確認済み: $FallbackConnectorName"
} else {
    Write-Warn "フォールバックコネクタが見つかりません: $FallbackConnectorName"
    Write-Warn "ループ防止ルールはスキップされます。"
}

# ------------------------------------------------------------
# 既存ルール確認
# ------------------------------------------------------------
Write-Step "既存トランスポートルール確認"

$existingRules = Get-TransportRule -ErrorAction SilentlyContinue
Write-Info "既存ルール数: $($existingRules.Count)"

$ruleNames = @(
    "Route-External-Via-GWC",
    "Block-External-Forwarding",
    "Add-EXO-Loop-Marker"
)

foreach ($name in $ruleNames) {
    $existing = $existingRules | Where-Object { $_.Name -eq $name }
    if ($existing) {
        Write-Warn "既存ルールあり: $name [状態: $($existing.State)]"
    }
}

# 結果記録用
$results = @()

# ------------------------------------------------------------
# ルール1: 外部宛メールをGWC経由でルーティング
# ------------------------------------------------------------
Write-Step "ルール1: Route-External-Via-GWC（外部宛→GWC経由）"

$rule1Name = "Route-External-Via-GWC"

if (-not $gwcConnector) {
    Write-Warn "GWCコネクタがないためスキップ"
    $results += [PSCustomObject]@{
        RuleName = $rule1Name
        Status = "SKIP"
        Reason = "GWCコネクタ未作成"
    }
}
elseif ($existingRules | Where-Object { $_.Name -eq $rule1Name }) {
    Write-Warn "同名のルールが既に存在します。スキップします。"
    $results += [PSCustomObject]@{
        RuleName = $rule1Name
        Status = "SKIP"
        Reason = "既存ルールあり"
    }
}
else {
    Write-Info "作成予定:"
    Write-Host "  名前: $rule1Name"
    Write-Host "  条件: 組織外（外部）宛のメール"
    Write-Host "  アクション: $GwcConnectorName 経由でルーティング"
    Write-Host "  優先度: 1"

    if (-not $WhatIfMode) {
        try {
            New-TransportRule `
                -Name $rule1Name `
                -SentToScope NotInOrganization `
                -RouteMessageOutboundConnector $GwcConnectorName `
                -Priority 1 `
                -Enabled $true `
                -ErrorAction Stop

            Write-Success "作成完了: $rule1Name"
            $results += [PSCustomObject]@{
                RuleName = $rule1Name
                Status = "SUCCESS"
                Reason = "作成完了"
            }
        }
        catch {
            Write-Err "作成失敗: $_"
            $results += [PSCustomObject]@{
                RuleName = $rule1Name
                Status = "ERROR"
                Reason = $_.Exception.Message
            }
        }
    }
    else {
        Write-Info "[WhatIf] 実際の作成は行いません"
        $results += [PSCustomObject]@{
            RuleName = $rule1Name
            Status = "WHATIF"
            Reason = "WhatIfモード"
        }
    }
}

# ------------------------------------------------------------
# ルール2: 外部転送ブロック
# ------------------------------------------------------------
Write-Step "ルール2: Block-External-Forwarding（外部転送ブロック）"

$rule2Name = "Block-External-Forwarding"

if ($existingRules | Where-Object { $_.Name -eq $rule2Name }) {
    Write-Warn "同名のルールが既に存在します。スキップします。"
    $results += [PSCustomObject]@{
        RuleName = $rule2Name
        Status = "SKIP"
        Reason = "既存ルールあり"
    }
}
else {
    Write-Info "作成予定:"
    Write-Host "  名前: $rule2Name"
    Write-Host "  条件: 組織内発、組織外宛、自動転送メッセージ"
    Write-Host "  アクション: 拒否（NDR返送）"
    Write-Host "  優先度: 0（最優先）"

    if (-not $WhatIfMode) {
        try {
            New-TransportRule `
                -Name $rule2Name `
                -FromScope InOrganization `
                -SentToScope NotInOrganization `
                -MessageTypeMatches AutoForward `
                -RejectMessageReasonText "外部への自動転送は禁止されています。External auto-forwarding is prohibited." `
                -RejectMessageEnhancedStatusCode "5.7.1" `
                -Priority 0 `
                -Enabled $true `
                -ErrorAction Stop

            Write-Success "作成完了: $rule2Name"
            $results += [PSCustomObject]@{
                RuleName = $rule2Name
                Status = "SUCCESS"
                Reason = "作成完了"
            }
        }
        catch {
            Write-Err "作成失敗: $_"
            $results += [PSCustomObject]@{
                RuleName = $rule2Name
                Status = "ERROR"
                Reason = $_.Exception.Message
            }
        }
    }
    else {
        Write-Info "[WhatIf] 実際の作成は行いません"
        $results += [PSCustomObject]@{
            RuleName = $rule2Name
            Status = "WHATIF"
            Reason = "WhatIfモード"
        }
    }
}

# ------------------------------------------------------------
# ルール3: ループ防止マーカー
# ------------------------------------------------------------
Write-Step "ルール3: Add-EXO-Loop-Marker（ループ防止）"

$rule3Name = "Add-EXO-Loop-Marker"

if (-not $fallbackConnector) {
    Write-Warn "フォールバックコネクタがないためスキップ"
    $results += [PSCustomObject]@{
        RuleName = $rule3Name
        Status = "SKIP"
        Reason = "フォールバックコネクタ未作成"
    }
}
elseif ($existingRules | Where-Object { $_.Name -eq $rule3Name }) {
    Write-Warn "同名のルールが既に存在します。スキップします。"
    $results += [PSCustomObject]@{
        RuleName = $rule3Name
        Status = "SKIP"
        Reason = "既存ルールあり"
    }
}
else {
    Write-Info "作成予定:"
    Write-Host "  名前: $rule3Name"
    Write-Host "  条件: 組織内発、フォールバックコネクタ経由、ヘッダなし"
    Write-Host "  アクション: X-EXO-Loop-Marker ヘッダを付与"
    Write-Host "  目的: 内部DMZ SMTPでループ検知可能にする"

    if (-not $WhatIfMode) {
        try {
            New-TransportRule `
                -Name $rule3Name `
                -FromScope InOrganization `
                -RouteMessageOutboundConnector $FallbackConnectorName `
                -ExceptIfHeaderContainsMessageHeader "X-EXO-Loop-Marker" `
                -ExceptIfHeaderContainsWords "true" `
                -SetHeaderName "X-EXO-Loop-Marker" `
                -SetHeaderValue "true" `
                -Priority 2 `
                -Enabled $true `
                -ErrorAction Stop

            Write-Success "作成完了: $rule3Name"
            $results += [PSCustomObject]@{
                RuleName = $rule3Name
                Status = "SUCCESS"
                Reason = "作成完了"
            }
        }
        catch {
            Write-Err "作成失敗: $_"
            $results += [PSCustomObject]@{
                RuleName = $rule3Name
                Status = "ERROR"
                Reason = $_.Exception.Message
            }
        }
    }
    else {
        Write-Info "[WhatIf] 実際の作成は行いません"
        $results += [PSCustomObject]@{
            RuleName = $rule3Name
            Status = "WHATIF"
            Reason = "WhatIfモード"
        }
    }
}

# ------------------------------------------------------------
# 結果出力
# ------------------------------------------------------------
$results | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "creation_results.csv")

# ------------------------------------------------------------
# 内部DMZ SMTP側の設定案内
# ------------------------------------------------------------
Write-Step "内部DMZ SMTP側の設定（手動）"

Write-Host ""
Write-Host "【重要】内部DMZ SMTP（Postfix）に以下のループ防止設定を追加してください:" -ForegroundColor Yellow
Write-Host ""
Write-Host "# /etc/postfix/header_checks に追加" -ForegroundColor Cyan
Write-Host '/^X-EXO-Loop-Marker: true/ REJECT Mail loop detected (already routed via EXO fallback)'
Write-Host ""
Write-Host "# 設定反映" -ForegroundColor Cyan
Write-Host "postmap /etc/postfix/header_checks"
Write-Host "postfix reload"
Write-Host ""

# ------------------------------------------------------------
# サマリー
# ------------------------------------------------------------
$successCount = ($results | Where-Object { $_.Status -eq "SUCCESS" }).Count
$skipCount = ($results | Where-Object { $_.Status -eq "SKIP" }).Count
$errorCount = ($results | Where-Object { $_.Status -eq "ERROR" }).Count
$whatifCount = ($results | Where-Object { $_.Status -eq "WHATIF" }).Count

$summary = @"
#===============================================================================
# EXO トランスポートルール作成サマリー
#===============================================================================

【実行日時】$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
【モード】$(if ($WhatIfMode) { "WhatIf（ドライラン）" } else { "本番実行" })

【処理結果】
  成功:      $successCount
  スキップ:  $skipCount
  エラー:    $errorCount
  WhatIf:    $whatifCount

#-------------------------------------------------------------------------------
# 作成されるルール
#-------------------------------------------------------------------------------

1. Route-External-Via-GWC
   条件: 組織外宛のメール
   動作: GuardianWall Cloud経由でルーティング
   目的: 添付ファイルのURL化

2. Block-External-Forwarding
   条件: 組織内発、組織外宛、自動転送
   動作: 拒否（NDR返送）
   目的: 情報漏洩防止、転送の横行を防止

3. Add-EXO-Loop-Marker
   条件: 組織内発、フォールバックコネクタ経由
   動作: X-EXO-Loop-Marker ヘッダ付与
   目的: 内部DMZ SMTPでループ検知

#-------------------------------------------------------------------------------
# 次のステップ
#-------------------------------------------------------------------------------

1. 作成されたルールの動作確認
   - テストメールを送信してMessage Traceで確認
   - 外部宛がGWC経由になっているか
   - 転送がブロックされるか

2. 内部DMZ SMTP側のループ防止設定
   - header_checks に上記の設定を追加
   - postfix reload で反映

3. メールフローテスト
   - 外部宛送信テスト
   - 転送テスト（ブロックされることを確認）
   - フォールバック経路テスト

"@

if ($WhatIfMode) {
    $summary += @"

【WhatIfモード】
  実際のルール作成は行われていません。
  問題がなければ -WhatIfMode なしで再実行してください。

"@
}

$summary | Out-File (Join-Path $OutDir "summary.txt") -Encoding UTF8

Write-Host ""
Write-Host "============================================================"
Write-Host " 完了"
Write-Host "============================================================"
Write-Host $summary

if ($errorCount -gt 0) {
    Write-Err "$errorCount 件のエラーが発生しました。creation_results.csv を確認してください。"
}

Stop-Transcript
Write-Host ""
Write-Host "出力先: $OutDir"

# 終了コード
if ($errorCount -gt 0) { exit 1 } else { exit 0 }
