<#
.SYNOPSIS
  Active Directory メール属性棚卸しスクリプト（強化版）

.DESCRIPTION
  ADユーザー・グループ・連絡先のメール関連属性を収集し、EXO移行計画に必要な情報を取得します。

  【収集する情報】
  - ユーザーのmail, proxyAddresses, targetAddress等
  - グループのメール属性
  - 連絡先（Contact）のメール属性
  - SMTP重複検出（user/group/contact横断）
  - Exchangeスキーマ拡張状態
  - Entra Connect同期状態
  - Forest/Domain機能レベル

  【出力ファイルと確認ポイント】
  ad_users_mailattrs.csv  ← ★重要: ユーザーのメール属性一覧（要約）
  ad_users_mailattrs.json ← 詳細データ（機械可読）
  ad_users_mailattrs.xml  ← 詳細データ（PowerShell互換）
  ad_groups_mailattrs.csv ← グループのメール属性一覧（要約）
  ad_groups_mailattrs.json← 詳細データ（機械可読）
  ad_groups_mailattrs.xml ← 詳細データ（PowerShell互換）
  ad_contacts_mailattrs.csv ← ★重要: 連絡先のメール属性一覧（要約）
  ad_contacts_mailattrs.json← 詳細データ（機械可読）
  ad_contacts_mailattrs.xml ← 詳細データ（PowerShell互換）
  smtp_duplicates.csv     ← ★重要: SMTP重複検出結果
  schema_version.txt      ← ★重要: Exchangeスキーマ拡張状態
  entra_connect_scp.txt   ← Entra Connect同期状態
  ad_forest.json          ← フォレスト情報
  ad_domain.json          ← ドメイン情報

.PARAMETER OutRoot
  出力先ルートフォルダ（デフォルト: .\inventory）

.PARAMETER Tag
  出力フォルダのサフィックス（デフォルト: 日時）

.PARAMETER PageSize
  AD検索のページサイズ（大規模環境向け、デフォルト: 1000）

.PARAMETER SearchBase
  検索ベースOU（指定しない場合はドメイン全体）
  例: "OU=Users,DC=contoso,DC=com"

.PARAMETER Server
  特定のDCを指定（指定しない場合は自動選択）

.PARAMETER IncludeDisabled
  無効なユーザー・グループも含める（デフォルト: 有効のみ）

.PARAMETER NoJson
  JSON/XML出力をスキップ（CSV/TXTのみ、大規模環境で高速化）

.EXAMPLE
  .\Collect-ADInventory.ps1 -OutRoot C:\temp\inventory

.EXAMPLE
  .\Collect-ADInventory.ps1 -SearchBase "OU=Tokyo,DC=contoso,DC=com" -Server DC01

.EXAMPLE
  .\Collect-ADInventory.ps1 -IncludeDisabled -NoJson
#>
param(
  [string]$OutRoot = ".\inventory",
  [string]$Tag = (Get-Date -Format "yyyyMMdd_HHmmss"),
  [int]$PageSize = 1000,
  [string]$SearchBase = $null,
  [string]$Server = $null,
  [switch]$IncludeDisabled,
  [switch]$NoJson
)

# エラーアクションの設定
$ErrorActionPreference = "Stop"

# 出力先フォルダ作成（UTF-8 with BOM）
$OutDir = Join-Path $OutRoot ("ad_" + $Tag)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# グローバル変数（finally句で参照）
$transcriptStarted = $false
$users = $null
$groups = $null
$contacts = $null
$usersWithMail = 0
$usersWithProxy = 0
$groupsWithMail = 0
$contactsWithMail = 0

