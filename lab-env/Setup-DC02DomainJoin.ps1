<#
.SYNOPSIS
  DC02のドメイン参加（ドメインコントローラーとして追加）自動化スクリプト

.DESCRIPTION
  DC02のWindows Serverインストール後、DC01のドメインにドメインコントローラーとして自動参加します。

  【前提条件】
  - DC01でドメイン構築が完了していること
  - DC02のWindows Server 2022がインストール済み
  - DC01とDC02が同じネットワークに接続されていること
  - DC01のIPアドレスが分かっていること

.PARAMETER DomainName
  ドメイン名（デフォルト: lab.local）

.PARAMETER Dc01IPAddress
  DC01のIPアドレス（必須）

.PARAMETER Dc01AdminCredential
  DC01の管理者資格情報（SecureString）

.PARAMETER SafeModePassword
  DSRMパスワード（デフォルト: P@ssw0rd123!）

.EXAMPLE
  $dc01Cred = Get-Credential -UserName "LAB\Administrator" -Message "DC01の管理者資格情報"
  .\Setup-DC02DomainJoin.ps1 -Dc01IPAddress "192.168.1.10" -Dc01AdminCredential $dc01Cred

.NOTES
  - このスクリプトはDC02のWindows Server上で実行
  - レプリケーションは自動で開始される
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$DomainName = "lab.local",
    
    [Parameter(Mandatory=$true)]
    [string]$Dc01IPAddress,
    
    [Parameter(Mandatory=$true)]
    [PSCredential]$Dc01AdminCredential,
    
    [Parameter(Mandatory=$false)]
    [SecureString]$SafeModePassword = (ConvertTo-SecureString "P@ssw0rd123!" -AsPlainText -Force)
)

# 管理者権限チェック
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "このスクリプトは管理者権限で実行してください。"
    exit 1
}

# ログ設定
$LogPath = Join-Path $PSScriptRoot "dc02-domainjoin-log.txt"
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Out-File -FilePath $LogPath -Append
    Write-Host "$timestamp - $Message"
}

Write-Log "=== DC02 ドメイン参加（ドメインコントローラー追加）開始 ==="
Write-Log "ドメイン: $DomainName"
Write-Log "DC01 IP: $Dc01IPAddress"

# Step 1: DC01への接続確認
Write-Log ""
Write-Log "[1/5] DC01への接続確認..."
try {
    $ping = Test-Connection -ComputerName $Dc01IPAddress -Count 2 -ErrorAction Stop
    Write-Log "      → DC01への接続成功"
} catch {
    Write-Log "エラー: DC01への接続に失敗しました: $_"
    exit 1
}

# Step 2: ネットワーク設定（DNSをDC01に設定）
Write-Log ""
Write-Log "[2/5] ネットワーク設定（DNSをDC01に設定）..."

$adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
if ($adapters.Count -eq 0) {
    Write-Log "エラー: 有効なネットワークアダプターが見つかりません"
    exit 1
}

foreach ($adapter in $adapters) {
    $adapterName = $adapter.Name
    Write-Log "      → アダプター '$adapterName' のDNS設定を変更中..."
    
    # 既存のDNS設定を削除
    Remove-DnsClientServerAddress -InterfaceAlias $adapterName -ErrorAction SilentlyContinue
    
    # DC01を優先DNSサーバーに設定
    Set-DnsClientServerAddress -InterfaceAlias $adapterName -ServerAddresses $Dc01IPAddress
    Write-Log "      → DNS設定完了: $Dc01IPAddress"
}

# DNS解決の確認
Start-Sleep -Seconds 3
try {
    $dc01Fqdn = Resolve-DnsName -Name $DomainName -Server $Dc01IPAddress -ErrorAction Stop
    Write-Log "      → DNS解決成功: $DomainName → $($dc01Fqdn[0].IPAddress)"
} catch {
    Write-Log "警告: DNS解決でエラーが発生しました: $_"
}

# Step 3: AD DS役割のインストール
Write-Log ""
Write-Log "[3/5] AD DS役割のインストール..."
try {
    $adRole = Get-WindowsFeature -Name AD-Domain-Services
    if (-not $adRole.Installed) {
        Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
        Write-Log "      → AD DS役割のインストール完了"
    } else {
        Write-Log "      → AD DS役割は既にインストール済み"
    }
} catch {
    Write-Log "エラー: AD DS役割のインストールに失敗しました: $_"
    exit 1
}

# Step 4: ドメインコントローラーとして追加
Write-Log ""
Write-Log "[4/5] ドメインコントローラーとして追加中..."
Write-Log "      → レプリケーションが自動で開始されます..."

try {
    # Install-ADDSDomainControllerでドメインコントローラーとして追加
    Install-ADDSDomainController `
        -DomainName $DomainName `
        -SafeModeAdministratorPassword $SafeModePassword `
        -Credential $Dc01AdminCredential `
        -Force `
        -NoRebootOnCompletion:$false
    
    Write-Log "      → ドメインコントローラー追加完了"
    Write-Log "      → サーバーを再起動します..."
    
    # 再起動（-NoRebootOnCompletion:$falseなので自動再起動）
} catch {
    Write-Log "エラー: ドメインコントローラーの追加に失敗しました: $_"
    Write-Log "      エラー詳細を確認してください"
    exit 1
}

# Step 5: 再起動後の確認（再起動後、手動で実行）
Write-Log ""
Write-Log "[5/5] 再起動後の確認（再起動後、手動で実行してください）..."
Write-Log ""
Write-Log "【再起動後、以下のコマンドでレプリケーション状態を確認】"
Write-Log "  repadmin /showrepl"
Write-Log "  dcdiag /test:replications"
Write-Log ""
Write-Log "【レプリケーション完了の確認】"
Write-Log "  以下のコマンドでレプリケーションが完了しているか確認:"
Write-Log "  repadmin /syncall /AdeP"
Write-Log ""
Write-Log "【注意】"
Write-Log "  - レプリケーションは自動で開始されます"
Write-Log "  - 完了まで数分〜数十分かかる場合があります"
Write-Log "  - レプリケーション完了後、FSMOロールの確認:"
Write-Log "    netdom query fsmo"

Write-Log ""
Write-Log "=== DC02 ドメイン参加完了 ==="
Write-Log "再起動後、レプリケーション状態を確認してください"
