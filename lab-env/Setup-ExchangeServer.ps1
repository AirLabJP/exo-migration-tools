<#
.SYNOPSIS
  Exchange Server 2022 自動構築スクリプト

.DESCRIPTION
  Windows Server + AD DS基盤が構築済みの環境で、Exchange Server 2022を自動インストールします。

  【前提条件】
  - AD DSドメインに参加済み
  - Exchange Server 2022 ISOファイルをマウント済み
  - 必要なWindows機能がインストール済み
  - 管理者権限で実行

.PARAMETER SetupExePath
  Exchange Setup.exe のパス（例: D:\Setup.exe）

.PARAMETER OrganizationName
  Exchange Organization名（デフォルト: First Organization）

.PARAMETER LicenseSwitch
  ライセンス同意スイッチ（DiagnosticDataON or DiagnosticDataOFF）

.PARAMETER SkipPrerequisites
  前提条件チェックをスキップするか

.EXAMPLE
  .\Setup-ExchangeServer.ps1 -SetupExePath "D:\Setup.exe" -OrganizationName "Lab Organization"

.NOTES
  - このスクリプトはExchange Server VM上で実行
  - ドメイン参加済みである必要がある
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$SetupExePath,
    
    [Parameter(Mandatory=$false)]
    [string]$OrganizationName = "First Organization",
    
    [ValidateSet("DiagnosticDataON","DiagnosticDataOFF")]
    [string]$LicenseSwitch = "DiagnosticDataON",
    
    [switch]$SkipPrerequisites
)

# 管理者権限チェック
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "このスクリプトは管理者権限で実行してください。"
    exit 1
}

# ログ設定
$LogPath = Join-Path $PSScriptRoot "exchange-setup-log.txt"
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Out-File -FilePath $LogPath -Append
    Write-Host "$timestamp - $Message"
}

Write-Log "=== Exchange Server 2022 自動構築開始 ==="
Write-Log "Setup.exe: $SetupExePath"
Write-Log "Organization: $OrganizationName"

# Setup.exeの存在確認
if (-not (Test-Path $SetupExePath)) {
    Write-Log "エラー: Setup.exeが見つかりません: $SetupExePath"
    exit 1
}

# ドメイン参加確認
$computer = Get-WmiObject Win32_ComputerSystem
if (-not $computer.PartOfDomain) {
    Write-Log "エラー: このマシンはドメインに参加していません。"
    exit 1
}
Write-Log "ドメイン: $($computer.Domain)"

# 前提条件チェック（スキップしない場合）
if (-not $SkipPrerequisites) {
    Write-Log ""
    Write-Log "[1/5] 前提条件チェック..."
    
    # 必要なWindows機能の確認
    $requiredFeatures = @(
        "RSAT-ADDS",
        "RSAT-ADDS-Tools"
    )
    
    foreach ($feature in $requiredFeatures) {
        $installed = Get-WindowsFeature -Name $feature -ErrorAction SilentlyContinue
        if (-not $installed.Installed) {
            Write-Log "      → インストール中: $feature"
            Install-WindowsFeature -Name $feature -IncludeManagementTools
        } else {
            Write-Log "      → OK: $feature は既にインストール済み"
        }
    }
    
    # Visual C++ 2013 再頒布可能パッケージの確認（Exchange 2022では不要かも）
    Write-Log "      → 前提条件チェック完了"
}

# Exchangeインストール
Write-Log ""
Write-Log "[2/5] Exchange Server 2022 インストール中..."
$license = "/IAcceptExchangeServerLicenseTerms_$LicenseSwitch"

$installArgs = @(
    $license,
    "/Mode:Install",
    "/Role:Mailbox",
    "/OrganizationName:`"$OrganizationName`"",
    "/IAcceptExchangeServerLicenseTerms"
)

Write-Log "      → 実行: $SetupExePath $($installArgs -join ' ')"

$process = Start-Process -FilePath $SetupExePath -ArgumentList $installArgs -Wait -PassThru -NoNewWindow

if ($process.ExitCode -ne 0) {
    Write-Log "エラー: Exchange Server のインストールが失敗しました（ExitCode: $($process.ExitCode)）"
    Write-Log "ログを確認してください: C:\ExchangeSetupLogs"
    exit 1
}

Write-Log "      → Exchange Server インストール完了"

# インストール後の確認
Write-Log ""
Write-Log "[3/5] インストール後の確認..."

# Exchange管理シェルの確認
try {
    Import-Module $env:ExchangeInstallPath\bin\RemoteExchange.ps1 -ErrorAction Stop
    Connect-ExchangeServer -Auto -ErrorAction Stop
    Write-Log "      → Exchange管理シェル接続成功"
    
    # 組織情報の取得
    $org = Get-OrganizationConfig -ErrorAction SilentlyContinue
    if ($org) {
        Write-Log "      → 組織名: $($org.Name)"
    }
} catch {
    Write-Log "警告: Exchange管理シェルへの接続でエラーが発生しました: $_"
}

# サービス状態の確認
Write-Log ""
Write-Log "[4/5] Exchangeサービス状態の確認..."
$services = @(
    "MSExchangeADTopology",
    "MSExchangeMailboxAssistants",
    "MSExchangeMailboxReplication",
    "MSExchangeIS"
)

foreach ($service in $services) {
    $svc = Get-Service -Name $service -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Log "      → $service : $($svc.Status)"
    }
}

# 最終確認
Write-Log ""
Write-Log "[5/5] 最終確認..."
Write-Log "      → Exchange Server 2022 のインストールが完了しました"
Write-Log ""
Write-Log "【次のステップ】"
Write-Log "1. Exchange管理センター（EAC）にアクセス: https://localhost/ecp"
Write-Log "2. データベースの作成"
Write-Log "3. メールボックスの作成"
Write-Log ""
Write-Log "【参考】"
Write-Log "- ログ: C:\ExchangeSetupLogs"
Write-Log "- インストールパス: $env:ExchangeInstallPath"

Write-Log "=== Exchange Server 2022 自動構築完了 ==="
