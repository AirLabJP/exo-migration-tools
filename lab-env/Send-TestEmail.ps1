<#
.SYNOPSIS
  検証用メール送信スクリプト（Thunderbird代替）

.DESCRIPTION
  検証環境でメールフローをテストするためのSMTP送信スクリプト。
  Thunderbirdが使えない環境でも、PowerShellからメール送信が可能です。

  【送信パターン】
  1. 内部宛（Courier IMAP / 未移行ユーザー）
  2. Exchange Online宛（移行済みユーザー）
  3. 外部宛（インターネット）

.PARAMETER To
  宛先メールアドレス（必須）

.PARAMETER From
  送信元メールアドレス（デフォルト: testuser01@lab.local）

.PARAMETER Subject
  件名（デフォルト: Test Email）

.PARAMETER Body
  本文（デフォルト: テストメールです）

.PARAMETER SmtpServer
  SMTPサーバー（デフォルト: postfix.lab.local または localhost）

.PARAMETER SmtpPort
  SMTPポート（デフォルト: 25）

.PARAMETER UseSsl
  SSL/TLSを使用するか（デフォルト: false）

.PARAMETER Credential
  SMTP認証用の資格情報（必要に応じて）

.PARAMETER AttachmentPath
  添付ファイルのパス（オプション）

.EXAMPLE
  # 内部宛（Courier IMAP）
  .\Send-TestEmail.ps1 -To "testuser02@lab.local" -Subject "内部宛テスト"

.EXAMPLE
  # Exchange Online宛
  .\Send-TestEmail.ps1 -To "user@exo-tenant.onmicrosoft.com" -Subject "EXO宛テスト"

.EXAMPLE
  # 外部宛
  .\Send-TestEmail.ps1 -To "your-email@gmail.com" -Subject "外部宛テスト"

.EXAMPLE
  # 添付ファイル付き
  .\Send-TestEmail.ps1 -To "test@lab.local" -AttachmentPath "C:\test.txt"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$To,
    
    [Parameter(Mandatory=$false)]
    [string]$From = "testuser01@lab.local",
    
    [Parameter(Mandatory=$false)]
    [string]$Subject = "Test Email",
    
    [Parameter(Mandatory=$false)]
    [string]$Body = "これは検証用のテストメールです。`n`n送信時刻: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    
    [Parameter(Mandatory=$false)]
    [string]$SmtpServer,
    
    [Parameter(Mandatory=$false)]
    [int]$SmtpPort = 25,
    
    [Parameter(Mandatory=$false)]
    [switch]$UseSsl,
    
    [Parameter(Mandatory=$false)]
    [PSCredential]$Credential,
    
    [Parameter(Mandatory=$false)]
    [string]$AttachmentPath
)

# SMTPサーバーの自動検出
if (-not $SmtpServer) {
    # ローカル環境（Docker）の場合
    $SmtpServer = "localhost"
    
    # ポート25が使えない場合は2525（DMZ SMTP）を試す
    $testConnection = Test-NetConnection -ComputerName $SmtpServer -Port 25 -WarningAction SilentlyContinue -InformationLevel Quiet
    if (-not $testConnection) {
        $SmtpServer = "localhost"
        $SmtpPort = 2525
        Write-Host "ポート25が使用できないため、ポート2525を使用します" -ForegroundColor Yellow
    }
}

Write-Host "============================================================"
Write-Host " 検証用メール送信"
Write-Host "============================================================"
Write-Host "送信元: $From"
Write-Host "宛先:   $To"
Write-Host "件名:   $Subject"
Write-Host "SMTP:   ${SmtpServer}:${SmtpPort}"
Write-Host ""

# メールメッセージの作成
$mailParams = @{
    From = $From
    To = $To
    Subject = $Subject
    Body = $Body
    SmtpServer = $SmtpServer
    Port = $SmtpPort
    UseSsl = $UseSsl
    Encoding = [System.Text.Encoding]::UTF8
}

# 認証が必要な場合
if ($Credential) {
    $mailParams.Credential = $Credential
}

# 添付ファイル
if ($AttachmentPath -and (Test-Path $AttachmentPath)) {
    $mailParams.Attachments = $AttachmentPath
    Write-Host "添付ファイル: $AttachmentPath"
}

# メール送信
try {
    Write-Host "メール送信中..."
    Send-MailMessage @mailParams -ErrorAction Stop
    Write-Host ""
    Write-Host "✅ メール送信成功" -ForegroundColor Green
    Write-Host ""
    Write-Host "【送信パターン判定】"
    
    # 宛先に基づく送信パターンの判定
    if ($To -match "@lab\.local$") {
        Write-Host "  → 内部宛（Courier IMAP / 未移行ユーザー）" -ForegroundColor Cyan
        Write-Host "    経路: Postfix → Courier IMAP"
    }
    elseif ($To -match "@.*\.onmicrosoft\.com$|@.*\.mail\.protection\.outlook\.com$") {
        Write-Host "  → Exchange Online宛（移行済みユーザー）" -ForegroundColor Cyan
        Write-Host "    経路: Postfix → AWS DMZ SMTP → Exchange Online"
    }
    else {
        Write-Host "  → 外部宛（インターネット）" -ForegroundColor Cyan
        Write-Host "    経路: Postfix → GuardianWall → AWS DMZ SMTP → インターネット"
    }
    
} catch {
    Write-Host ""
    Write-Host "❌ メール送信失敗" -ForegroundColor Red
    Write-Host "エラー: $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "【トラブルシューティング】"
    Write-Host "1. SMTPサーバーが起動しているか確認: Test-NetConnection -ComputerName $SmtpServer -Port $SmtpPort"
    Write-Host "2. ファイアウォール設定を確認"
    Write-Host "3. SMTPサーバーのログを確認"
    exit 1
}

Write-Host ""
Write-Host "============================================================"
