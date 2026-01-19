<#
.SYNOPSIS
  移行前提条件チェックスクリプト

.DESCRIPTION
  Exchange Online移行の各フェーズ実行前に、必要な前提条件を確認します。
  このスクリプトは読み取り専用で、環境への変更は行いません。

  【チェック項目】
  - AD: ドメイン接続、Schema Admins/Enterprise Admins権限、Schema Master確認
  - EXO: 接続状態、Organization Management権限
  - Graph: 接続状態、必要スコープの同意確認
  - ネットワーク: 必要なエンドポイントへの疎通

  【出力ファイル】
  prereq_check_results.json  ← チェック結果（機械可読）
  prereq_check_summary.txt   ← サマリー（人が読む用）

.PARAMETER CheckAD
  AD関連のチェックを実行

.PARAMETER CheckEXO
  Exchange Online関連のチェックを実行

.PARAMETER CheckGraph
  Microsoft Graph関連のチェックを実行

.PARAMETER CheckNetwork
  ネットワーク疎通チェックを実行

.PARAMETER All
  全てのチェックを実行

.PARAMETER OutDir
  出力先フォルダ

.EXAMPLE
  # 全チェック実行
  .\Test-Prerequisites.ps1 -All

.EXAMPLE
  # AD関連のみチェック（スキーマ拡張前）
  .\Test-Prerequisites.ps1 -CheckAD

.EXAMPLE
  # EXO + Graph（コネクタ作成前）
  .\Test-Prerequisites.ps1 -CheckEXO -CheckGraph
#>
param(
  [switch]$CheckAD,
  [switch]$CheckEXO,
  [switch]$CheckGraph,
  [switch]$CheckNetwork,
  [switch]$All,
  [string]$OutDir = ".\prereq_check"
)

# エラーアクションの設定
$ErrorActionPreference = "Continue"

# 出力先フォルダ作成
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$OutDir = Join-Path $OutDir $ts
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Start-Transcript -Path (Join-Path $OutDir "run.log") -Force

Write-Host "============================================================"
Write-Host " EXO移行 前提条件チェック"
Write-Host "============================================================"
Write-Host "出力先: $OutDir"
Write-Host ""

# Allが指定された場合は全てON
if ($All) {
  $CheckAD = $true
  $CheckEXO = $true
  $CheckGraph = $true
  $CheckNetwork = $true
}

# 何もチェックが指定されていない場合はヘルプ表示
if (-not $CheckAD -and -not $CheckEXO -and -not $CheckGraph -and -not $CheckNetwork) {
  Write-Host "チェック項目が指定されていません。"
  Write-Host ""
  Write-Host "使用例:"
  Write-Host "  .\Test-Prerequisites.ps1 -All              # 全チェック"
  Write-Host "  .\Test-Prerequisites.ps1 -CheckAD          # AD関連のみ"
  Write-Host "  .\Test-Prerequisites.ps1 -CheckEXO -CheckGraph  # EXO + Graph"
  Write-Host ""
  Stop-Transcript
  exit 0
}

#----------------------------------------------------------------------
# 結果格納
#----------------------------------------------------------------------
$results = @{
  Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
  Hostname = $env:COMPUTERNAME
  User = $env:USERNAME
  Checks = @{}
  OverallStatus = "PASS"
  Errors = @()
  Warnings = @()
}

function Add-CheckResult {
  param(
    [string]$Category,
    [string]$CheckName,
    [string]$Status,  # PASS, FAIL, WARN, SKIP
    [string]$Message,
    [object]$Details = $null
  )
  
  if (-not $results.Checks.ContainsKey($Category)) {
    $results.Checks[$Category] = @()
  }
  
  $check = @{
    Name = $CheckName
    Status = $Status
    Message = $Message
    Details = $Details
  }
  $results.Checks[$Category] += $check
  
  # 出力
  $icon = switch ($Status) {
    "PASS" { "✓" }
    "FAIL" { "✗" }
    "WARN" { "⚠" }
    "SKIP" { "-" }
    default { "?" }
  }
  $color = switch ($Status) {
    "PASS" { "Green" }
    "FAIL" { "Red" }
    "WARN" { "Yellow" }
    default { "Gray" }
  }
  
  Write-Host "  [$icon] $CheckName" -ForegroundColor $color
  if ($Message) {
    Write-Host "      → $Message"
  }
  
  # 全体ステータス更新
  if ($Status -eq "FAIL") {
    $results.OverallStatus = "FAIL"
    $results.Errors += "${Category}/${CheckName}: $Message"
  }
  if ($Status -eq "WARN") {
    $results.Warnings += "${Category}/${CheckName}: $Message"
  }
}

