<#
.SYNOPSIS
  Active Directory Domain Services 2台構成（レプリケーション）構築スクリプト

.DESCRIPTION
  Hyper-V上で2台のWindows Server VMを立てて、AD DSレプリケーション環境を構築します。

  【構成】
  - DC01: 最初のドメインコントローラー（Schema Master等のFSMOロール）
  - DC02: 追加のドメインコントローラー（レプリケーション）

  【前提条件】
  - Hyper-Vが有効なWindows Server（親ホスト）
  - Windows Server 2022 ISOファイル
  - 十分なリソース（RAM 8GB以上、ディスク 120GB以上）

.PARAMETER DomainName
  作成するドメイン名（デフォルト: lab.local）

.PARAMETER NetBIOSName
  NetBIOS名（デフォルト: LAB）

.PARAMETER IsoPath
  Windows Server 2022 ISOファイルのパス

.PARAMETER VmPath
  VMファイルの保存先（デフォルト: C:\VMs）

.PARAMETER SafeModePassword
  DSRMパスワード（デフォルト: P@ssw0rd123!）

.EXAMPLE
  .\Setup-ADDSReplication.ps1 -IsoPath "D:\ISO\Windows_Server_2022.iso"

.NOTES
  - このスクリプトは親ホスト（Hyper-Vホスト）で実行
  - DC01とDC02の2台のVMを自動作成
  - DC01でドメイン作成、DC02でドメイン参加
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$DomainName = "lab.local",
    
    [Parameter(Mandatory=$false)]
    [string]$NetBIOSName = "LAB",
    
    [Parameter(Mandatory=$true)]
    [string]$IsoPath,
    
    [Parameter(Mandatory=$false)]
    [string]$VmPath = "C:\VMs",
    
    [Parameter(Mandatory=$false)]
    [SecureString]$SafeModePassword = (ConvertTo-SecureString "P@ssw0rd123!" -AsPlainText -Force)
)

# 管理者権限チェック
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "このスクリプトは管理者権限で実行してください。"
    exit 1
}

# Hyper-Vモジュールの確認
if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
    Write-Error "Hyper-Vモジュールが見つかりません。Hyper-V役割をインストールしてください。"
    exit 1
}

Import-Module Hyper-V

# ISOファイルの確認
if (-not (Test-Path $IsoPath)) {
    Write-Error "ISOファイルが見つかりません: $IsoPath"
    exit 1
}

# VM設定
$vmConfig = @{
    DC01 = @{
        Name = "DC01"
        Memory = 4GB
        DiskSize = 60GB
        ProcessorCount = 2
    }
    DC02 = @{
        Name = "DC02"
        Memory = 4GB
        DiskSize = 60GB
        ProcessorCount = 2
    }
}

# VM保存先の作成
if (-not (Test-Path $VmPath)) {
    New-Item -ItemType Directory -Path $VmPath -Force | Out-Null
}

Write-Host "============================================================"
Write-Host " AD DS 2台構成（レプリケーション）構築"
Write-Host "============================================================"
Write-Host "ドメイン名: $DomainName"
Write-Host "ISOファイル: $IsoPath"
Write-Host "VM保存先: $VmPath"
Write-Host ""

# Step 1: DC01の作成とドメイン構築
Write-Host "[Step 1/4] DC01 VMの作成..."
$dc01Path = Join-Path $VmPath "DC01"
$dc01Vhd = Join-Path $dc01Path "DC01.vhdx"

