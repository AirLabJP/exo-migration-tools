<#
.SYNOPSIS
  Active Directory メール属性棚卸しスクリプト

.DESCRIPTION
  ADユーザー・グループのメール関連属性を収集し、EXO移行計画に必要な情報を取得します。

  【収集する情報】
  - ユーザーのmail, proxyAddresses, targetAddress等
  - グループのメール属性
  - Exchangeスキーマ拡張状態
  - Entra Connect同期状態

  【出力ファイルと確認ポイント】
  ad_users_mailattrs.csv  ← ★重要: ユーザーのメール属性一覧
  ad_groups_mailattrs.csv ← グループのメール属性一覧
  schema_version.txt      ← ★重要: Exchangeスキーマ拡張状態
  entra_connect_scp.txt   ← Entra Connect同期状態
  ad_forest.txt           ← フォレスト情報
  ad_domain.txt           ← ドメイン情報

.PARAMETER OutRoot
  出力先ルートフォルダ（デフォルト: .\inventory）

.PARAMETER Tag
  出力フォルダのサフィックス（デフォルト: 日時）

.PARAMETER PageSize
  AD検索のページサイズ（大規模環境向け、デフォルト: 1000）

.EXAMPLE
  .\Collect-ADInventory.ps1 -OutRoot C:\temp\inventory
#>
param(
  [string]$OutRoot = ".\inventory",
  [string]$Tag = (Get-Date -Format "yyyyMMdd_HHmmss"),
  [int]$PageSize = 1000
)

# 出力先フォルダ作成
$OutDir = Join-Path $OutRoot ("ad_" + $Tag)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Start-Transcript -Path (Join-Path $OutDir "run.log") -Force

Write-Host "============================================================"
Write-Host " Active Directory メール属性棚卸し"
Write-Host "============================================================"
Write-Host "出力先:      $OutDir"
Write-Host "ページサイズ: $PageSize"
Write-Host ""

Import-Module ActiveDirectory

#----------------------------------------------------------------------
# 1. ユーザーのメール属性取得
#----------------------------------------------------------------------
Write-Host "[1/5] ★ ADユーザーのメール属性を取得中..."
Write-Host "      → このファイルがEXO移行対象ユーザーの基礎資料になります"

$userProps = @(
  "SamAccountName","UserPrincipalName","Enabled",
  "mail","proxyAddresses","targetAddress",
  "msExchMailboxGuid","msExchRecipientTypeDetails","msExchRemoteRecipientType",
  "mailNickname","displayName","givenName","sn","department","company",
  "msDS-ConsistencyGuid"  # Entra Connect同期用GUID
)