#======================================================================
# AD チェック
#======================================================================
if ($CheckAD) {
  Write-Host ""
  Write-Host "=== Active Directory チェック ===" -ForegroundColor Cyan
  
  # ADモジュールの確認
  try {
    Import-Module ActiveDirectory -ErrorAction Stop
    Add-CheckResult -Category "AD" -CheckName "ADモジュール" -Status "PASS" -Message "ActiveDirectoryモジュールが利用可能"
  } catch {
    Add-CheckResult -Category "AD" -CheckName "ADモジュール" -Status "FAIL" -Message "ActiveDirectoryモジュールがインストールされていません。RSAT-AD-PowerShellをインストールしてください。"
  }
  
  # ドメイン接続
  try {
    $domain = Get-ADDomain -ErrorAction Stop
    Add-CheckResult -Category "AD" -CheckName "ドメイン接続" -Status "PASS" -Message "ドメイン: $($domain.DNSRoot)" -Details @{ DomainDNSRoot = $domain.DNSRoot; DomainMode = $domain.DomainMode }
  } catch {
    Add-CheckResult -Category "AD" -CheckName "ドメイン接続" -Status "FAIL" -Message "ADドメインに接続できません: $($_.Exception.Message)"
  }
  
  # フォレスト情報
  try {
    $forest = Get-ADForest -ErrorAction Stop
    Add-CheckResult -Category "AD" -CheckName "フォレスト接続" -Status "PASS" -Message "フォレスト: $($forest.Name)" -Details @{ 
      ForestName = $forest.Name
      ForestMode = $forest.ForestMode
      SchemaMaster = $forest.SchemaMaster
      DomainNamingMaster = $forest.DomainNamingMaster
    }
    
    # Schema Master確認
    $localFqdn = try { ([System.Net.Dns]::GetHostEntry($env:COMPUTERNAME)).HostName } catch { $env:COMPUTERNAME }
    $isSchemamaster = ($forest.SchemaMaster -eq $localFqdn)
    if ($isSchemamaster) {
      Add-CheckResult -Category "AD" -CheckName "Schema Master" -Status "PASS" -Message "このマシンはSchema Masterです"
    } else {
      Add-CheckResult -Category "AD" -CheckName "Schema Master" -Status "WARN" -Message "Schema Masterは $($forest.SchemaMaster) です（スキーマ拡張はそちらで実行）"
    }
  } catch {
    Add-CheckResult -Category "AD" -CheckName "フォレスト接続" -Status "FAIL" -Message "ADフォレストに接続できません: $($_.Exception.Message)"
  }
  
  # 権限チェック
  try {
    $schemaAdmins = Get-ADGroup -LDAPFilter "(cn=Schema Admins)" -ErrorAction Stop
    $enterpriseAdmins = Get-ADGroup -LDAPFilter "(cn=Enterprise Admins)" -ErrorAction Stop
    $domainAdmins = Get-ADGroup -LDAPFilter "(cn=Domain Admins)" -ErrorAction Stop
    
    $inSchema = Get-ADGroupMember $schemaAdmins -Recursive -ErrorAction SilentlyContinue | Where-Object { $_.SamAccountName -eq $env:USERNAME }
    $inEnt = Get-ADGroupMember $enterpriseAdmins -Recursive -ErrorAction SilentlyContinue | Where-Object { $_.SamAccountName -eq $env:USERNAME }
    $inDomain = Get-ADGroupMember $domainAdmins -Recursive -ErrorAction SilentlyContinue | Where-Object { $_.SamAccountName -eq $env:USERNAME }
    
    if ($inSchema) {
      Add-CheckResult -Category "AD" -CheckName "Schema Admins" -Status "PASS" -Message "Schema Adminsグループのメンバーです"
    } else {
      Add-CheckResult -Category "AD" -CheckName "Schema Admins" -Status "WARN" -Message "Schema Adminsグループのメンバーではありません（スキーマ拡張には必要）"
    }
    
    if ($inEnt) {
      Add-CheckResult -Category "AD" -CheckName "Enterprise Admins" -Status "PASS" -Message "Enterprise Adminsグループのメンバーです"
    } else {
      Add-CheckResult -Category "AD" -CheckName "Enterprise Admins" -Status "WARN" -Message "Enterprise Adminsグループのメンバーではありません（スキーマ拡張には必要）"
    }
    
    if ($inDomain) {
      Add-CheckResult -Category "AD" -CheckName "Domain Admins" -Status "PASS" -Message "Domain Adminsグループのメンバーです"
    } else {
      Add-CheckResult -Category "AD" -CheckName "Domain Admins" -Status "WARN" -Message "Domain Adminsグループのメンバーではありません"
    }
  } catch {
    Add-CheckResult -Category "AD" -CheckName "権限チェック" -Status "FAIL" -Message "権限チェックに失敗: $($_.Exception.Message)"
  }
  
  # Exchangeスキーマバージョン
  try {
    $rootDSE = Get-ADRootDSE
    $schemaNC = $rootDSE.schemaNamingContext
    
    try {
      $msExchSchema = Get-ADObject "CN=ms-Exch-Schema-Version-Pt,$schemaNC" -Properties rangeUpper -ErrorAction Stop
      $exchVersion = $msExchSchema.rangeUpper
      Add-CheckResult -Category "AD" -CheckName "Exchangeスキーマ" -Status "PASS" -Message "Exchangeスキーマ拡張済み（バージョン: $exchVersion）" -Details @{ ExchangeSchemaVersion = $exchVersion }
    } catch {
      Add-CheckResult -Category "AD" -CheckName "Exchangeスキーマ" -Status "WARN" -Message "Exchangeスキーマ未拡張（移行前に拡張が必要）"
    }
  } catch {
    Add-CheckResult -Category "AD" -CheckName "Exchangeスキーマ" -Status "SKIP" -Message "スキーマ確認をスキップ"
  }
}

