<#
.SYNOPSIS
  Entra Connect (Azure AD Connect) 棚卸しスクリプト

.DESCRIPTION
  Entra Connect（旧 Azure AD Connect）サーバーの設定情報を収集し、EXO移行計画に必要な情報を取得します。
  ADSyncモジュールがインストールされているEntra Connectサーバー上で実行してください。

  【収集する情報】
  - Entra Connectバージョン・Scheduler状態
  - Connectors（AD/Entra ID）構成
  - Sync Rules（同期ルール）一覧
  - mail/proxy/mailNickname/targetAddressの属性フロー
  - sourceAnchor設定（msDS-ConsistencyGuid or objectGUID）
  - 直近の同期実行状況・エラー
  - Pending Export（保留中のエクスポート）状況

  【出力ファイルと確認ポイント】
  scheduler.json              ← ★重要: Scheduler状態（同期間隔・有効/無効）
  version.json                ← ★重要: Entra Connectバージョン
  connectors.csv              ← ★重要: Connectors一覧（AD/Entra ID）
  connectors.json             ← 詳細データ（機械可読）
  sync_rules.csv              ← ★重要: Sync Rules一覧
  sync_rules.json             ← 詳細データ（機械可読）
  attribute_flows_mail.csv    ← ★重要: mail/proxy/mailNickname/targetAddress属性フロー
  source_anchor.json          ← ★重要: sourceAnchor設定
  run_history.csv             ← ★重要: 直近の同期実行履歴
  run_history_errors.csv      ← ★重要: エラー一覧
  pending_exports.csv         ← ★重要: 保留中のエクスポート
  global_settings.json        ← グローバル設定
  server_config/              ← Export-ADSyncServerConfiguration出力（JSON）
  summary.txt                 ← 統計サマリー

.PARAMETER OutRoot
  出力先ルートフォルダ（デフォルト: .\inventory）

.PARAMETER Tag
  出力フォルダのサフィックス（デフォルト: 日時）

.PARAMETER RunHistoryLimit
  取得する同期履歴の件数（デフォルト: 100）

.PARAMETER PendingExportLimit
  取得するPending Exportの件数（デフォルト: 500）

.EXAMPLE
  .\Collect-EntraConnectInventory.ps1 -OutRoot C:\temp\inventory

.EXAMPLE
  .\Collect-EntraConnectInventory.ps1 -RunHistoryLimit 50 -PendingExportLimit 100

.NOTES
  必要モジュール: ADSync（Entra Connectサーバーにインストール済み）
  実行権限: 管理者権限が必要
#>
param(
  [string]$OutRoot = ".\inventory",
  [string]$Tag = (Get-Date -Format "yyyyMMdd_HHmmss"),
  [int]$RunHistoryLimit = 100,
  [int]$PendingExportLimit = 500
)

# UTF-8 with BOM出力用エンコーディング
$Utf8Bom = New-Object System.Text.UTF8Encoding $true

# エラーアクションの設定
$ErrorActionPreference = "Stop"

# 出力先フォルダ作成
$OutDir = Join-Path $OutRoot ("entra_connect_" + $Tag)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# グローバル変数（finally句で参照）
$transcriptStarted = $false
$schedulerInfo = $null
$versionInfo = $null
$connectors = $null
$syncRules = $null
$runHistory = $null
$errorCount = 0
$pendingExportCount = 0
$sourceAnchorAttribute = "Unknown"

