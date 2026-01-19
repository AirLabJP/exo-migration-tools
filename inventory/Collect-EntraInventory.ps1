<#
.SYNOPSIS
  Entra ID（Azure AD）棚卸しスクリプト（強化版）

.DESCRIPTION
  Entra IDのユーザー・ライセンス情報を収集し、EXO移行計画に必要な情報を取得します。

  【収集する情報】
  - テナント情報（DirSync有効状態含む）
  - ドメイン一覧
  - ライセンスSKU一覧と消費状況
  - ユーザー×ライセンス割当状況
  - Exchange Online有効状態（assignedPlansベース）
  - ライセンス問題ユーザー一覧
  - ライセンス割当グループ概要

  【出力ファイルと確認ポイント】
  org.json                     ← テナント基本情報（DirSync状態含む）
  domains.csv                  ← ★重要: ドメイン一覧
  domains.json                 ← 詳細データ（機械可読）
  subscribed_skus.csv          ← ★重要: ライセンス一覧（要約・人が読む用）
  subscribed_skus.json         ← 詳細データ（機械可読）
  subscribed_skus.xml          ← 詳細データ（PowerShell互換）
  users_license.csv            ← ★重要: ユーザー×ライセンス対応表（要約）
  users_license.json           ← 詳細データ（機械可読）
  users_license.xml            ← 詳細データ（PowerShell互換）
  users_licence_issues.csv     ← ★重要: ライセンス問題ユーザー
  license_groups.csv           ← ★重要: ライセンス割当グループ
  summary.txt                  ← 同期ユーザー数等のサマリー

.PARAMETER OutRoot
  出力先ルートフォルダ

.PARAMETER Tag
  出力フォルダのサフィックス（省略時は日時）

.PARAMETER StreamToCsv
  大規模環境向け：ユーザーを逐次CSVに書き出し（メモリ節約）

.EXAMPLE
  .\Collect-EntraInventory.ps1 -OutRoot C:\temp\inventory

.EXAMPLE
  .\Collect-EntraInventory.ps1 -StreamToCsv

.NOTES
  必要モジュール: Microsoft.Graph (v1.0 API使用)
  必要権限: User.Read.All, Directory.Read.All, Organization.Read.All, Domain.Read.All, Group.Read.All
#>
param(
  [string]$OutRoot = ".\inventory",
  [string]$Tag = (Get-Date -Format "yyyyMMdd_HHmmss"),
  [switch]$StreamToCsv
)

# エラーアクションの設定
$ErrorActionPreference = "Stop"

# 出力先フォルダ作成
$OutDir = Join-Path $OutRoot ("entra_" + $Tag)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# グローバル変数（finally句で参照）
$transcriptStarted = $false
$mgConnected = $false
$dirSyncEnabled = $false
$users = $null
$domains = $null