#======================================================================
# EXO チェック
#======================================================================
if ($CheckEXO) {
  Write-Host ""
  Write-Host "=== Exchange Online チェック ===" -ForegroundColor Cyan
  
  # EXOモジュールの確認
  $exoModule = Get-Module -Name ExchangeOnlineManagement -ListAvailable
  if ($exoModule) {
    $ver = ($exoModule | Sort-Object Version -Descending | Select-Object -First 1).Version
    Add-CheckResult -Category "EXO" -CheckName "EXOモジュール" -Status "PASS" -Message "ExchangeOnlineManagement v$ver" -Details @{ Version = $ver.ToString() }
  } else {
    Add-CheckResult -Category "EXO" -CheckName "EXOモジュール" -Status "FAIL" -Message "ExchangeOnlineManagementモジュールがインストールされていません"
  }
  
  # EXO接続状態
  try {
    Import-Module ExchangeOnlineManagement -ErrorAction Stop
    $org = Get-OrganizationConfig -ErrorAction Stop
    Add-CheckResult -Category "EXO" -CheckName "EXO接続" -Status "PASS" -Message "接続済み: $($org.Name)" -Details @{ OrganizationName = $org.Name }
    
    # 権限チェック（簡易）
    try {
      $acceptedDomains = Get-AcceptedDomain -ErrorAction Stop
      Add-CheckResult -Category "EXO" -CheckName "EXO権限" -Status "PASS" -Message "AcceptedDomain取得可能（$($acceptedDomains.Count) ドメイン）"
    } catch {
      Add-CheckResult -Category "EXO" -CheckName "EXO権限" -Status "WARN" -Message "AcceptedDomain取得不可（権限不足の可能性）"
    }
    
    # コネクタ作成権限チェック
    try {
      $connectors = Get-OutboundConnector -ErrorAction Stop
      Add-CheckResult -Category "EXO" -CheckName "コネクタ管理" -Status "PASS" -Message "OutboundConnector参照可能（$($connectors.Count) 件）"
    } catch {
      Add-CheckResult -Category "EXO" -CheckName "コネクタ管理" -Status "WARN" -Message "OutboundConnector参照不可（権限不足の可能性）"
    }
    
  } catch {
    Add-CheckResult -Category "EXO" -CheckName "EXO接続" -Status "FAIL" -Message "EXOに接続されていません。Connect-ExchangeOnlineを実行してください。"
  }
}

#======================================================================
# Graph チェック
#======================================================================
if ($CheckGraph) {
  Write-Host ""
  Write-Host "=== Microsoft Graph チェック ===" -ForegroundColor Cyan
  
  # Graphモジュールの確認
  $graphModule = Get-Module -Name Microsoft.Graph.Authentication -ListAvailable
  if ($graphModule) {
    $ver = ($graphModule | Sort-Object Version -Descending | Select-Object -First 1).Version
    Add-CheckResult -Category "Graph" -CheckName "Graphモジュール" -Status "PASS" -Message "Microsoft.Graph.Authentication v$ver" -Details @{ Version = $ver.ToString() }
  } else {
    Add-CheckResult -Category "Graph" -CheckName "Graphモジュール" -Status "FAIL" -Message "Microsoft.Graphモジュールがインストールされていません"
  }
  
  # Graph接続状態
  try {
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $context = Get-MgContext -ErrorAction Stop
    if ($context) {
      Add-CheckResult -Category "Graph" -CheckName "Graph接続" -Status "PASS" -Message "接続済み: $($context.Account)" -Details @{ 
        Account = $context.Account
        TenantId = $context.TenantId
        Scopes = $context.Scopes -join ","
      }
      
      # 必要スコープの確認
      $requiredScopes = @("User.Read.All", "Directory.Read.All", "Organization.Read.All")
      $currentScopes = $context.Scopes
      $missingScopes = $requiredScopes | Where-Object { $_ -notin $currentScopes }
      
      if ($missingScopes.Count -eq 0) {
        Add-CheckResult -Category "Graph" -CheckName "Graphスコープ" -Status "PASS" -Message "必要なスコープが付与されています"
      } else {
        Add-CheckResult -Category "Graph" -CheckName "Graphスコープ" -Status "WARN" -Message "不足スコープ: $($missingScopes -join ', ')"
      }
    } else {
      Add-CheckResult -Category "Graph" -CheckName "Graph接続" -Status "FAIL" -Message "Graphに接続されていません。Connect-MgGraphを実行してください。"
    }
  } catch {
    Add-CheckResult -Category "Graph" -CheckName "Graph接続" -Status "FAIL" -Message "Graph接続確認に失敗: $($_.Exception.Message)"
  }
}