try {
  # トランスクリプト開始
  Start-Transcript -Path (Join-Path $OutDir "run.log") -Force
  $transcriptStarted = $true

  Write-Host "============================================================"
  Write-Host " Active Directory メール属性棚卸し（強化版）"
  Write-Host "============================================================"
  Write-Host "出力先:         $OutDir"
  Write-Host "ページサイズ:   $PageSize"
  if ($SearchBase) { Write-Host "検索ベース:     $SearchBase" }
  if ($Server) { Write-Host "ドメインコントローラー: $Server" }
  if ($IncludeDisabled) { Write-Host "無効オブジェクト: 含める" }
  if ($NoJson) { Write-Host "JSON出力:       スキップ" }
  Write-Host ""

  Import-Module ActiveDirectory

  # Get-ADUser/Group/Contact共通パラメータ構築
  $adParams = @{
    ResultPageSize = $PageSize
  }
  if ($SearchBase) { $adParams['SearchBase'] = $SearchBase }
  if ($Server) { $adParams['Server'] = $Server }

  #----------------------------------------------------------------------
  # 1. ★重要：ユーザーのメール属性取得
  #----------------------------------------------------------------------
  Write-Host "[1/7] ★ ADユーザーのメール属性を取得中..."
  Write-Host "      → このファイルがEXO移行対象ユーザーの基礎資料になります"

  $userProps = @(
    "SamAccountName","UserPrincipalName","Enabled",
    "objectGUID",  # GUID文字列化
    "mail","proxyAddresses","targetAddress",
    "msExchMailboxGuid","msExchRecipientTypeDetails","msExchRemoteRecipientType",
    "mailNickname","displayName","givenName","sn","department","company",
    "msDS-ConsistencyGuid"  # GUID文字列化（Entra Connect sourceAnchor）
  )

  # フィルタ構築（有効/無効）
  $userFilter = if ($IncludeDisabled) { "*" } else { "Enabled -eq `$true" }

  try {
    $users = Get-ADUser -Filter $userFilter -Properties $userProps @adParams -ErrorAction Stop
  } catch {
    Write-Warning "ユーザー取得でエラー: $_"
    $users = @()
  }

  # 要約CSV出力（人が読む用）
  $usersSummary = $users | ForEach-Object {
    # objectGUID を文字列化
    $objectGuidStr = if ($_.objectGUID) { $_.objectGUID.ToString() } else { $null }

    # msDS-ConsistencyGuid を GUID文字列化（バイナリ→GUID）
    $msDSConsistencyGuidStr = $null
    if ($_.'msDS-ConsistencyGuid') {
      try {
        # バイナリ→GUID変換
        $guid = New-Object Guid (,$_.'msDS-ConsistencyGuid')
        $msDSConsistencyGuidStr = $guid.ToString()
      } catch {
        $msDSConsistencyGuidStr = "変換エラー"
      }
    }

    [PSCustomObject]@{
      SamAccountName = $_.SamAccountName
      UserPrincipalName = $_.UserPrincipalName
      Enabled = $_.Enabled
      DisplayName = $_.DisplayName
      GivenName = $_.GivenName
      Surname = $_.Surname
      Department = $_.Department
      Company = $_.Company
      objectGUID = $objectGuidStr
      mail = $_.mail
      mailNickname = $_.mailNickname
      targetAddress = $_.targetAddress
      proxyAddresses = ($_.proxyAddresses -join ";")
      msExchMailboxGuid = $_.msExchMailboxGuid
      msExchRecipientTypeDetails = $_.msExchRecipientTypeDetails
      msExchRemoteRecipientType = $_.msExchRemoteRecipientType
      "msDS-ConsistencyGuid" = $msDSConsistencyGuidStr
    }
  }

  $usersSummary | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "ad_users_mailattrs.csv")

  # 詳細データ出力（機械可読）
  if (-not $NoJson) {
    # 注意：秘匿情報（パスワードハッシュ等）は取得していませんが、
    # 将来的に属性を追加する場合は unicodePwd, userPassword 等を除外してください
    $users | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "ad_users_mailattrs.json") -Encoding UTF8
    $users | Export-Clixml -Path (Join-Path $OutDir "ad_users_mailattrs.xml") -Encoding UTF8
  }

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
  Write-Host "[2/7] ADグループのメール属性を取得中..."

  $groupProps = @(
    "GroupCategory","GroupScope","Enabled",
    "objectGUID","mail","proxyAddresses","msDS-ConsistencyGuid"
  )

  # グループフィルタ
  $groupFilter = if ($IncludeDisabled) { "*" } else { "Enabled -eq `$true" }

  try {
    $groups = Get-ADGroup -Filter $groupFilter -Properties $groupProps @adParams -ErrorAction Stop
  } catch {
    Write-Warning "グループ取得でエラー: $_"
    $groups = @()
  }

  # 要約CSV出力
  $groupsSummary = $groups | ForEach-Object {
    $objectGuidStr = if ($_.objectGUID) { $_.objectGUID.ToString() } else { $null }

    $msDSConsistencyGuidStr = $null
    if ($_.'msDS-ConsistencyGuid') {
      try {
        $guid = New-Object Guid (,$_.'msDS-ConsistencyGuid')
        $msDSConsistencyGuidStr = $guid.ToString()
      } catch {
        $msDSConsistencyGuidStr = "変換エラー"
      }
    }

    [PSCustomObject]@{
      Name = $_.Name
      SamAccountName = $_.SamAccountName
      GroupCategory = $_.GroupCategory
      GroupScope = $_.GroupScope
      Enabled = $_.Enabled
      objectGUID = $objectGuidStr
      mail = $_.mail
      proxyAddresses = ($_.proxyAddresses -join ";")
      "msDS-ConsistencyGuid" = $msDSConsistencyGuidStr
    }
  }

  $groupsSummary | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "ad_groups_mailattrs.csv")

  # 詳細データ出力
  if (-not $NoJson) {
    $groups | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "ad_groups_mailattrs.json") -Encoding UTF8
    $groups | Export-Clixml -Path (Join-Path $OutDir "ad_groups_mailattrs.xml") -Encoding UTF8
  }

  Write-Host "      → グループ数: $($groups.Count)"
  $groupsWithMail = ($groups | Where-Object { $_.mail }).Count
  Write-Host "      → mail属性あり: $groupsWithMail"

  #----------------------------------------------------------------------
  # 3. ★重要：連絡先（Contact）のメール属性取得
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[3/7] ★ AD連絡先（Contact）のメール属性を取得中..."

  $contactProps = @(
    "objectGUID","mail","proxyAddresses","targetAddress",
    "displayName","msDS-ConsistencyGuid"
  )

  try {
    $contacts = Get-ADObject -Filter "objectClass -eq 'contact'" -Properties $contactProps @adParams -ErrorAction Stop
  } catch {
    Write-Warning "連絡先取得でエラー: $_"
    $contacts = @()
  }

  # 要約CSV出力
  $contactsSummary = $contacts | ForEach-Object {
    $objectGuidStr = if ($_.objectGUID) { $_.objectGUID.ToString() } else { $null }

    $msDSConsistencyGuidStr = $null
    if ($_.'msDS-ConsistencyGuid') {
      try {
        $guid = New-Object Guid (,$_.'msDS-ConsistencyGuid')
        $msDSConsistencyGuidStr = $guid.ToString()
      } catch {
        $msDSConsistencyGuidStr = "変換エラー"
      }
    }

    [PSCustomObject]@{
      Name = $_.Name
      DisplayName = $_.DisplayName
      objectGUID = $objectGuidStr
      mail = $_.mail
      targetAddress = $_.targetAddress
      proxyAddresses = ($_.proxyAddresses -join ";")
      "msDS-ConsistencyGuid" = $msDSConsistencyGuidStr
    }
  }

  $contactsSummary | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "ad_contacts_mailattrs.csv")

  # 詳細データ出力
  if (-not $NoJson) {
    $contacts | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "ad_contacts_mailattrs.json") -Encoding UTF8
    $contacts | Export-Clixml -Path (Join-Path $OutDir "ad_contacts_mailattrs.xml") -Encoding UTF8
  }

  Write-Host "      → 連絡先数: $($contacts.Count)"
  $contactsWithMail = ($contacts | Where-Object { $_.mail }).Count
  Write-Host "      → mail属性あり: $contactsWithMail"

  #----------------------------------------------------------------------
  # 4. ★重要：SMTP重複検出（user/group/contact横断）
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[4/7] ★ SMTP重複検出を実行中（user/group/contact横断）..."

  # 全オブジェクトからmail/proxyAddressesを抽出
  $allSmtpAddresses = @()

  # ユーザーから抽出
  foreach ($user in $users) {
    if ($user.mail) {
      $allSmtpAddresses += [PSCustomObject]@{
        Address = $user.mail.ToLower()
        Type = "User"
        Name = $user.SamAccountName
        Source = "mail"
      }
    }
    if ($user.proxyAddresses) {
      foreach ($proxy in $user.proxyAddresses) {
        if ($proxy -match '^smtp:(.+)$') {
          $allSmtpAddresses += [PSCustomObject]@{
            Address = $Matches[1].ToLower()
            Type = "User"
            Name = $user.SamAccountName
            Source = "proxyAddresses"
          }
        }
      }
    }
  }

  # グループから抽出
  foreach ($group in $groups) {
    if ($group.mail) {
      $allSmtpAddresses += [PSCustomObject]@{
        Address = $group.mail.ToLower()
        Type = "Group"
        Name = $group.Name
        Source = "mail"
      }
    }
    if ($group.proxyAddresses) {
      foreach ($proxy in $group.proxyAddresses) {
        if ($proxy -match '^smtp:(.+)$') {
          $allSmtpAddresses += [PSCustomObject]@{
            Address = $Matches[1].ToLower()
            Type = "Group"
            Name = $group.Name
            Source = "proxyAddresses"
          }
        }
      }
    }
  }

  # 連絡先から抽出
  foreach ($contact in $contacts) {
    if ($contact.mail) {
      $allSmtpAddresses += [PSCustomObject]@{
        Address = $contact.mail.ToLower()
        Type = "Contact"
        Name = $contact.Name
        Source = "mail"
      }
    }
    if ($contact.proxyAddresses) {
      foreach ($proxy in $contact.proxyAddresses) {
        if ($proxy -match '^smtp:(.+)$') {
          $allSmtpAddresses += [PSCustomObject]@{
            Address = $Matches[1].ToLower()
            Type = "Contact"
            Name = $contact.Name
            Source = "proxyAddresses"
          }
        }
      }
    }
  }

  # 重複を検出
  $duplicates = $allSmtpAddresses | Group-Object -Property Address | Where-Object { $_.Count -gt 1 }

  # 重複CSVを出力
  $duplicateRecords = @()
  foreach ($dup in $duplicates) {
    $address = $dup.Name
    $occurrences = $dup.Group | ForEach-Object { "$($_.Type):$($_.Name)" }
    $duplicateRecords += [PSCustomObject]@{
      SMTPAddress = $address
      OccurrenceCount = $dup.Count
      Occurrences = ($occurrences -join "; ")
    }
  }

  if ($duplicateRecords.Count -gt 0) {
    $duplicateRecords | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "smtp_duplicates.csv")
    Write-Host "      → ★警告: 重複SMTP検出数: $($duplicateRecords.Count)" -ForegroundColor Yellow
    Write-Host "      → smtp_duplicates.csv を確認してください" -ForegroundColor Yellow
  } else {
    "# 重複なし" | Out-File (Join-Path $OutDir "smtp_duplicates.csv") -Encoding UTF8
    Write-Host "      → 重複SMTP: なし"
  }

  #----------------------------------------------------------------------
  # 5. フォレスト・ドメイン情報（機能レベル追加）
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[5/7] フォレスト・ドメイン情報を取得中（機能レベル含む）..."

  $forest = Get-ADForest
  $domain = Get-ADDomain

  # テキスト形式（互換性のため維持）
  $forest | Format-List * | Out-File (Join-Path $OutDir "ad_forest.txt") -Encoding UTF8
  $domain | Format-List * | Out-File (Join-Path $OutDir "ad_domain.txt") -Encoding UTF8

  # JSON形式（機械可読）
  if (-not $NoJson) {
    $forest | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "ad_forest.json") -Encoding UTF8
    $domain | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "ad_domain.json") -Encoding UTF8
  }

  Write-Host "      → Forest機能レベル: $($forest.ForestMode)"
  Write-Host "      → Domain機能レベル: $($domain.DomainMode)"

  #----------------------------------------------------------------------
  # 6. ★重要：Exchangeスキーマ拡張状態の確認
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[6/7] ★ Exchangeスキーマ拡張状態を確認中..."
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
  # 7. Entra Connect同期状態の確認
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[7/7] Entra Connect同期状態を確認中..."

  try {
    $aadcServer = Get-ADObject -Filter "objectClass -eq 'serviceConnectionPoint' -and name -eq 'Azure AD Connect'" `
      -SearchBase $configNC -Properties keywords -ErrorAction SilentlyContinue

    if ($aadcServer) {
      $aadcServer | Format-List * | Out-File (Join-Path $OutDir "entra_connect_scp.txt") -Encoding UTF8
      if (-not $NoJson) {
        $aadcServer | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "entra_connect_scp.json") -Encoding UTF8
      }
      Write-Host "      → Entra Connect SCP を検出"
    } else {
      "Entra Connect SCPが見つかりません（未構成の可能性）" | Out-File (Join-Path $OutDir "entra_connect_scp.txt") -Encoding UTF8
      Write-Host "      → Entra Connect SCP が見つかりません"
    }
  } catch {
    Write-Warning "Entra Connect状態の確認に失敗: $_"
  }

  #----------------------------------------------------------------------
  # サマリー作成（targetAddress/proxy集計追加）
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "============================================================"
  Write-Host " 完了"
  Write-Host "============================================================"

  # targetAddress/proxyAddresses集計
  $usersWithTargetAddress = ($users | Where-Object { $_.targetAddress }).Count
  $allProxyCount = ($users | Where-Object { $_.proxyAddresses } | ForEach-Object { $_.proxyAddresses.Count } | Measure-Object -Sum).Sum

  $summary = @"
#===============================================================================
# AD棚卸しサマリー（強化版）
#===============================================================================

【実行日時】$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

【フォレスト・ドメイン】
  Forest機能レベル:       $($forest.ForestMode)
  Domain機能レベル:       $($domain.DomainMode)
  Forest名:               $($forest.Name)
  Domain名:               $($domain.DNSRoot)

【ユーザー】
  総数:                   $($users.Count)
  mail属性あり:           $usersWithMail
  proxyAddresses属性あり: $usersWithProxy
  targetAddress属性あり:  $usersWithTargetAddress
  proxyAddresses総数:     $allProxyCount

【グループ】
  総数:                   $($groups.Count)
  mail属性あり:           $groupsWithMail

【連絡先】
  総数:                   $($contacts.Count)
  mail属性あり:           $contactsWithMail

【SMTP重複検出】
  重複SMTP数:             $($duplicateRecords.Count)
  $(if ($duplicateRecords.Count -gt 0) { "  → smtp_duplicates.csv を確認してください" } else { "  → 重複なし" })

【出力形式】
  要約CSV: ad_users_mailattrs.csv, ad_groups_mailattrs.csv, ad_contacts_mailattrs.csv
  $(if (-not $NoJson) { "詳細JSON: ad_users_mailattrs.json, ad_groups_mailattrs.json, ad_contacts_mailattrs.json" } else { "JSON出力: スキップ" })
  $(if (-not $NoJson) { "詳細XML: ad_users_mailattrs.xml, ad_groups_mailattrs.xml, ad_contacts_mailattrs.xml" } else { "XML出力: スキップ" })

【確認すべきファイル】

  ★ ad_users_mailattrs.csv
     → ユーザーのメール属性一覧（要約・人が読む用）
     → EXO移行対象ユーザーの特定に使用
     → objectGUID, msDS-ConsistencyGuid は GUID文字列形式

  ★ ad_contacts_mailattrs.csv
     → 連絡先のメール属性一覧
     → targetAddress の確認に使用

  ★ smtp_duplicates.csv
     → SMTP重複検出結果（user/group/contact横断）
     → 重複がある場合は要対処

  ★ schema_version.txt
     → Exchangeスキーマ拡張状態
     → 「未拡張」ならPrepareSchema/PrepareADが必要

  ★ entra_connect_scp.txt
     → Entra Connect同期の構成状態
"@

  $summary | Out-File (Join-Path $OutDir "summary.txt") -Encoding UTF8
  Write-Host $summary

} catch {
  # エラー時の処理
  Write-Host ""
  Write-Host "============================================================" -ForegroundColor Red
  Write-Host " エラーが発生しました" -ForegroundColor Red
  Write-Host "============================================================" -ForegroundColor Red
  Write-Host $_.Exception.Message -ForegroundColor Red
  Write-Host $_.ScriptStackTrace -ForegroundColor Red

  # エラー情報をファイルに保存
  $errorInfo = @"
エラー発生時刻: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
エラーメッセージ: $($_.Exception.Message)
スタックトレース:
$($_.ScriptStackTrace)
"@
  $errorInfo | Out-File (Join-Path $OutDir "error.log") -Encoding UTF8

  # エラーを再スロー（スクリプトを終了コード1で終了させる）
  throw
} finally {
  # 必ず実行される後片付け
  if ($transcriptStarted) {
    try {
      Stop-Transcript
    } catch {
      # トランスクリプト停止でエラーが出ても無視
    }
  }

  Write-Host ""
  Write-Host "出力先: $OutDir"
}