try {
  # トランスクリプト開始
  Start-Transcript -Path (Join-Path $OutDir "run.log") -Force
  $transcriptStarted = $true

  Write-Host "============================================================"
  Write-Host " Entra ID（Azure AD）棚卸し（強化版）"
  Write-Host "============================================================"
  Write-Host "出力先: $OutDir"
  if ($StreamToCsv) { Write-Host "モード: 逐次CSV出力（大規模環境向け）" }
  Write-Host ""

  #----------------------------------------------------------------------
  # 1. Microsoft.Graphモジュール確認（Fail Fast）
  #----------------------------------------------------------------------
  Write-Host "[1/8] Microsoft.Graphモジュールを確認中..."

  # 必要なモジュールの確認
  $requiredModules = @(
    "Microsoft.Graph.Users",
    "Microsoft.Graph.Identity.DirectoryManagement",
    "Microsoft.Graph.Groups"
  )

  foreach ($moduleName in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $moduleName)) {
      throw "必要なモジュール '$moduleName' がインストールされていません。`nInstall-Module Microsoft.Graph を実行してください。"
    }
  }

  Import-Module Microsoft.Graph.Users -ErrorAction Stop
  Import-Module Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop
  Import-Module Microsoft.Graph.Groups -ErrorAction Stop

  Write-Host "      → Microsoft.Graphモジュールを確認しました"

  # Graph APIバージョンをv1.0に設定（Beta APIは避ける）
  try {
    # Select-MgProfile は Microsoft.Graph v1.x で使用（v2.x では不要）
    if (Get-Command Select-MgProfile -ErrorAction SilentlyContinue) {
      Select-MgProfile -Name "v1.0"
      Write-Host "      → Graph API v1.0 を選択しました"
    }
  } catch {
    Write-Warning "Select-MgProfile は利用できません（Microsoft.Graph v2.x の可能性）"
  }

  #----------------------------------------------------------------------
  # 2. Microsoft Graphへ接続
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[2/8] Microsoft Graphに接続中..."
  Write-Host "      → ブラウザで認証画面が開きます"

  $scopes = @(
    "User.Read.All",
    "Directory.Read.All",
    "Organization.Read.All",
    "Domain.Read.All",
    "Group.Read.All"
  )

  Connect-MgGraph -Scopes $scopes -NoWelcome
  $mgConnected = $true

  #----------------------------------------------------------------------
  # 3. テナント情報の取得（DirSyncフラグ含む）
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[3/8] テナント情報を取得中（DirSync状態含む）..."

  $org = Get-MgOrganization

  # DirSync有効状態を取得
  $dirSyncEnabled = $org.OnPremisesSyncEnabled
  Write-Host "      → テナント名: $($org.DisplayName)"
  Write-Host "      → DirSync有効: $dirSyncEnabled"

  # 拡張情報を付与してJSON出力
  $orgExtended = [PSCustomObject]@{
    Id = $org.Id
    DisplayName = $org.DisplayName
    TenantType = $org.TenantType
    OnPremisesSyncEnabled = $org.OnPremisesSyncEnabled
    OnPremisesLastSyncDateTime = $org.OnPremisesLastSyncDateTime
    VerifiedDomains = $org.VerifiedDomains
    AssignedPlans = $org.AssignedPlans
    CreatedDateTime = $org.CreatedDateTime
    CollectionTime = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
  }
  $orgExtended | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "org.json") -Encoding UTF8

  #----------------------------------------------------------------------
  # 4. ★重要：ドメイン一覧の取得
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[4/8] ★ ドメイン一覧を取得中..."

  try {
    $domains = Get-MgDomain -All

    # 要約CSV出力
    $domainsSummary = $domains | ForEach-Object {
      [PSCustomObject]@{
        ドメイン = $_.Id
        認証タイプ = $_.AuthenticationType
        デフォルト = $_.IsDefault
        初期 = $_.IsInitial
        検証済み = $_.IsVerified
        ルート = $_.IsRoot
        管理者管理 = $_.IsAdminManaged
        サポート対象サービス = ($_.SupportedServices -join ";")
      }
    }
    $domainsSummary | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "domains.csv")
    $domains | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "domains.json") -Encoding UTF8

    Write-Host "      → ドメイン数: $($domains.Count)"
    Write-Host "      → デフォルト: $(($domains | Where-Object { $_.IsDefault }).Id)"
  } catch {
    Write-Warning "ドメイン一覧の取得に失敗: $_"
  }

  #----------------------------------------------------------------------
  # 5. ★重要：ライセンスSKU一覧の取得
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[5/8] ★ ライセンスSKU一覧を取得中..."
  Write-Host "      → Exchange Online を含むSKUがあるか確認してください"

  $skus = Get-MgSubscribedSku

  # 要約CSV出力（人が読む用）
  $skus | Select-Object SkuPartNumber,SkuId,
    @{n="消費数";e={$_.ConsumedUnits}},
    @{n="有効数";e={$_.PrepaidUnits.Enabled}},
    @{n="停止数";e={$_.PrepaidUnits.Suspended}},
    @{n="警告数";e={$_.PrepaidUnits.Warning}} |
    Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "subscribed_skus.csv")

  # 詳細データ出力（機械可読）
  $skus | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "subscribed_skus.json") -Encoding UTF8
  $skus | Export-Clixml -Path (Join-Path $OutDir "subscribed_skus.xml") -Encoding UTF8

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
  # 6. ★重要：ユーザー×ライセンス一覧の取得（Exchange Enabled判定含む）
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[6/8] ★ ユーザー×ライセンス一覧を取得中..."
  Write-Host "      → 大規模テナントでは時間がかかる場合があります"

  $userProps = @(
    "id","displayName","userPrincipalName","mail",
    "accountEnabled","onPremisesSyncEnabled","assignedLicenses",
    "assignedPlans",  # Exchange Enabled判定用
    "proxyAddresses","userType","createdDateTime",
    "licenseAssignmentStates"  # グループ経由のライセンス割当確認用
  )

  $users = Get-MgUser -All -Property ($userProps -join ",") -ConsistencyLevel eventual -CountVariable count

  # ライセンス問題ユーザーを収集
  $licenseIssues = New-Object System.Collections.Generic.List[object]

  # 逐次CSV出力モード
  if ($StreamToCsv) {
    Write-Host "      → 逐次CSV出力モードで処理中..."
    $csvPath = Join-Path $OutDir "users_license.csv"

    # ヘッダー行を先に書き込み
    $headerWritten = $false

    foreach ($user in $users) {
      # Exchange Online有効状態をassignedPlansから判定
      $hasExoEnabled = $false
      if ($user.AssignedPlans) {
        $exoPlans = $user.AssignedPlans | Where-Object {
          $_.ServicePlanId -and
          $_.CapabilityStatus -eq "Enabled" -and
          ($_.Service -eq "exchange" -or $_.Service -match "Exchange")
        }
        if ($exoPlans) { $hasExoEnabled = $true }
      }

      # SKU名を取得
      $skuNames = @()
      if ($user.AssignedLicenses) {
        $skuNames = $user.AssignedLicenses | ForEach-Object {
          if ($skuLookup.ContainsKey($_.SkuId)) { $skuLookup[$_.SkuId] }
          else { $_.SkuId }
        }
      }

      # ライセンス割当方法（直接 or グループ経由）
      $licenseAssignmentMethod = "なし"
      if ($user.LicenseAssignmentStates) {
        $directAssign = $user.LicenseAssignmentStates | Where-Object { $_.AssignedByGroup -eq $null }
        $groupAssign = $user.LicenseAssignmentStates | Where-Object { $_.AssignedByGroup -ne $null }
        if ($directAssign -and $groupAssign) { $licenseAssignmentMethod = "直接+グループ" }
        elseif ($directAssign) { $licenseAssignmentMethod = "直接" }
        elseif ($groupAssign) { $licenseAssignmentMethod = "グループ" }
      }

      $record = [PSCustomObject]@{
        表示名 = $user.DisplayName
        UPN = $user.UserPrincipalName
        メール = $user.Mail
        有効 = $user.AccountEnabled
        オンプレ同期 = $user.OnPremisesSyncEnabled
        ユーザー種別 = $user.UserType
        作成日時 = $user.CreatedDateTime
        割当SKU = ($skuNames -join ";")
        SKU数 = $user.AssignedLicenses.Count
        HasExoEnabled = $hasExoEnabled
        ライセンス割当方法 = $licenseAssignmentMethod
        proxyAddresses = ($user.ProxyAddresses -join ";")
      }

      if (-not $headerWritten) {
        $record | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $csvPath
        $headerWritten = $true
      } else {
        $record | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $csvPath -Append
      }

      # ライセンス問題チェック
      if ($user.AccountEnabled -and $user.AssignedLicenses.Count -eq 0) {
        $licenseIssues.Add([PSCustomObject]@{
          UPN = $user.UserPrincipalName
          表示名 = $user.DisplayName
          有効 = $user.AccountEnabled
          オンプレ同期 = $user.OnPremisesSyncEnabled
          問題 = "有効ユーザーにライセンスなし"
        })
      }
      if ($user.AssignedLicenses.Count -gt 0 -and -not $hasExoEnabled) {
        $licenseIssues.Add([PSCustomObject]@{
          UPN = $user.UserPrincipalName
          表示名 = $user.DisplayName
          有効 = $user.AccountEnabled
          オンプレ同期 = $user.OnPremisesSyncEnabled
          問題 = "ライセンスありだがExchange Onlineなし"
        })
      }
    }
  } else {
    # 従来のバッチ処理モード
    $usersSummary = $users | ForEach-Object {
      $user = $_

      # Exchange Online有効状態をassignedPlansから判定
      $hasExoEnabled = $false
      if ($user.AssignedPlans) {
        $exoPlans = $user.AssignedPlans | Where-Object {
          $_.ServicePlanId -and
          $_.CapabilityStatus -eq "Enabled" -and
          ($_.Service -eq "exchange" -or $_.Service -match "Exchange")
        }
        if ($exoPlans) { $hasExoEnabled = $true }
      }

      $skuNames = @()
      if ($user.AssignedLicenses) {
        $skuNames = $user.AssignedLicenses | ForEach-Object {
          if ($skuLookup.ContainsKey($_.SkuId)) { $skuLookup[$_.SkuId] }
          else { $_.SkuId }
        }
      }

      # ライセンス割当方法
      $licenseAssignmentMethod = "なし"
      if ($user.LicenseAssignmentStates) {
        $directAssign = $user.LicenseAssignmentStates | Where-Object { $_.AssignedByGroup -eq $null }
        $groupAssign = $user.LicenseAssignmentStates | Where-Object { $_.AssignedByGroup -ne $null }
        if ($directAssign -and $groupAssign) { $licenseAssignmentMethod = "直接+グループ" }
        elseif ($directAssign) { $licenseAssignmentMethod = "直接" }
        elseif ($groupAssign) { $licenseAssignmentMethod = "グループ" }
      }

      # ライセンス問題チェック
      if ($user.AccountEnabled -and $user.AssignedLicenses.Count -eq 0) {
        $licenseIssues.Add([PSCustomObject]@{
          UPN = $user.UserPrincipalName
          表示名 = $user.DisplayName
          有効 = $user.AccountEnabled
          オンプレ同期 = $user.OnPremisesSyncEnabled
          問題 = "有効ユーザーにライセンスなし"
        })
      }
      if ($user.AssignedLicenses.Count -gt 0 -and -not $hasExoEnabled) {
        $licenseIssues.Add([PSCustomObject]@{
          UPN = $user.UserPrincipalName
          表示名 = $user.DisplayName
          有効 = $user.AccountEnabled
          オンプレ同期 = $user.OnPremisesSyncEnabled
          問題 = "ライセンスありだがExchange Onlineなし"
        })
      }

      [PSCustomObject]@{
        表示名 = $user.DisplayName
        UPN = $user.UserPrincipalName
        メール = $user.Mail
        有効 = $user.AccountEnabled
        オンプレ同期 = $user.OnPremisesSyncEnabled
        ユーザー種別 = $user.UserType
        作成日時 = $user.CreatedDateTime
        割当SKU = ($skuNames -join ";")
        SKU数 = $user.AssignedLicenses.Count
        HasExoEnabled = $hasExoEnabled
        ライセンス割当方法 = $licenseAssignmentMethod
        proxyAddresses = ($user.ProxyAddresses -join ";")
      }
    }

    $usersSummary | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "users_license.csv")

    # 詳細データ出力（機械可読）
    $users | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "users_license.json") -Encoding UTF8
    $users | Export-Clixml -Path (Join-Path $OutDir "users_license.xml") -Encoding UTF8
  }

  # ライセンス問題ユーザーを出力
  if ($licenseIssues.Count -gt 0) {
    $licenseIssues | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "users_licence_issues.csv")
    Write-Host "      → ライセンス問題ユーザー: $($licenseIssues.Count) 件 → users_licence_issues.csv"
  } else {
    "# ライセンス問題ユーザーはいません" | Out-File (Join-Path $OutDir "users_licence_issues.csv") -Encoding UTF8
  }

  Write-Host "      → ユーザー数: $($users.Count)"

  #----------------------------------------------------------------------
  # 7. ★重要：ライセンス割当グループの取得
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[7/8] ★ ライセンス割当グループを取得中..."

  try {
    # ライセンスが割り当てられているグループを取得
    $licenseGroups = Get-MgGroup -All -Property "id,displayName,assignedLicenses" |
      Where-Object { $_.AssignedLicenses -and $_.AssignedLicenses.Count -gt 0 }

    if ($licenseGroups -and $licenseGroups.Count -gt 0) {
      $licenseGroupsSummary = $licenseGroups | ForEach-Object {
        $group = $_
        $skuNames = @()
        if ($group.AssignedLicenses) {
          $skuNames = $group.AssignedLicenses | ForEach-Object {
            if ($skuLookup.ContainsKey($_.SkuId)) { $skuLookup[$_.SkuId] }
            else { $_.SkuId }
          }
        }

        [PSCustomObject]@{
          グループ名 = $group.DisplayName
          グループID = $group.Id
          割当SKU = ($skuNames -join ";")
          SKU数 = $group.AssignedLicenses.Count
        }
      }

      $licenseGroupsSummary | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "license_groups.csv")
      Write-Host "      → ライセンス割当グループ: $($licenseGroups.Count) 件"
    } else {
      "# ライセンス割当グループはありません" | Out-File (Join-Path $OutDir "license_groups.csv") -Encoding UTF8
      Write-Host "      → ライセンス割当グループ: なし（直接割当のみ）"
    }
  } catch {
    Write-Warning "ライセンス割当グループの取得に失敗: $_"
  }

  #----------------------------------------------------------------------
  # 8. サマリー作成
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[8/8] サマリーを作成中..."

  $syncedUsers = ($users | Where-Object { $_.OnPremisesSyncEnabled -eq $true }).Count
  $cloudOnlyUsers = ($users | Where-Object { $_.OnPremisesSyncEnabled -ne $true }).Count
  $licensedUsers = ($users | Where-Object { $_.AssignedLicenses.Count -gt 0 }).Count

  # Exchange Online有効ユーザー数を集計
  $exoEnabledCount = 0
  foreach ($user in $users) {
    if ($user.AssignedPlans) {
      $exoPlans = $user.AssignedPlans | Where-Object {
        $_.CapabilityStatus -eq "Enabled" -and
        ($_.Service -eq "exchange" -or $_.Service -match "Exchange")
      }
      if ($exoPlans) { $exoEnabledCount++ }
    }
  }

  $summary = @"
