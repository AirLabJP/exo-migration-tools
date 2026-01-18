<#
.SYNOPSIS
  Exchange Online移行 検証環境構築スクリプト（Windows Server + AD DS）

.DESCRIPTION
  Windows Server上でActive Directory Domain Services（AD DS）を自動構築し、
  検証用ドメイン（lab.local）を作成します。

  実行内容:
  1. AD DS役割のインストール
  2. ドメインコントローラーの昇格
  3. テストユーザー・グループの作成
  4. DNS設定の確認

.PARAMETER DomainName
  作成するドメイン名（デフォルト: lab.local）

.PARAMETER NetBIOSName
  NetBIOS名（デフォルト: LAB）

.PARAMETER SafeModePassword
  DSRM（Directory Services Restore Mode）パスワード（デフォルト: P@ssw0rd123!）

.EXAMPLE
  .\Setup-LabEnvironment.ps1

.EXAMPLE
  .\Setup-LabEnvironment.ps1 -DomainName "test.local" -NetBIOSName "TEST"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$DomainName = "lab.local",
    
    [Parameter(Mandatory=$false)]
    [string]$NetBIOSName = "LAB",
    
    [Parameter(Mandatory=$false)]
    [SecureString]$SafeModePassword = (ConvertTo-SecureString "P@ssw0rd123!" -AsPlainText -Force)
)

# 管理者権限チェック
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "このスクリプトは管理者権限で実行してください。"
    exit 1
}

# ログ設定
$LogPath = Join-Path $PSScriptRoot "setup-log.txt"
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Out-File -FilePath $LogPath -Append
    Write-Host "$timestamp - $Message"
}

Write-Log "=== Exchange Online移行 検証環境構築開始 ==="
Write-Log "ドメイン名: $DomainName"
Write-Log "NetBIOS名: $NetBIOSName"

# Step 1: AD DS役割のインストール
Write-Log "Step 1: AD DS役割のインストール中..."
try {
    $adRole = Get-WindowsFeature -Name AD-Domain-Services
    if (-not $adRole.Installed) {
        Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
        Write-Log "AD DS役割のインストールが完了しました。"
    } else {
        Write-Log "AD DS役割は既にインストール済みです。"
    }
} catch {
    Write-Log "エラー: AD DS役割のインストールに失敗しました。 - $_"
    exit 1
}

# Step 2: 既存ドメインコントローラーの確認
$isDC = (Get-WmiObject Win32_ComputerSystem).PartOfDomain -and (Get-WmiObject Win32_ComputerSystem).DomainRole -eq 5
if ($isDC) {
    Write-Log "警告: このサーバーは既にドメインコントローラーです。"
    Write-Log "現在のドメイン: $((Get-WmiObject Win32_ComputerSystem).Domain)"
    $continue = Read-Host "続行しますか？ (Y/N)"
    if ($continue -ne "Y" -and $continue -ne "y") {
        exit 0
    }
} else {
    # Step 3: ドメインコントローラーの昇格
    Write-Log "Step 2: ドメインコントローラーの昇格中..."
    
    $ForestName = $DomainName
    $DomainNetBIOSName = $NetBIOSName
    
    try {
        # AD DSフォレストのインストール（新しいフォレストを作成）
        Install-ADDSForest `
            -CreateDnsDelegation:$false `
            -DatabasePath "C:\Windows\NTDS" `
            -DomainMode "WinThreshold" `
            -DomainName $ForestName `
            -DomainNetbiosName $DomainNetBIOSName `
            -ForestMode "WinThreshold" `
            -InstallDns:$true `
            -LogPath "C:\Windows\NTDS" `
            -NoRebootOnCompletion:$false `
            -SafeModeAdministratorPassword $SafeModePassword `
            -SysvolPath "C:\Windows\SYSVOL" `
            -Force:$true
        
        Write-Log "ドメインコントローラーの昇格が完了しました。"
        Write-Log "サーバーを再起動します..."
        # 再起動後、このスクリプトを再度実行する必要があります
    } catch {
        Write-Log "エラー: ドメインコントローラーの昇格に失敗しました。 - $_"
        exit 1
    }
    
    # 再起動が発生するため、ここで終了
    Write-Log "再起動後、続きの処理を実行してください。"
    exit 0
}