if (-not (Get-VM -Name $vmConfig.DC01.Name -ErrorAction SilentlyContinue)) {
    # VM作成
    New-VM -Name $vmConfig.DC01.Name `
        -MemoryStartupBytes $vmConfig.DC01.Memory `
        -Generation 2 `
        -Path $dc01Path | Out-Null
    
    # 仮想ハードディスク作成
    New-VHD -Path $dc01Vhd -SizeBytes $vmConfig.DC01.DiskSize -Dynamic | Out-Null
    Add-VMHardDiskDrive -VMName $vmConfig.DC01.Name -Path $dc01Vhd
    
    # プロセッサ設定
    Set-VMProcessor -VMName $vmConfig.DC01.Name -Count $vmConfig.DC01.ProcessorCount
    
    # ISOマウント
    Set-VMDvdDrive -VMName $vmConfig.DC01.Name -Path $IsoPath
    
    # ネットワークアダプター（内部ネットワーク）
    $switch = Get-VMSwitch -Name "Internal" -ErrorAction SilentlyContinue
    if (-not $switch) {
        $switch = New-VMSwitch -Name "Internal" -SwitchType Internal
    }
    Connect-VMNetworkAdapter -VMName $vmConfig.DC01.Name -SwitchName $switch.Name
    
    Write-Host "      → DC01 VMを作成しました"
} else {
    Write-Host "      → DC01 VMは既に存在します"
}

# Step 2: DC02の作成
Write-Host ""
Write-Host "[Step 2/4] DC02 VMの作成..."
$dc02Path = Join-Path $VmPath "DC02"
$dc02Vhd = Join-Path $dc02Path "DC02.vhdx"

if (-not (Get-VM -Name $vmConfig.DC02.Name -ErrorAction SilentlyContinue)) {
    # VM作成
    New-VM -Name $vmConfig.DC02.Name `
        -MemoryStartupBytes $vmConfig.DC02.Memory `
        -Generation 2 `
        -Path $dc02Path | Out-Null
    
    # 仮想ハードディスク作成
    New-VHD -Path $dc02Vhd -SizeBytes $vmConfig.DC02.DiskSize -Dynamic | Out-Null
    Add-VMHardDiskDrive -VMName $vmConfig.DC02.Name -Path $dc02Vhd
    
    # プロセッサ設定
    Set-VMProcessor -VMName $vmConfig.DC02.Name -Count $vmConfig.DC02.ProcessorCount
    
    # ISOマウント
    Set-VMDvdDrive -VMName $vmConfig.DC02.Name -Path $IsoPath
    
    # ネットワークアダプター（同じスイッチ）
    Connect-VMNetworkAdapter -VMName $vmConfig.DC02.Name -SwitchName $switch.Name
    
    Write-Host "      → DC02 VMを作成しました"
} else {
    Write-Host "      → DC02 VMは既に存在します"
}

# Step 3: DC01の起動とドメイン構築指示
Write-Host ""
Write-Host "[Step 3/4] DC01の起動..."
Start-VM -Name $vmConfig.DC01.Name
Write-Host "      → DC01を起動しました"
Write-Host ""
Write-Host "【手動作業が必要】"
Write-Host "1. Hyper-VマネージャーでDC01に接続"
Write-Host "2. Windows Server 2022をインストール（Desktop Experienceを選択）"
Write-Host "3. インストール後、DC01で以下のスクリプトを実行:"
Write-Host "   .\Setup-LabEnvironment.ps1 -DomainName `"$DomainName`" -NetBIOSName `"$NetBIOSName`""
Write-Host "4. DC01の再起動後、続きの処理を実行"

# Step 4: DC02の起動とドメイン参加指示
Write-Host ""
Write-Host "[Step 4/4] DC02の起動..."
Start-VM -Name $vmConfig.DC02.Name
Write-Host "      → DC02を起動しました"
Write-Host ""
Write-Host "【DC01のドメイン構築完了後】"
Write-Host "1. Hyper-VマネージャーでDC02に接続"
Write-Host "2. Windows Server 2022をインストール（Desktop Experienceを選択）"
Write-Host "3. DC01のIPアドレスを確認（DC01で: ipconfig）"
Write-Host "4. DC02で以下のスクリプトを実行（自動化）:"
Write-Host "   `$dc01Cred = Get-Credential -UserName `"$NetBIOSName\Administrator`" -Message `"DC01の管理者資格情報`""
Write-Host "   .\Setup-DC02DomainJoin.ps1 -Dc01IPAddress `<DC01のIP>` -Dc01AdminCredential `$dc01Cred"
Write-Host ""
Write-Host "   ※ または手動で:"
Write-Host "   Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools"
Write-Host "   Install-ADDSDomainController -DomainName `"$DomainName`" -Credential (Get-Credential) -Force"

Write-Host ""
Write-Host "============================================================"
Write-Host " VM作成完了"
Write-Host "============================================================"
Write-Host ""
Write-Host "【次のステップ】"
Write-Host "1. DC01でWindows Server 2022をインストール"
Write-Host "2. DC01でSetup-LabEnvironment.ps1を実行"
Write-Host "3. DC02でWindows Server 2022をインストール"
Write-Host "4. DC02でドメインコントローラーとして追加"
Write-Host ""
Write-Host "【レプリケーション確認】"
Write-Host "DC02追加後、以下のコマンドで確認:"
Write-Host "  repadmin /showrepl"
Write-Host "  dcdiag /test:replications"