$users = Get-ADUser -Filter * -Properties $userProps -ResultPageSize $PageSize
$users | Select-Object `
  SamAccountName,UserPrincipalName,Enabled,DisplayName,GivenName,Surname,Department,Company,
  mail,mailNickname,targetAddress,
  @{n="proxyAddresses";e={($_.proxyAddresses -join ";")}},
  msExchMailboxGuid,msExchRecipientTypeDetails,msExchRemoteRecipientType,
  @{n="msDSConsistencyGuid";e={
    if ($_.'msDS-ConsistencyGuid') {
      [System.Convert]::ToBase64String($_.'msDS-ConsistencyGuid')
    } else { $null }
  }} |
  Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "ad_users_mailattrs.csv")

Write-Host "      → ユーザー数: $($users.Count)"

# メール属性を持つユーザー数をカウント
$usersWithMail = ($users | Where-Object { $_.mail }).Count
$usersWithProxy = ($users | Where-Object { $_.proxyAddresses }).Count
Write-Host "      → mail属性あり: $usersWithMail"
Write-Host "      → proxyAddresses属性あり: $usersWithProxy"

#----------------------------------------------------------------------
# 2. グループのメール属性取得
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[2/5] ADグループのメール属性を取得中..."

$groupProps = @("GroupCategory","GroupScope","mail","proxyAddresses","msDS-ConsistencyGuid")

$groups = Get-ADGroup -Filter * -Properties $groupProps -ResultPageSize $PageSize
$groups | Select-Object Name,SamAccountName,GroupCategory,GroupScope,mail,
  @{n="proxyAddresses";e={($_.proxyAddresses -join ";")}},
  @{n="msDSConsistencyGuid";e={
    if ($_.'msDS-ConsistencyGuid') {
      [System.Convert]::ToBase64String($_.'msDS-ConsistencyGuid')
    } else { $null }
  }} |
  Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "ad_groups_mailattrs.csv")

Write-Host "      → グループ数: $($groups.Count)"
$groupsWithMail = ($groups | Where-Object { $_.mail }).Count
Write-Host "      → mail属性あり: $groupsWithMail"

#----------------------------------------------------------------------
# 3. フォレスト・ドメイン情報
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[3/5] フォレスト・ドメイン情報を取得中..."

(Get-ADForest) | Format-List * | Out-File (Join-Path $OutDir "ad_forest.txt") -Encoding UTF8
(Get-ADDomain) | Format-List * | Out-File (Join-Path $OutDir "ad_domain.txt") -Encoding UTF8

#----------------------------------------------------------------------
# 4. ★重要：Exchangeスキーマ拡張状態の確認
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[4/5] ★ Exchangeスキーマ拡張状態を確認中..."
Write-Host "      → スキーマ拡張が必要かどうかの判断材料になります"

try {
  $rootDSE = Get-ADRootDSE
  $schemaNC = $rootDSE.schemaNamingContext
  $configNC = $rootDSE.configurationNamingContext
  
  $schemaVersion = (Get-ADObject $schemaNC -Properties objectVersion).objectVersion
  $exchangeSchemaVersion = $null
  
  # Exchangeスキーマバージョン取得（拡張済みの場合のみ存在）
  try {
    $msExchSchema = Get-ADObject "CN=ms-Exch-Schema-Version-Pt,$schemaNC" -Properties rangeUpper -ErrorAction Stop
    $exchangeSchemaVersion = $msExchSchema.rangeUpper
  } catch {
    $exchangeSchemaVersion = "未拡張（Exchangeスキーマが見つかりません）"
  }
  
  # 結果をファイルに出力
  $schemaInfo = @"
#===============================================================================
# ADスキーマバージョン情報
#===============================================================================

【ADスキーマバージョン】
  $schemaVersion

【Exchangeスキーマバージョン】
  $exchangeSchemaVersion

【判断基準】
  - 「未拡張」の場合 → スキーマ拡張（PrepareSchema/PrepareAD）が必要
  - バージョン番号がある場合 → 既に拡張済み
    - Exchange 2016 CU23: 15334
    - Exchange 2019 CU14: 17003

【参照パス】
  Schema NC: $schemaNC
  Config NC: $configNC
"@
  
  $schemaInfo | Out-File (Join-Path $OutDir "schema_version.txt") -Encoding UTF8
  
  Write-Host "      → ADスキーマ: $schemaVersion"
  Write-Host "      → Exchangeスキーマ: $exchangeSchemaVersion"
} catch {
  Write-Warning "スキーマ情報の取得に失敗: $_"
}

#----------------------------------------------------------------------
# 5. Entra Connect同期状態の確認
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[5/5] Entra Connect同期状態を確認中..."

try {
  $aadcServer = Get-ADObject -Filter "objectClass -eq 'serviceConnectionPoint' -and name -eq 'Azure AD Connect'" `
    -SearchBase $configNC -Properties keywords -ErrorAction SilentlyContinue
  
  if ($aadcServer) {
    $aadcServer | Format-List * | Out-File (Join-Path $OutDir "entra_connect_scp.txt") -Encoding UTF8
    Write-Host "      → Entra Connect SCP を検出"
  } else {
    "Entra Connect SCPが見つかりません（未構成の可能性）" | Out-File (Join-Path $OutDir "entra_connect_scp.txt") -Encoding UTF8
    Write-Host "      → Entra Connect SCP が見つかりません"
  }
} catch {
  Write-Warning "Entra Connect状態の確認に失敗: $_"
}

#----------------------------------------------------------------------
# サマリー作成
#----------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================"
Write-Host " 完了"
Write-Host "============================================================"

$summary = @"
#===============================================================================
# AD棚卸しサマリー
#===============================================================================

【実行日時】$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

【ユーザー】
  総数:              $($users.Count)
  mail属性あり:      $usersWithMail
  proxyAddresses属性あり: $usersWithProxy

【グループ】
  総数:              $($groups.Count)
  mail属性あり:      $groupsWithMail

【確認すべきファイル】

  ★ ad_users_mailattrs.csv
     → ユーザーのメール属性一覧
     → EXO移行対象ユーザーの特定に使用

  ★ schema_version.txt
     → Exchangeスキーマ拡張状態
     → 「未拡張」ならPrepareSchema/PrepareADが必要

  ★ entra_connect_scp.txt
     → Entra Connect同期の構成状態
"@

$summary | Out-File (Join-Path $OutDir "summary.txt") -Encoding UTF8
Write-Host $summary

Stop-Transcript
Write-Host ""
Write-Host "出力先: $OutDir"
