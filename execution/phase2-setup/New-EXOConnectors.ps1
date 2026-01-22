<#
.SYNOPSIS
    Exchange Online コネクタ作成スクリプト

.DESCRIPTION
    EXO移行に必要な3つのコネクタを作成します：
    - Outbound #1: 送信セキュリティサービス向け（外部送信の添付URL化）
    - Outbound #2: 内部DMZ SMTP向け（未移行ユーザーへのフォールバック）
    - Inbound #1: AWS DMZ SMTPからの受信許可

.PARAMETER MailSecurityHost
    送信セキュリティサービスのSMTPホスト名

.PARAMETER OnPremDmzSmtpHost
    内部DMZ SMTPサーバーのホスト名（FQDN）

.PARAMETER AwsDmzSmtpIP
    AWS DMZ SMTPサーバーのグローバルIPアドレス

.PARAMETER TargetDomainsFile
    移行対象ドメイン一覧ファイル（1行1ドメイン）

.PARAMETER WhatIfMode
    $true の場合、実際には作成せず確認のみ

.EXAMPLE
    .\New-EXOConnectors.ps1 `
        -MailSecurityHost "mailsecurity.example.com" `
        -OnPremDmzSmtpHost "dmz-smtp.internal.example.co.jp" `
        -AwsDmzSmtpIP "203.0.113.10" `
        -TargetDomainsFile ".\domains.txt"

.NOTES
    作成者: AI Assistant
    更新日: 2026-01-17
    
    【前提条件】
    - ExchangeOnlineManagement モジュールがインストール済み
    - Connect-ExchangeOnline で接続済み
    - 全体管理者またはExchange管理者権限
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$MailSecurityHost,

    [Parameter(Mandatory = $true)]
    [string]$OnPremDmzSmtpHost,

    [Parameter(Mandatory = $true)]
    [string]$AwsDmzSmtpIP,

    [Parameter(Mandatory = $false)]
    [string]$TargetDomainsFile,

    [Parameter(Mandatory = $false)]
    [string[]]$TargetDomains,

    [Parameter(Mandatory = $false)]
    [switch]$WhatIfMode = $false
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

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Exchange Online コネクタ作成スクリプト" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

if ($WhatIfMode) {
    Write-Warn "WhatIfMode が有効です。実際の作成は行いません。"
}

# ------------------------------------------------------------
# 移行対象ドメインの読み込み
# ------------------------------------------------------------
Write-Step "移行対象ドメインの確認"

$domains = @()

if ($TargetDomainsFile -and (Test-Path $TargetDomainsFile)) {
    Write-Info "ファイルからドメイン一覧を読み込み: $TargetDomainsFile"
    $domains = Get-Content $TargetDomainsFile | Where-Object { $_ -and $_.Trim() -ne "" }
}
elseif ($TargetDomains -and $TargetDomains.Count -gt 0) {
    $domains = $TargetDomains
}
else {
    Write-Err "移行対象ドメインが指定されていません。"
    Write-Err "-TargetDomainsFile または -TargetDomains パラメータを指定してください。"
    exit 1
}

Write-Info "移行対象ドメイン数: $($domains.Count)"
foreach ($d in $domains) {
    Write-Host "  - $d"
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
    exit 1
}

# ------------------------------------------------------------
# 既存コネクタの確認
# ------------------------------------------------------------
Write-Step "既存コネクタの確認"

$existingOutbound = Get-OutboundConnector -ErrorAction SilentlyContinue
$existingInbound = Get-InboundConnector -ErrorAction SilentlyContinue

Write-Info "既存 Outbound Connector: $($existingOutbound.Count) 件"
foreach ($c in $existingOutbound) {
    Write-Host "  - $($c.Name) [有効: $($c.Enabled)]"
}

Write-Info "既存 Inbound Connector: $($existingInbound.Count) 件"
foreach ($c in $existingInbound) {
    Write-Host "  - $($c.Name) [有効: $($c.Enabled)]"
}

# ------------------------------------------------------------
# Outbound #1: 送信セキュリティサービス向け
# ------------------------------------------------------------
Write-Step "Outbound Connector #1: 送信セキュリティサービス向け（外部送信）"

$gwcConnectorName = "To-MailSecurity-Service"