#===============================================================================
# Entra ID 棚卸しサマリー（強化版）
#===============================================================================

【実行日時】$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

【テナント】
  名前:              $($org.DisplayName)
  DirSync有効:       $dirSyncEnabled
  最終同期:          $(if ($org.OnPremisesLastSyncDateTime) { $org.OnPremisesLastSyncDateTime } else { "N/A" })

【ドメイン】
  登録数:            $(if ($domains) { $domains.Count } else { "取得不可" })
  デフォルト:        $(if ($domains) { ($domains | Where-Object { $_.IsDefault }).Id } else { "取得不可" })

【ユーザー統計】
  総数:                     $($users.Count)
  オンプレ同期:             $syncedUsers
  クラウドのみ:             $cloudOnlyUsers
  ライセンス割当あり:       $licensedUsers
  Exchange Online有効:      $exoEnabledCount
  ライセンス問題ユーザー:   $($licenseIssues.Count)

【ライセンスSKU】
$($skus | ForEach-Object { "  $($_.SkuPartNumber): 消費 $($_.ConsumedUnits) / 有効 $($_.PrepaidUnits.Enabled)" } | Out-String)

【ライセンス割当グループ】
$(if ($licenseGroups -and $licenseGroups.Count -gt 0) {
  ($licenseGroups | ForEach-Object { "  - $($_.DisplayName)" }) -join "`n"
} else {
  "  なし（直接割当のみ）"
})