try {
  # トランスクリプト開始
  Start-Transcript -Path (Join-Path $OutDir "run.log") -Force
  $transcriptStarted = $true

  Write-Host "============================================================"
  Write-Host " Entra Connect (Azure AD Connect) 棚卸し"
  Write-Host "============================================================"
  Write-Host "出力先: $OutDir"
  Write-Host ""

  #----------------------------------------------------------------------
  # 1. ADSyncモジュールの確認（Fail Fast）
  #----------------------------------------------------------------------
  Write-Host "[1/12] ADSyncモジュールを確認中..."

  if (-not (Get-Module -ListAvailable -Name ADSync)) {
    throw "ADSyncモジュールが見つかりません。このスクリプトはEntra Connect（Azure AD Connect）サーバー上で実行してください。"
  }

  try {
    Import-Module ADSync -ErrorAction Stop
    Write-Host "      → ADSyncモジュールをインポートしました"
  } catch {
    throw "ADSyncモジュールのインポートに失敗しました: $_"
  }

  #----------------------------------------------------------------------
  # 2. ★重要：バージョン情報の取得
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[2/12] ★ Entra Connectバージョンを取得中..."

  try {
    # ADSyncGlobalSettings からバージョン情報を取得
    $globalSettings = Get-ADSyncGlobalSettings
    $versionInfo = [PSCustomObject]@{
      CollectionTime = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
      Hostname = $env:COMPUTERNAME
    }

    # レジストリからバージョン情報を取得
    $aadcRegPath = "HKLM:\SOFTWARE\Microsoft\Azure AD Connect"
    if (Test-Path $aadcRegPath) {
      $regInfo = Get-ItemProperty -Path $aadcRegPath -ErrorAction SilentlyContinue
      if ($regInfo) {
        $versionInfo | Add-Member -MemberType NoteProperty -Name "Version" -Value $regInfo.Version -ErrorAction SilentlyContinue
        $versionInfo | Add-Member -MemberType NoteProperty -Name "WizardVersion" -Value $regInfo.WizardVersion -ErrorAction SilentlyContinue
        Write-Host "      → バージョン: $($regInfo.Version)"
      }
    }

    # 代替：ADSyncSchedulerからバージョン取得を試みる
    if (-not $versionInfo.Version) {
      try {
        $scheduler = Get-ADSyncScheduler
        $versionInfo | Add-Member -MemberType NoteProperty -Name "SchedulerReportedVersion" -Value "N/A (レジストリから取得不可)" -Force
        Write-Host "      → バージョン情報はレジストリから取得できませんでした"
      } catch {
        Write-Warning "バージョン情報の取得に失敗: $_"
      }
    }

    $versionInfo | ConvertTo-Json -Depth 5 | Out-File (Join-Path $OutDir "version.json") -Encoding UTF8
  } catch {
    Write-Warning "バージョン情報の取得に失敗: $_"
  }

  #----------------------------------------------------------------------
  # 3. ★重要：Scheduler状態の取得
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[3/12] ★ Scheduler状態を取得中..."

  try {
    $schedulerInfo = Get-ADSyncScheduler

    Write-Host "      → 同期有効:         $($schedulerInfo.SyncCycleEnabled)"
    Write-Host "      → 同期間隔:         $($schedulerInfo.CurrentlyEffectiveSyncCycleInterval)"
    Write-Host "      → ステージングモード: $($schedulerInfo.StagingModeEnabled)"
    Write-Host "      → 次回同期:         $($schedulerInfo.NextSyncCycleStartTimeInUTC)"

    $schedulerInfo | ConvertTo-Json -Depth 5 | Out-File (Join-Path $OutDir "scheduler.json") -Encoding UTF8
  } catch {
    Write-Warning "Scheduler状態の取得に失敗: $_"
  }

  #----------------------------------------------------------------------
  # 4. グローバル設定の取得
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[4/12] グローバル設定を取得中..."

  try {
    $globalSettings = Get-ADSyncGlobalSettings
    $globalSettings | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "global_settings.json") -Encoding UTF8

    # パラメータ一覧を出力
    $globalParams = $globalSettings.Parameters | ForEach-Object {
      [PSCustomObject]@{
        Name = $_.Name
        Value = $_.Value
      }
    }
    $globalParams | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "global_settings_params.csv")

    Write-Host "      → グローバル設定を保存しました"
  } catch {
    Write-Warning "グローバル設定の取得に失敗: $_"
  }

  #----------------------------------------------------------------------
  # 5. ★重要：Connectors（AD/Entra ID）構成の取得
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[5/12] ★ Connectors構成を取得中..."

  try {
    $connectors = Get-ADSyncConnector

    # 要約CSV出力
    $connectorsSummary = $connectors | ForEach-Object {
      [PSCustomObject]@{
        Name = $_.Name
        Identifier = $_.Identifier
        Type = $_.Type
        Subtype = $_.Subtype
        CreationTime = $_.CreationTime
        LastModificationTime = $_.LastModificationTime
        Description = $_.Description
      }
    }
    $connectorsSummary | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "connectors.csv")

    # 詳細JSON出力（秘密情報を除外）
    $connectorsDetail = $connectors | ForEach-Object {
      $conn = $_

      # パーティション情報（AD用）
      $partitions = @()
      if ($conn.Partitions) {
        $partitions = $conn.Partitions | ForEach-Object {
          [PSCustomObject]@{
            Name = $_.Name
            DN = $_.DN
            Selected = $_.Selected
          }
        }
      }

      [PSCustomObject]@{
        Name = $conn.Name
        Identifier = $conn.Identifier
        Type = $conn.Type
        Subtype = $conn.Subtype
        CreationTime = $conn.CreationTime
        LastModificationTime = $conn.LastModificationTime
        Description = $conn.Description
        Partitions = $partitions
        # 接続パラメータ（秘密情報を除外）
        ConnectionParameterKeys = if ($conn.ConnectivityParameters) {
          ($conn.ConnectivityParameters | Where-Object { $_.Name -notmatch 'password|secret|key' } | ForEach-Object { $_.Name })
        } else { @() }
      }
    }
    $connectorsDetail | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "connectors.json") -Encoding UTF8

    Write-Host "      → Connectors数: $($connectors.Count)"
    foreach ($conn in $connectors) {
      Write-Host "        - $($conn.Name) ($($conn.Type))"
    }
  } catch {
    Write-Warning "Connectors構成の取得に失敗: $_"
  }

  #----------------------------------------------------------------------
  # 6. ★重要：sourceAnchor設定の取得
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[6/12] ★ sourceAnchor設定を取得中..."

  try {
    # sourceAnchorを特定（GlobalSettingsから）
    $sourceAnchorParam = $globalSettings.Parameters | Where-Object { $_.Name -eq "Microsoft.OptionalFeature.AnchorAttribute" }

    if ($sourceAnchorParam -and $sourceAnchorParam.Value) {
      $sourceAnchorAttribute = $sourceAnchorParam.Value
    } else {
      # デフォルトを判定
      # msDS-ConsistencyGuid が有効な場合はそれを使用、そうでなければobjectGUID
      $consistencyGuidParam = $globalSettings.Parameters | Where-Object { $_.Name -eq "Microsoft.SynchronizationOption.AnchorAttribute" }
      if ($consistencyGuidParam -and $consistencyGuidParam.Value) {
        $sourceAnchorAttribute = $consistencyGuidParam.Value
      } else {
        # Sync Rulesから推測
        $sourceAnchorRule = Get-ADSyncRule | Where-Object {
          $_.Direction -eq "Outbound" -and
          $_.TargetObjectType -eq "user" -and
          $_.Connector -match "AAD"
        } | Select-Object -First 1

        if ($sourceAnchorRule) {
          $anchorFlow = $sourceAnchorRule.AttributeFlowMappings | Where-Object { $_.Destination -eq "sourceAnchor" }
          if ($anchorFlow) {
            $sourceAnchorAttribute = $anchorFlow.Source
          }
        }
      }
    }

    Write-Host "      → sourceAnchor: $sourceAnchorAttribute"

    $sourceAnchorInfo = [PSCustomObject]@{
      sourceAnchorAttribute = $sourceAnchorAttribute
      Description = switch ($sourceAnchorAttribute) {
        "ms-DS-ConsistencyGuid" { "msDS-ConsistencyGuid（推奨）- Entra IDのImmutableIdに同期" }
        "objectGUID" { "objectGUID - 従来のソースアンカー" }
        "mS-DS-ConsistencyGuid" { "msDS-ConsistencyGuid（推奨）- Entra IDのImmutableIdに同期" }
        default { "カスタム属性または不明" }
      }
      Notes = "この属性がEntra IDのImmutableIdにマッピングされます。移行時にこの値が一致している必要があります。"
    }

    $sourceAnchorInfo | ConvertTo-Json -Depth 5 | Out-File (Join-Path $OutDir "source_anchor.json") -Encoding UTF8
  } catch {
    Write-Warning "sourceAnchor設定の取得に失敗: $_"
  }

  #----------------------------------------------------------------------
  # 7. ★重要：Sync Rules（同期ルール）一覧の取得
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[7/12] ★ Sync Rules（同期ルール）一覧を取得中..."

  try {
    $syncRules = Get-ADSyncRule

    # 要約CSV出力
    $syncRulesSummary = $syncRules | ForEach-Object {
      [PSCustomObject]@{
        Name = $_.Name
        Identifier = $_.Identifier
        Direction = $_.Direction
        Precedence = $_.Precedence
        SourceObjectType = $_.SourceObjectType
        TargetObjectType = $_.TargetObjectType
        Connector = $_.Connector
        LinkType = $_.LinkType
        ImmutableTag = $_.ImmutableTag
        Disabled = $_.Disabled
      }
    } | Sort-Object Precedence

    $syncRulesSummary | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "sync_rules.csv")

    # 詳細JSON出力
    $syncRulesDetail = $syncRules | ForEach-Object {
      [PSCustomObject]@{
        Name = $_.Name
        Identifier = $_.Identifier
        Direction = $_.Direction
        Precedence = $_.Precedence
        SourceObjectType = $_.SourceObjectType
        TargetObjectType = $_.TargetObjectType
        Connector = $_.Connector
        LinkType = $_.LinkType
        ImmutableTag = $_.ImmutableTag
        Disabled = $_.Disabled
        ScopingFilter = $_.ScopingFilter
        JoinFilter = $_.JoinFilter
        AttributeFlowMappingsCount = ($_.AttributeFlowMappings | Measure-Object).Count
      }
    }
    $syncRulesDetail | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "sync_rules.json") -Encoding UTF8

    Write-Host "      → Sync Rules数: $($syncRules.Count)"
    Write-Host "        - Inbound:  $(($syncRules | Where-Object { $_.Direction -eq 'Inbound' }).Count)"
    Write-Host "        - Outbound: $(($syncRules | Where-Object { $_.Direction -eq 'Outbound' }).Count)"
  } catch {
    Write-Warning "Sync Rulesの取得に失敗: $_"
  }

  #----------------------------------------------------------------------
  # 8. ★重要：mail/proxy/mailNickname/targetAddressの属性フロー抽出
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[8/12] ★ メール関連属性フローを抽出中..."
  Write-Host "      → mail, proxyAddresses, mailNickname, targetAddress の属性フローを抽出"

  try {
    $mailAttributes = @("mail", "proxyAddresses", "mailNickname", "targetAddress", "userPrincipalName", "sourceAnchor")

    $attributeFlows = @()
    foreach ($rule in $syncRules) {
      if ($rule.AttributeFlowMappings) {
        foreach ($flow in $rule.AttributeFlowMappings) {
          # 対象属性に関連するフローを抽出
          $isRelevant = $false
          foreach ($attr in $mailAttributes) {
            if ($flow.Source -match $attr -or $flow.Destination -match $attr) {
              $isRelevant = $true
              break
            }
          }

          if ($isRelevant) {
            $attributeFlows += [PSCustomObject]@{
              RuleName = $rule.Name
              RulePrecedence = $rule.Precedence
              Direction = $rule.Direction
              SourceObjectType = $rule.SourceObjectType
              TargetObjectType = $rule.TargetObjectType
              ConnectorName = $rule.Connector
              SourceAttribute = $flow.Source
              DestinationAttribute = $flow.Destination
              FlowType = $flow.FlowType
              ValueMergeType = $flow.ValueMergeType
              Expression = if ($flow.Expression) { $flow.Expression.ToString().Substring(0, [Math]::Min(200, $flow.Expression.ToString().Length)) } else { $null }
            }
          }
        }
      }
    }

    $attributeFlows | Sort-Object Direction, RulePrecedence |
      Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "attribute_flows_mail.csv")

    # JSON出力
    $attributeFlows | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "attribute_flows_mail.json") -Encoding UTF8

    Write-Host "      → メール関連属性フロー数: $($attributeFlows.Count)"

    # 主要な属性フローを表示
    $keyFlows = $attributeFlows | Where-Object { $_.DestinationAttribute -in @("mail", "proxyAddresses", "mailNickname", "sourceAnchor") }
    if ($keyFlows) {
      Write-Host ""
      Write-Host "      【主要な属性フロー】"
      foreach ($flow in ($keyFlows | Select-Object -First 10)) {
        Write-Host "        $($flow.Direction): $($flow.SourceAttribute) → $($flow.DestinationAttribute)"
      }
    }
  } catch {
    Write-Warning "属性フローの抽出に失敗: $_"
  }

  #----------------------------------------------------------------------
  # 9. ★重要：直近の同期実行履歴の取得
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[9/12] ★ 直近の同期実行履歴を取得中（最大 $RunHistoryLimit 件）..."

  try {
    $runHistory = @()

    foreach ($conn in $connectors) {
      try {
        $history = Get-ADSyncRunProfileResult -ConnectorId $conn.Identifier -NumberRequested $RunHistoryLimit -ErrorAction SilentlyContinue
        if ($history) {
          foreach ($run in $history) {
            $runHistory += [PSCustomObject]@{
              ConnectorName = $conn.Name
              ConnectorType = $conn.Type
              RunProfileName = $run.RunProfileName
              Result = $run.Result
              StartDate = $run.StartDate
              EndDate = $run.EndDate
              CountNonError = $run.StepResult.CountNonError
              CountErrors = $run.StepResult.CountErrors
              CountMissing = $run.StepResult.CountMissing
              CountAdds = $run.StepResult.CountAdds
              CountUpdates = $run.StepResult.CountUpdates
              CountDeletes = $run.StepResult.CountDeletes
            }

            # エラー件数を集計
            if ($run.StepResult.CountErrors -gt 0) {
              $errorCount += $run.StepResult.CountErrors
            }
          }
        }
      } catch {
        Write-Warning "Connector '$($conn.Name)' の履歴取得に失敗: $_"
      }
    }

    $runHistory | Sort-Object StartDate -Descending |
      Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "run_history.csv")

    Write-Host "      → 同期履歴: $($runHistory.Count) 件"
    Write-Host "      → エラー総数: $errorCount"

    # 直近の実行結果を表示
    $recentRuns = $runHistory | Sort-Object StartDate -Descending | Select-Object -First 5
    if ($recentRuns) {
      Write-Host ""
      Write-Host "      【直近の同期結果】"
      foreach ($run in $recentRuns) {
        $status = if ($run.Result -eq "success") { "✓" } else { "✗" }
        Write-Host "        $status $($run.ConnectorName): $($run.RunProfileName) - $($run.Result) ($($run.StartDate))"
      }
    }
  } catch {
    Write-Warning "同期履歴の取得に失敗: $_"
  }

  #----------------------------------------------------------------------
  # 10. エラー詳細の取得
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[10/12] エラー詳細を取得中..."

  try {
    $syncErrors = @()

    foreach ($conn in $connectors) {
      try {
        $csErrors = Get-ADSyncCSObject -ConnectorIdentifier $conn.Identifier -HasError -MaxResults 100 -ErrorAction SilentlyContinue
        if ($csErrors) {
          foreach ($csObj in $csErrors) {
            $syncErrors += [PSCustomObject]@{
              ConnectorName = $conn.Name
              ObjectType = $csObj.ObjectType
              DN = $csObj.DN
              ErrorType = $csObj.ExportError.ErrorType
              ErrorDescription = if ($csObj.ExportError.ErrorDescription) {
                # 秘密情報をマスク
                $csObj.ExportError.ErrorDescription -replace '(?i)(password|secret|key)=[^\s;]+', '$1=***MASKED***'
              } else { $null }
              DateOccurred = $csObj.ExportError.DateOccurred
            }
          }
        }
      } catch {
        # エラーを無視して続行
      }
    }

    if ($syncErrors.Count -gt 0) {
      $syncErrors | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "run_history_errors.csv")
      Write-Host "      → 同期エラー: $($syncErrors.Count) 件"
    } else {
      "# 同期エラーはありません" | Out-File (Join-Path $OutDir "run_history_errors.csv") -Encoding UTF8
      Write-Host "      → 同期エラー: なし"
    }
  } catch {
    Write-Warning "エラー詳細の取得に失敗: $_"
  }

  #----------------------------------------------------------------------
  # 11. ★重要：Pending Export（保留中のエクスポート）状況の取得
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[11/12] ★ Pending Export（保留中のエクスポート）を取得中..."

  try {
    $pendingExports = @()

    foreach ($conn in $connectors) {
      try {
        # Pending Exportを取得
        $pending = Get-ADSyncCSObject -ConnectorIdentifier $conn.Identifier -HasExportPending -MaxResults $PendingExportLimit -ErrorAction SilentlyContinue
        if ($pending) {
          foreach ($obj in $pending) {
            $pendingExports += [PSCustomObject]@{
              ConnectorName = $conn.Name
              ObjectType = $obj.ObjectType
              DN = $obj.DN
              Operation = $obj.PendingExportOperation
              AttributeChanges = if ($obj.PendingExportAttributeChanges) {
                ($obj.PendingExportAttributeChanges.Name -join ";")
              } else { $null }
            }
            $pendingExportCount++
          }
        }
      } catch {
        # エラーを無視して続行
      }
    }

    if ($pendingExports.Count -gt 0) {
      $pendingExports | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "pending_exports.csv")
      Write-Host "      → Pending Exports: $pendingExportCount 件"

      # オペレーション別の集計
      $pendingByOp = $pendingExports | Group-Object Operation
      foreach ($group in $pendingByOp) {
        Write-Host "        - $($group.Name): $($group.Count)"
      }
    } else {
      "# Pending Exportはありません" | Out-File (Join-Path $OutDir "pending_exports.csv") -Encoding UTF8
      Write-Host "      → Pending Exports: なし"
    }
  } catch {
    Write-Warning "Pending Exportの取得に失敗: $_"
  }

  #----------------------------------------------------------------------
  # 12. Export-ADSyncServerConfiguration（サーバー構成のエクスポート）
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[12/12] Export-ADSyncServerConfiguration を実行中..."

  try {
    $serverConfigDir = Join-Path $OutDir "server_config"
    New-Item -ItemType Directory -Force -Path $serverConfigDir | Out-Null

    Export-ADSyncServerConfiguration -Path $serverConfigDir

    Write-Host "      → サーバー構成をエクスポートしました: server_config/"

    # 出力されたファイルをリスト
    $configFiles = Get-ChildItem -Path $serverConfigDir -Recurse -File
    Write-Host "      → エクスポートファイル数: $($configFiles.Count)"
  } catch {
    Write-Warning "Export-ADSyncServerConfigurationに失敗: $_"
    Write-Host "      → この機能はEntra Connectのバージョンによっては利用できない場合があります"
  }

  #----------------------------------------------------------------------
  # サマリー作成
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "============================================================"
  Write-Host " 完了"
  Write-Host "============================================================"

  # サマリー統計を収集
  $inboundRules = if ($syncRules) { ($syncRules | Where-Object { $_.Direction -eq 'Inbound' }).Count } else { 0 }
  $outboundRules = if ($syncRules) { ($syncRules | Where-Object { $_.Direction -eq 'Outbound' }).Count } else { 0 }
  $recentErrors = if ($runHistory) {
    ($runHistory | Where-Object { $_.CountErrors -gt 0 } | Measure-Object -Property CountErrors -Sum).Sum
  } else { 0 }

  $summary = @"
