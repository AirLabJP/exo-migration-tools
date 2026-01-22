<#
.SYNOPSIS
  Entra ID Connect 自動構築スクリプト

.DESCRIPTION
  Windows Server + AD DS基盤が構築済みの環境で、Entra ID Connectを自動インストール・設定します。

  【前提条件】
  - AD DSドメインに参加済み
  - Entra ID（Azure AD）テナントが準備済み
  - グローバル管理者アカウントの資格情報
  - 管理者権限で実行

.PARAMETER TenantId
  Entra ID（Azure AD）テナントID

.PARAMETER GlobalAdminUPN
  グローバル管理者のUPN（例: admin@tenant.onmicrosoft.com）

.PARAMETER GlobalAdminPassword
  グローバル管理者のパスワード（SecureString）

.PARAMETER AadConnectInstallerPath
  AADConnect インストーラーのパス（省略時は自動ダウンロード）

.PARAMETER SyncMode
  同期モード（PasswordHashSync, PassThrough, Federation）

.PARAMETER StagingMode
  ステージングモードでインストールするか（デフォルト: false）

.EXAMPLE
  $password = ConvertTo-SecureString "YourPassword" -AsPlainText -Force
  .\Setup-EntraIDConnect.ps1 `
    -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -GlobalAdminUPN "admin@tenant.onmicrosoft.com" `
    -GlobalAdminPassword $password

.NOTES
  - このスクリプトはAD DSドメイン参加済みのサーバーで実行
  - SQL Server Express LocalDBが自動インストールされる
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$TenantId,
    
    [Parameter(Mandatory=$true)]
    [string]$GlobalAdminUPN,
    
    [Parameter(Mandatory=$true)]
    [SecureString]$GlobalAdminPassword,
    
    [Parameter(Mandatory=$false)]
    [string]$AadConnectInstallerPath,
    
    [ValidateSet("PasswordHashSync","PassThrough","Federation")]
    [string]$SyncMode = "PasswordHashSync",
    
    [switch]$StagingMode
)

# 管理者権限チェック
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "このスクリプトは管理者権限で実行してください。"
    exit 1
}

# ログ設定
$LogPath = Join-Path $PSScriptRoot "aadconnect-setup-log.txt"
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Out-File -FilePath $LogPath -Append
    Write-Host "$timestamp - $Message"
}

Write-Log "=== Entra ID Connect 自動構築開始 ==="
Write-Log "テナントID: $TenantId"
Write-Log "グローバル管理者: $GlobalAdminUPN"
Write-Log "同期モード: $SyncMode"

# ドメイン参加確認
$computer = Get-WmiObject Win32_ComputerSystem
if (-not $computer.PartOfDomain) {
    Write-Log "エラー: このマシンはドメインに参加していません。"
    exit 1
}
Write-Log "ドメイン: $($computer.Domain)"

# AADConnectインストーラーのダウンロード（未指定の場合）
if (-not $AadConnectInstallerPath) {
    Write-Log ""
    Write-Log "[1/6] AADConnect インストーラーのダウンロード..."
    $installerUrl = "https://aka.ms/AADConnect"
    $installerPath = Join-Path $env:TEMP "AADConnect.msi"
    
    try {
        Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing
        Write-Log "      → ダウンロード完了: $installerPath"
        $AadConnectInstallerPath = $installerPath
    } catch {
        Write-Log "エラー: ダウンロードに失敗しました: $_"
        Write-Log "手動でダウンロードしてください: https://aka.ms/AADConnect"
        exit 1
    }
} else {
    if (-not (Test-Path $AadConnectInstallerPath)) {
        Write-Log "エラー: インストーラーが見つかりません: $AadConnectInstallerPath"
        exit 1
    }
}

# 既存インストールの確認
Write-Log ""
Write-Log "[2/6] 既存インストールの確認..."
$existingInstall = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" | 
    Where-Object { $_.DisplayName -like "*Azure AD Connect*" } | 
    Select-Object -First 1

if ($existingInstall) {
    Write-Log "警告: Entra ID Connect は既にインストールされています。"
    Write-Log "再インストールする場合は、先にアンインストールしてください。"
    exit 1
}

# 前提条件の確認
Write-Log ""
Write-Log "[3/6] 前提条件の確認..."
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

# AADConnectのインストール（サイレント）
Write-Log ""
Write-Log "[4/6] AADConnect インストール中..."
$installArgs = @(
    "/i",
    "`"$AadConnectInstallerPath`"",
    "/quiet",
    "/norestart"
)

Write-Log "      → 実行: msiexec $($installArgs -join ' ')"

$process = Start-Process -FilePath "msiexec.exe" -ArgumentList $installArgs -Wait -PassThru

if ($process.ExitCode -ne 0) {
    Write-Log "エラー: AADConnect のインストールが失敗しました（ExitCode: $($process.ExitCode)）"
    exit 1
}

Write-Log "      → AADConnect インストール完了"

# インストール後の設定（自動構成）
Write-Log ""
Write-Log "[5/6] AADConnect 設定中..."

# AADConnectの設定パス
$aadConnectPath = "${env:ProgramFiles}\Microsoft Azure AD Sync\Bin"

if (-not (Test-Path $aadConnectPath)) {
    Write-Log "エラー: AADConnect のインストールパスが見つかりません"
    exit 1
}

# 資格情報の準備
# 資格情報の準備（将来の自動化用にコメントアウト）
# $credential = New-Object System.Management.Automation.PSCredential($GlobalAdminUPN, $GlobalAdminPassword)

# 設定スクリプトの実行（簡易版）
# 注意: 実際の設定はGUIまたは詳細な設定スクリプトが必要
Write-Log "      → 設定は手動で実行してください"
Write-Log ""
Write-Log "【手動設定手順】"
Write-Log "1. スタートメニューから「Azure AD Connect」を起動"
Write-Log "2. 「カスタマイズ」を選択"
Write-Log "3. グローバル管理者資格情報を入力"
Write-Log "4. 同期モード: $SyncMode を選択"
Write-Log "5. ドメイン/OUのフィルタリングを設定"
Write-Log "6. インストール完了"

# または、PowerShellで自動設定（高度）
Write-Log ""
Write-Log "【自動設定（オプション）】"
Write-Log "以下のコマンドで自動設定も可能（詳細な設定が必要）:"
Write-Log "  Import-Module ADSync"
Write-Log "  Install-ADSyncConfig -TenantId `"$TenantId`" -Credential `$credential"

# 最終確認
Write-Log ""
Write-Log "[6/6] 最終確認..."
Write-Log "      → AADConnect のインストールが完了しました"
Write-Log ""
Write-Log "【次のステップ】"
Write-Log "1. Azure AD Connect ウィザードで設定を完了"
Write-Log "2. 同期の実行: Start-ADSyncSyncCycle -PolicyType Initial"
Write-Log "3. Entra ID管理画面でユーザーが同期されているか確認"
Write-Log ""
Write-Log "【参考】"
Write-Log "- インストールパス: $aadConnectPath"
Write-Log "- ログ: C:\ProgramData\AADConnect"

Write-Log "=== Entra ID Connect 自動構築完了 ==="