if ($existingOutbound | Where-Object { $_.Name -eq $gwcConnectorName }) {
    Write-Warn "同名のコネクタが既に存在します: $gwcConnectorName"
    Write-Warn "スキップします。更新が必要な場合は手動で削除してください。"
}
else {
    Write-Info "作成予定:"
    Write-Host "  名前: $gwcConnectorName"
    Write-Host "  SmartHost: $MailSecurityHost"
    Write-Host "  用途: 外部宛メールをGWC経由で送信（添付URL化）"
    Write-Host "  対象: 全外部ドメイン（トランスポートルールでスコープ制御推奨）"

    if (-not $WhatIfMode) {
        try {
            New-OutboundConnector `
                -Name $gwcConnectorName `
                -ConnectorType Partner `
                -SmartHosts $MailSecurityHost `
                -TlsSettings EncryptionOnly `
                -UseMXRecord $false `
                -RecipientDomains "*" `
                -IsTransportRuleScoped $true `
                -Enabled $true `
                -ErrorAction Stop

            Write-Success "作成完了: $gwcConnectorName"
        }
        catch {
            Write-Err "作成失敗: $_"
        }
    }
}

# ------------------------------------------------------------
# Outbound #2: 内部DMZ SMTP向け（フォールバック）
# ------------------------------------------------------------
Write-Step "Outbound Connector #2: 内部DMZ SMTP向け（フォールバック）"

$dmzConnectorName = "To-OnPrem-DMZ-Fallback"

if ($existingOutbound | Where-Object { $_.Name -eq $dmzConnectorName }) {
    Write-Warn "同名のコネクタが既に存在します: $dmzConnectorName"
    Write-Warn "スキップします。更新が必要な場合は手動で削除してください。"
}
else {
    Write-Info "作成予定:"
    Write-Host "  名前: $dmzConnectorName"
    Write-Host "  SmartHost: $OnPremDmzSmtpHost"
    Write-Host "  用途: Internal Relay で EXO にメールボックスがない宛先を転送"
    Write-Host "  対象ドメイン: $($domains -join ', ')"

    if (-not $WhatIfMode) {
        try {
            New-OutboundConnector `
                -Name $dmzConnectorName `
                -ConnectorType OnPremises `
                -SmartHosts $OnPremDmzSmtpHost `
                -TlsSettings EncryptionOnly `
                -UseMXRecord $false `
                -RecipientDomains $domains `
                -Enabled $true `
                -ErrorAction Stop

            Write-Success "作成完了: $dmzConnectorName"
        }
        catch {
            Write-Err "作成失敗: $_"
        }
    }
}

# ------------------------------------------------------------
# Inbound #1: AWS DMZ SMTPから
# ------------------------------------------------------------
Write-Step "Inbound Connector #1: AWS DMZ SMTPからの受信"

$awsConnectorName = "From-AWS-DMZ-SMTP"

if ($existingInbound | Where-Object { $_.Name -eq $awsConnectorName }) {
    Write-Warn "同名のコネクタが既に存在します: $awsConnectorName"
    Write-Warn "スキップします。更新が必要な場合は手動で削除してください。"
}
else {
    Write-Info "作成予定:"
    Write-Host "  名前: $awsConnectorName"
    Write-Host "  送信元IP: $AwsDmzSmtpIP"
    Write-Host "  用途: AWS DMZ SMTPからの内部メール受信を許可"
    Write-Host "  TLS必須: はい"

    if (-not $WhatIfMode) {
        try {
            New-InboundConnector `
                -Name $awsConnectorName `
                -ConnectorType Partner `
                -SenderIPAddresses $AwsDmzSmtpIP `
                -RestrictDomainsToIPAddresses $true `
                -RequireTls $true `
                -Enabled $true `
                -ErrorAction Stop

            Write-Success "作成完了: $awsConnectorName"
        }
        catch {
            Write-Err "作成失敗: $_"
        }
    }
}

# ------------------------------------------------------------
# Accepted Domain の確認
# ------------------------------------------------------------
Write-Step "Accepted Domain の確認（Internal Relay設定）"

Write-Info "移行対象ドメインは Internal Relay として設定する必要があります。"
Write-Info "以下のコマンドで設定してください:"
Write-Host ""

foreach ($d in $domains) {
    Write-Host "  Set-AcceptedDomain -Identity `"$d`" -DomainType InternalRelay" -ForegroundColor Yellow
}

Write-Host ""
Write-Warn "Internal Relay の意味:"
Write-Host "  - EXOにメールボックスがある宛先 → EXO配信"
Write-Host "  - EXOにメールボックスがない宛先 → Outbound Connector で転送"
Write-Host "  - 全員移行完了後は Authoritative に変更"

# ------------------------------------------------------------
# 結果サマリー
# ------------------------------------------------------------
Write-Step "作成結果サマリー"

Write-Host ""
Write-Host "【作成したコネクタ】" -ForegroundColor Cyan
Write-Host "┌────────────────────────────────────────────────────────────┐"
Write-Host "│ # │ 種類     │ 名前                      │ 宛先/送信元    │"
Write-Host "├───┼──────────┼───────────────────────────┼────────────────┤"
Write-Host "│ 1 │ Outbound │ To-MailSecurity-Service     │ $MailSecurityHost"
Write-Host "│ 2 │ Outbound │ To-OnPrem-DMZ-Fallback    │ $OnPremDmzSmtpHost"
Write-Host "│ 3 │ Inbound  │ From-AWS-DMZ-SMTP         │ $AwsDmzSmtpIP"
Write-Host "└────────────────────────────────────────────────────────────┘"
Write-Host ""

Write-Host "【次のステップ】" -ForegroundColor Cyan
Write-Host "1. Accepted Domain を Internal Relay に設定"
Write-Host "2. GWC向けコネクタのスコープをトランスポートルールで制御"
Write-Host "3. テストメール送受信で動作確認"
Write-Host ""

if ($WhatIfMode) {
    Write-Warn "WhatIfMode でした。実際に作成するには -WhatIfMode を外して再実行してください。"
}

Write-Host "完了しました。" -ForegroundColor Green