#===============================================================================
# Entra Connect 棚卸しサマリー
#===============================================================================

【実行日時】$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
【ホスト名】$env:COMPUTERNAME

【バージョン】
  Entra Connect: $(if ($versionInfo.Version) { $versionInfo.Version } else { "取得不可" })

【Scheduler】
  同期有効:          $(if ($schedulerInfo) { $schedulerInfo.SyncCycleEnabled } else { "取得不可" })
  同期間隔:          $(if ($schedulerInfo) { $schedulerInfo.CurrentlyEffectiveSyncCycleInterval } else { "取得不可" })
  ステージングモード: $(if ($schedulerInfo) { $schedulerInfo.StagingModeEnabled } else { "取得不可" })
  次回同期予定:      $(if ($schedulerInfo) { $schedulerInfo.NextSyncCycleStartTimeInUTC } else { "取得不可" })

【sourceAnchor】
  属性: $sourceAnchorAttribute
  ※この属性がEntra IDのImmutableIdにマッピングされます

【Connectors】
  総数: $(if ($connectors) { $connectors.Count } else { 0 })
$(if ($connectors) {
  ($connectors | ForEach-Object { "    - $($_.Name) ($($_.Type))" }) -join "`n"
} else { "    取得不可" })

【Sync Rules】
  総数:     $(if ($syncRules) { $syncRules.Count } else { 0 })
  Inbound:  $inboundRules
  Outbound: $outboundRules