# Step 4: 再起動後の処理（ドメインコントローラー昇格済みの場合）
Write-Log "Step 3: テストユーザー・グループの作成中..."

# Active Directoryモジュールのインポート
Import-Module ActiveDirectory -ErrorAction SilentlyContinue

# 組織単位（OU）の作成
try {
    $ouPath = "OU=Users,DC=$($DomainName.Replace('.',',DC='))"
    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouPath'" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name "Users" -Path "DC=$($DomainName.Replace('.',',DC='))" -ProtectedFromAccidentalDeletion $false
        Write-Log "組織単位 'Users' を作成しました。"
    } else {
        Write-Log "組織単位 'Users' は既に存在します。"
    }
} catch {
    Write-Log "警告: 組織単位の作成でエラーが発生しました（既存の可能性があります）。 - $_"
}

# テストユーザーの作成
$testUsers = @(
    @{
        Name = "TestUser01"
        UserPrincipalName = "testuser01@$DomainName"
        SamAccountName = "testuser01"
        EmailAddress = "testuser01@$DomainName"
        DisplayName = "Test User 01"
        Password = "P@ssw0rd123"
    },
    @{
        Name = "TestUser02"
        UserPrincipalName = "testuser02@$DomainName"
        SamAccountName = "testuser02"
        EmailAddress = "testuser02@$DomainName"
        DisplayName = "Test User 02"
        Password = "P@ssw0rd123"
    }
)

foreach ($user in $testUsers) {
    try {
        $existingUser = Get-ADUser -Filter "SamAccountName -eq '$($user.SamAccountName)'" -ErrorAction SilentlyContinue
        if (-not $existingUser) {
            $ouPath = "OU=Users,DC=$($DomainName.Replace('.',',DC='))"
            New-ADUser `
                -Name $user.Name `
                -UserPrincipalName $user.UserPrincipalName `
                -SamAccountName $user.SamAccountName `
                -Path $ouPath `
                -EmailAddress $user.EmailAddress `
                -DisplayName $user.DisplayName `
                -AccountPassword (ConvertTo-SecureString $user.Password -AsPlainText -Force) `
                -Enabled $true `
                -PasswordNeverExpires $true
            
            # メール属性の設定（proxyAddresses）
            Set-ADUser -Identity $user.SamAccountName -Add @{
                proxyAddresses = @("SMTP:$($user.EmailAddress)")
            }
            
            Write-Log "テストユーザー '$($user.SamAccountName)' を作成しました。"
        } else {
            Write-Log "テストユーザー '$($user.SamAccountName)' は既に存在します。"
        }
    } catch {
        Write-Log "警告: ユーザー '$($user.SamAccountName)' の作成でエラーが発生しました。 - $_"
    }
}

# Step 5: DNS設定の確認
Write-Log "Step 4: DNS設定の確認中..."
try {
    $dnsZones = Get-DnsServerZone
    Write-Log "DNSゾーン一覧:"
    foreach ($zone in $dnsZones) {
        Write-Log "  - $($zone.ZoneName)"
    }
} catch {
    Write-Log "警告: DNS設定の確認でエラーが発生しました。 - $_"
}

# Step 6: 環境情報の出力
Write-Log "Step 5: 環境情報の出力..."
$envInfo = @{
    DomainName = $DomainName
    NetBIOSName = $NetBIOSName
    ComputerName = $env:COMPUTERNAME
    FQDN = "$env:COMPUTERNAME.$DomainName"
    TestUsers = $testUsers | ForEach-Object { $_.UserPrincipalName }
}

$envInfoPath = Join-Path $PSScriptRoot "environment-info.json"
$envInfo | ConvertTo-Json -Depth 3 | Out-File -FilePath $envInfoPath -Encoding UTF8
Write-Log "環境情報を '$envInfoPath' に保存しました。"

Write-Log "=== 検証環境構築完了 ==="
Write-Log ""
Write-Log "【作成された環境】"
Write-Log "ドメイン: $DomainName"
Write-Log "テストユーザー:"
foreach ($user in $testUsers) {
    Write-Log "  - $($user.UserPrincipalName) (パスワード: $($user.Password))"
}
Write-Log ""
Write-Log "【次のステップ】"
Write-Log "1. Docker環境を起動: docker-compose up -d"
Write-Log "2. メールフローのテストを実行"