【出力形式】
  要約CSV: subscribed_skus.csv, users_license.csv, domains.csv
  詳細JSON: subscribed_skus.json, users_license.json, domains.json
  詳細XML: subscribed_skus.xml, users_license.xml

【確認すべきファイル】

  ★ org.json
     → テナント情報（DirSync状態含む）
     → OnPremisesSyncEnabled でAD連携有無を確認

  ★ domains.csv / domains.json
     → ドメイン一覧
     → 認証タイプ、サポート対象サービスを確認

  ★ subscribed_skus.csv
     → ライセンス一覧（要約・人が読む用）
     → Exchange Online を含むSKUを確認

  ★ users_license.csv
     → ユーザー×ライセンス対応表（要約・人が読む用）
     → 「オンプレ同期」列でAD連携状態を確認
     → 「HasExoEnabled」列でExchange Online有効状態を確認
     → 「ライセンス割当方法」で直接/グループ経由を確認

  ★ users_licence_issues.csv
     → ライセンス問題ユーザー
     → 有効ユーザーにライセンスなし、EXOなしなどを検出

  ★ license_groups.csv
     → ライセンス割当グループ一覧
     → グループベースのライセンス管理を確認

【判断ポイント】

  1. DirSync有効: $dirSyncEnabled
     → TrueならADからEntra Connectで同期されている
     → EXO移行時はAD側でmail属性を設定する必要あり

  2. オンプレ同期ユーザーが $syncedUsers 人
     → これらはADからEntra Connectで同期されている
     → AD側のmail/proxyAddresses属性を確認

  3. クラウドのみユーザーが $cloudOnlyUsers 人
     → ADとは無関係にEntraで作成されたユーザー
     → 必要に応じてADに作成して同期させる検討

  4. Exchange Online有効ユーザーが $exoEnabledCount 人
     → assignedPlans でExchange=Enabledのユーザー数
     → EXO移行後のメールボックス対象者数の目安

  5. ライセンス問題ユーザーが $($licenseIssues.Count) 人
     → 移行前に解消しておくことを推奨

"@

  $summary | Out-File (Join-Path $OutDir "summary.txt") -Encoding UTF8

  Write-Host ""
  Write-Host "============================================================"
  Write-Host " 完了"
  Write-Host "============================================================"
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

  # エラーを再スロー
  throw
} finally {
  # 必ず実行される後片付け
  if ($mgConnected) {
    try {
      Disconnect-MgGraph
      Write-Host "Microsoft Graph から切断しました"
    } catch {
      # 切断でエラーが出ても無視
    }
  }

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