#======================================================================
# ネットワーク チェック
#======================================================================
if ($CheckNetwork) {
  Write-Host ""
  Write-Host "=== ネットワーク チェック ===" -ForegroundColor Cyan
  
  $endpoints = @(
    @{ Name = "EXO PowerShell"; Host = "outlook.office365.com"; Port = 443 },
    @{ Name = "Graph API"; Host = "graph.microsoft.com"; Port = 443 },
    @{ Name = "Azure AD Login"; Host = "login.microsoftonline.com"; Port = 443 },
    @{ Name = "EXO Mail Routing"; Host = "mail.protection.outlook.com"; Port = 25 }
  )
  
  foreach ($ep in $endpoints) {
    try {
      $tcpClient = New-Object System.Net.Sockets.TcpClient
      $connect = $tcpClient.BeginConnect($ep.Host, $ep.Port, $null, $null)
      $wait = $connect.AsyncWaitHandle.WaitOne(3000, $false)
      
      if ($wait) {
        try { $tcpClient.EndConnect($connect) } catch {}
        Add-CheckResult -Category "Network" -CheckName $ep.Name -Status "PASS" -Message "$($ep.Host):$($ep.Port) に接続可能"
      } else {
        Add-CheckResult -Category "Network" -CheckName $ep.Name -Status "FAIL" -Message "$($ep.Host):$($ep.Port) に接続できません（タイムアウト）"
      }
      $tcpClient.Close()
    } catch {
      Add-CheckResult -Category "Network" -CheckName $ep.Name -Status "FAIL" -Message "$($ep.Host):$($ep.Port) に接続できません: $($_.Exception.Message)"
    }
  }
}

#======================================================================
# 結果出力
#======================================================================
Write-Host ""
Write-Host "=== チェック結果サマリー ===" -ForegroundColor Cyan

# JSON出力
$results | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "prereq_check_results.json") -Encoding UTF8

# サマリー作成
$summary = @"
#===============================================================================
# EXO移行 前提条件チェック結果
#===============================================================================

【実行日時】$($results.Timestamp)
【実行ホスト】$($results.Hostname)
【実行ユーザー】$($results.User)

【総合判定】$($results.OverallStatus)

"@

foreach ($category in $results.Checks.Keys) {
  $summary += "`n【$category】`n"
  foreach ($check in $results.Checks[$category]) {
    $icon = switch ($check.Status) {
      "PASS" { "✓" }
      "FAIL" { "✗" }
      "WARN" { "⚠" }
      default { "-" }
    }
    $summary += "  [$icon] $($check.Name): $($check.Message)`n"
  }
}

if ($results.Errors.Count -gt 0) {
  $summary += "`n【エラー（要対応）】`n"
  foreach ($err in $results.Errors) {
    $summary += "  ✗ $err`n"
  }
}

if ($results.Warnings.Count -gt 0) {
  $summary += "`n【警告（確認推奨）】`n"
  foreach ($warn in $results.Warnings) {
    $summary += "  ⚠ $warn`n"
  }
}

$summary += @"

#-------------------------------------------------------------------------------
# 次のステップ
#-------------------------------------------------------------------------------

"@

if ($results.OverallStatus -eq "PASS") {
  $summary += "  ✓ 全てのチェックがPASSしました。次のフェーズに進めます。`n"
} else {
  $summary += "  ✗ エラーがあります。上記の問題を解消してから次のフェーズに進んでください。`n"
}

$summary | Out-File (Join-Path $OutDir "prereq_check_summary.txt") -Encoding UTF8

Write-Host ""
Write-Host "============================================================"
Write-Host " 完了"
Write-Host "============================================================"
Write-Host $summary

Stop-Transcript
Write-Host ""
Write-Host "出力先: $OutDir"

# 終了コード
if ($results.OverallStatus -eq "PASS") { exit 0 } else { exit 1 }
