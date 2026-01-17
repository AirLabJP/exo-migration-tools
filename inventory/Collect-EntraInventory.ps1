<#
.SYNOPSIS
  Entra ID（Azure AD）棚卸しスクリプト

.DESCRIPTION
  Entra IDのユーザー・ライセンス情報を収集し、EXO移行計画に必要な情報を取得します。

  【収集する情報】
  - テナント情報
  - ライセンスSKU一覧と消費状況
  - ユーザー×ライセンス割当状況
  - オンプレ同期状態（DirSync）

  【出力ファイルと確認ポイント】
  org.json              ← テナント基本情報
  subscribed_skus.csv   ← ★重要: ライセンス一覧（Exchange含むSKUを確認）
  users_license.csv     ← ★重要: ユーザー×ライセンス対応表
  summary.txt           ← 同期ユーザー数等のサマリー

.PARAMETER OutRoot
  出力先ルートフォルダ

.PARAMETER Tag
  出力フォルダのサフィックス（省略時は日時）

.EXAMPLE
  .\Collect-EntraInventory.ps1 -OutRoot C:\temp\inventory

.NOTES
  必要モジュール: Microsoft.Graph
  必要権限: User.Read.All, Directory.Read.All, Organization.Read.All
#>
param(
  [string]$OutRoot = ".\inventory",
  [string]$Tag = (Get-Date -Format "yyyyMMdd_HHmmss")
)

# 出力先フォルダ作成
$OutDir = Join-Path $OutRoot ("entra_" + $Tag)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Start-Transcript -Path (Join-Path $OutDir "run.log") -Force

Write-Host "============================================================"
Write-Host " Entra ID（Azure AD）棚卸し"
Write-Host "============================================================"
Write-Host "出力先: $OutDir"
Write-Host ""

Import-Module Microsoft.Graph.Users
Import-Module Microsoft.Graph.Identity.DirectoryManagement

#----------------------------------------------------------------------
# 1. Microsoft Graphへ接続
#----------------------------------------------------------------------
Write-Host "[1/4] Microsoft Graphに接続中..."
Write-Host "      → ブラウザで認証画面が開きます"
Connect-MgGraph -Scopes "User.Read.All","Directory.Read.All","Organization.Read.All" -NoWelcome

#----------------------------------------------------------------------
# 2. テナント情報の取得
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[2/4] テナント情報を取得中..."

$org = Get-MgOrganization
$org | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "org.json") -Encoding UTF8
Write-Host "      → テナント名: $($org.DisplayName)"

#----------------------------------------------------------------------
# 3. ★重要：ライセンスSKU一覧の取得
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[3/4] ★ ライセンスSKU一覧を取得中..."
Write-Host "      → Exchange Online を含むSKUがあるか確認してください"

$skus = Get-MgSubscribedSku
$skus | Select-Object SkuPartNumber,SkuId,
  @{n="消費数";e={$_.ConsumedUnits}},
  @{n="有効数";e={$_.PrepaidUnits.Enabled}},
  @{n="停止数";e={$_.PrepaidUnits.Suspended}},
  @{n="警告数";e={$_.PrepaidUnits.Warning}} |
  Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "subscribed_skus.csv")

Write-Host "      → SKU数: $($skus.Count)"

# Exchange関連SKUを表示
$exchangeSkus = $skus | Where-Object { $_.SkuPartNumber -match 'EXCHANGE|E3|E5|BUSINESS' }
if ($exchangeSkus) {
  Write-Host ""
  Write-Host "      【Exchange関連SKU】"
  foreach ($sku in $exchangeSkus) {
    Write-Host "        - $($sku.SkuPartNumber): 消費 $($sku.ConsumedUnits) / 有効 $($sku.PrepaidUnits.Enabled)"
  }
}

# SKU名→IDの変換テーブル作成
$skuLookup = @{}
foreach ($sku in $skus) {
  $skuLookup[$sku.SkuId] = $sku.SkuPartNumber
}

#----------------------------------------------------------------------
# 4. ★重要：ユーザー×ライセンス一覧の取得
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[4/4] ★ ユーザー×ライセンス一覧を取得中..."
Write-Host "      → 大規模テナントでは時間がかかる場合があります"

$userProps = @(
  "id","displayName","userPrincipalName","mail",
  "accountEnabled","onPremisesSyncEnabled","assignedLicenses",
  "proxyAddresses","userType","createdDateTime"
)

$users = Get-MgUser -All -Property ($userProps -join ",") -ConsistencyLevel eventual -CountVariable count

$users | ForEach-Object {
  $skuNames = @()
  if ($_.AssignedLicenses) {
    $skuNames = $_.AssignedLicenses | ForEach-Object {
      if ($skuLookup.ContainsKey($_.SkuId)) { $skuLookup[$_.SkuId] }
      else { $_.SkuId }
    }
  }
  
  [PSCustomObject]@{
    表示名 = $_.DisplayName
    UPN = $_.UserPrincipalName
    メール = $_.Mail
    有効 = $_.AccountEnabled
    オンプレ同期 = $_.OnPremisesSyncEnabled
    ユーザー種別 = $_.UserType
    作成日時 = $_.CreatedDateTime
    割当SKU = ($skuNames -join ";")
    SKU数 = $_.AssignedLicenses.Count
    proxyAddresses = ($_.ProxyAddresses -join ";")
  }
} | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "users_license.csv")

Write-Host "      → ユーザー数: $($users.Count)"

#----------------------------------------------------------------------
# サマリー作成
#----------------------------------------------------------------------
$syncedUsers = ($users | Where-Object { $_.OnPremisesSyncEnabled -eq $true }).Count
$cloudOnlyUsers = ($users | Where-Object { $_.OnPremisesSyncEnabled -ne $true }).Count
$licensedUsers = ($users | Where-Object { $_.AssignedLicenses.Count -gt 0 }).Count

$summary = @"
#===============================================================================
# Entra ID 棚卸しサマリー
#===============================================================================

【テナント】
  名前: $($org.DisplayName)

【ユーザー統計】
  総数:                 $($users.Count)
  オンプレ同期:         $syncedUsers
  クラウドのみ:         $cloudOnlyUsers
  ライセンス割当あり:   $licensedUsers

【ライセンスSKU】
$($skus | ForEach-Object { "  $($_.SkuPartNumber): 消費 $($_.ConsumedUnits) / 有効 $($_.PrepaidUnits.Enabled)" } | Out-String)

【確認すべきファイル】

  ★ subscribed_skus.csv
     → ライセンス一覧
     → Exchange Online を含むSKUを確認

  ★ users_license.csv
     → ユーザー×ライセンス対応表
     → 「オンプレ同期」列でAD連携状態を確認

【判断ポイント】

  1. オンプレ同期ユーザーが $syncedUsers 人
     → これらはADからEntra Connectで同期されている
     → EXO移行時はAD側でmail属性を設定する必要あり

  2. クラウドのみユーザーが $cloudOnlyUsers 人
     → ADとは無関係にEntraで作成されたユーザー
     → 必要に応じてADに作成して同期させる検討

"@

$summary | Out-File (Join-Path $OutDir "summary.txt") -Encoding UTF8

Write-Host ""
Write-Host "============================================================"
Write-Host " 完了"
Write-Host "============================================================"
Write-Host $summary

Disconnect-MgGraph
Stop-Transcript
Write-Host ""
Write-Host "出力先: $OutDir"