【同期状況】
  履歴取得件数:      $($runHistory.Count)
  エラー総数:        $recentErrors
  Pending Exports:   $pendingExportCount

#-------------------------------------------------------------------------------
# 確認すべきファイル
#-------------------------------------------------------------------------------

  ★ scheduler.json
     → Scheduler状態（同期間隔、有効/無効、ステージングモード）
     → ステージングモードが有効の場合は実際の同期は行われていません

  ★ source_anchor.json
     → sourceAnchor設定（msDS-ConsistencyGuid or objectGUID）
     → EXO移行時にこの値がEntra IDのImmutableIdと一致している必要があります

  ★ connectors.csv / connectors.json
     → AD/Entra ID Connectors構成
     → 同期対象のADパーティションを確認

  ★ sync_rules.csv / sync_rules.json
     → 同期ルール一覧
     → カスタムルールがある場合は移行時に考慮が必要

  ★ attribute_flows_mail.csv
     → mail/proxyAddresses/mailNickname/targetAddressの属性フロー
     → これらの属性がどのようにEntra IDに同期されるかを確認
     → EXO移行時のメールアドレス設定に重要

  ★ run_history.csv
     → 直近の同期実行履歴
     → エラーが多発している場合は原因調査が必要

  ★ run_history_errors.csv
     → 同期エラーの詳細
     → 移行前にエラーを解消しておくことを推奨

  ★ pending_exports.csv
     → 保留中のエクスポート
     → 大量にある場合は同期が滞っている可能性

  ★ server_config/
     → Export-ADSyncServerConfigurationの出力
     → サーバー構成のバックアップとして使用可能

#-------------------------------------------------------------------------------
# 判断ポイント
#-------------------------------------------------------------------------------

  1. sourceAnchor: $sourceAnchorAttribute
     → msDS-ConsistencyGuidが推奨（objectGUIDからの移行は計画が必要）

  2. ステージングモード: $(if ($schedulerInfo) { $schedulerInfo.StagingModeEnabled } else { "取得不可" })
     → 有効の場合、このサーバーは待機系（同期は読み取り専用）

  3. Pending Exports: $pendingExportCount
     → 大量にある場合は同期に問題がある可能性

  4. 同期エラー: $recentErrors
     → 移行前にゼロにしておくことを推奨

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

  # エラーを再スロー
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
