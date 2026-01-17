<#
.SYNOPSIS
  Exchange AD スキーマ拡張スクリプト

.DESCRIPTION
  Exchange用のADスキーマ拡張とAD準備を安全に実行します。
  Schema Master DCで実行してください。

  【実行内容】
  1. 権限チェック（Schema Admins / Enterprise Admins）
  2. Schema Master確認（このDCで実行しているか）
  3. /PrepareSchema → /PrepareAD → /PrepareAllDomains（任意）
  4. レプリケーション強制実行
  5. スキーマバージョンの事前/事後比較

  【出力ファイル】
  schema_version_before.json ← 実行前のスキーマバージョン
  schema_version_after.json  ← 実行後のスキーマバージョン
  schema_version_comparison.txt ← 比較結果
  01_PrepareSchema_cmd.txt   ← 実行コマンドと結果
  02_PrepareAD_cmd.txt       ← 実行コマンドと結果
  repadmin_syncall_*.txt     ← レプリケーション結果

.PARAMETER SetupExePath
  Exchange Setup.exe のパス（例: D:\ExchangeSetup\Setup.exe）

.PARAMETER OrganizationName
  Exchange Organization名（例: Contoso）

.PARAMETER OutRoot
  出力先ルートフォルダ

.PARAMETER PrepareAllDomains
  全ドメインの /PrepareAllDomains を実行するか

.PARAMETER LicenseSwitch
  ライセンス同意スイッチ（DiagnosticDataON or DiagnosticDataOFF）

.EXAMPLE
  .\Invoke-ExchangeSchemaPrep.ps1 `
    -SetupExePath D:\ExchangeSetup\Setup.exe `
    -OrganizationName "Contoso"

.NOTES
  - Schema Master DCで実行すること
  - Schema Admins + Enterprise Admins権限が必要
  - 実行前に必ずADバックアップを取得
#>
param(
  [Parameter(Mandatory=$true)]
  [string]$SetupExePath,

  [Parameter(Mandatory=$true)]
  [string]$OrganizationName,

  [string]$OutRoot = ".\inventory",

  [switch]$PrepareAllDomains,

  [ValidateSet("DiagnosticDataON","DiagnosticDataOFF")]
  [string]$LicenseSwitch = "DiagnosticDataON"
)

#----------------------------------------------------------------------
# ヘルパー関数
#----------------------------------------------------------------------
function New-OutDir {
  param([string]$Root, [string]$Prefix)
  $ts = Get-Date -Format "yyyyMMdd_HHmmss"
  $dir = Join-Path $Root ("{0}_{1}" -f $Prefix, $ts)
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  return $dir
}

function Assert-FileExists([string]$Path) {
  if (-not (Test-Path $Path)) { throw "ファイルが見つかりません: $Path" }
}

function Assert-RequiredPrivileges {
  Import-Module ActiveDirectory
  
  $me = (whoami)
  Write-Host "      → 実行ユーザー: $me"
  
  $schemaAdmins = Get-ADGroup -LDAPFilter "(cn=Schema Admins)" -ErrorAction Stop
  $enterpriseAdmins = Get-ADGroup -LDAPFilter "(cn=Enterprise Admins)" -ErrorAction Stop
  
  $inSchema = Get-ADGroupMember $schemaAdmins -Recursive | Where-Object { $_.SamAccountName -eq $env:USERNAME }
  $inEnt = Get-ADGroupMember $enterpriseAdmins -Recursive | Where-Object { $_.SamAccountName -eq $env:USERNAME }
  
  if (-not $inSchema) { throw "エラー: 'Schema Admins' グループのメンバーではありません。追加して再ログオンしてください。" }
  if (-not $inEnt) { throw "エラー: 'Enterprise Admins' グループのメンバーではありません。追加して再ログオンしてください。" }
  
  Write-Host "      → 権限OK: Schema Admins / Enterprise Admins"
}

function Get-SchemaMasterDc {
  Import-Module ActiveDirectory
  $forest = Get-ADForest
  return $forest.SchemaMaster
}

function Get-SchemaVersion {
  $rootDSE = Get-ADRootDSE
  $schemaNC = $rootDSE.schemaNamingContext
  
  $result = @{
    ADSchemaVersion = (Get-ADObject $schemaNC -Properties objectVersion).objectVersion
    ExchangeSchemaVersion = $null
  }
  
  try {
    $msExchSchema = Get-ADObject "CN=ms-Exch-Schema-Version-Pt,$schemaNC" -Properties rangeUpper -ErrorAction Stop
    $result.ExchangeSchemaVersion = $msExchSchema.rangeUpper
  } catch {
    $result.ExchangeSchemaVersion = "未拡張"
  }
  
  return $result
}

function Invoke-Setup([string]$SetupExe, [string[]]$Args, [string]$LogFile) {
  $argLine = $Args -join " "
  Write-Host "      → 実行: `"$SetupExe`" $argLine"
  $p = Start-Process -FilePath $SetupExe -ArgumentList $Args -Wait -PassThru -NoNewWindow
  $exit = $p.ExitCode
  "EXITCODE=$exit`r`nCMD=`"$SetupExe`" $argLine" | Out-File -FilePath $LogFile -Encoding UTF8
  if ($exit -ne 0) { throw "Setup.exe が失敗しました（ExitCode=$exit）。$LogFile および C:\ExchangeSetupLogs を確認してください。" }
}

function Force-Replication([string]$OutDir, [int]$Attempt) {
  $repLog = Join-Path $OutDir "repadmin_syncall_$Attempt.txt"
  Write-Host "      → レプリケーション強制実行中..."
  & repadmin /syncall /AdeP | Out-File $repLog -Encoding UTF8
  Start-Sleep -Seconds 10
}

function Save-Basics([string]$OutDir) {
  & hostname | Out-File (Join-Path $OutDir "hostname.txt") -Encoding UTF8
  & whoami /all | Out-File (Join-Path $OutDir "whoami_all.txt") -Encoding UTF8
  & netdom query fsmo | Out-File (Join-Path $OutDir "fsmo.txt") -Encoding UTF8
  & dcdiag /test:replications | Out-File (Join-Path $OutDir "dcdiag_replications.txt") -Encoding UTF8
}

#----------------------------------------------------------------------
# メイン処理
#----------------------------------------------------------------------
Assert-FileExists $SetupExePath

$OutDir = New-OutDir -Root $OutRoot -Prefix "exchange_schema_prep"
Start-Transcript -Path (Join-Path $OutDir "run.log") -Force

try {
  Import-Module ActiveDirectory
  
  Write-Host "============================================================"
  Write-Host " Exchange AD スキーマ拡張"
  Write-Host "============================================================"
  Write-Host "Setup.exe:     $SetupExePath"
  Write-Host "Organization:  $OrganizationName"
  Write-Host "出力先:        $OutDir"
  Write-Host ""
  
  #----------------------------------------------------------------------
  # 事前チェック
  #----------------------------------------------------------------------
  Write-Host "[1/6] 事前チェック..."
  Save-Basics -OutDir $OutDir
  Assert-RequiredPrivileges
  
  $schemaMaster = Get-SchemaMasterDc
  $localFqdn = ([System.Net.Dns]::GetHostEntry($env:COMPUTERNAME)).HostName
  
  Write-Host ""
  Write-Host "      → Schema Master: $schemaMaster"
  Write-Host "      → このホスト:    $localFqdn"
  
  if ($schemaMaster -ne $localFqdn) {
    throw "エラー: このマシンはSchema Masterではありません。Schema Master DC ($schemaMaster) で実行するか、FSMOロールを移動してください。"
  }
  Write-Host "      → OK: このマシンはSchema Masterです"
  
  #----------------------------------------------------------------------
  # スキーマバージョン（実行前）
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[2/6] スキーマバージョン（実行前）を取得..."
  $versionBefore = Get-SchemaVersion
  Write-Host "      → ADスキーマ:       $($versionBefore.ADSchemaVersion)"
  Write-Host "      → Exchangeスキーマ: $($versionBefore.ExchangeSchemaVersion)"
  $versionBefore | ConvertTo-Json | Out-File (Join-Path $OutDir "schema_version_before.json") -Encoding UTF8
  
  # ライセンススイッチ
  $license = "/IAcceptExchangeServerLicenseTerms_$LicenseSwitch"
  
  #----------------------------------------------------------------------
  # PrepareSchema
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[3/6] PrepareSchema を実行中..."
  Write-Host "      → ADスキーマにExchange属性を追加します"
  Invoke-Setup -SetupExe $SetupExePath `
    -Args @($license, "/PrepareSchema") `
    -LogFile (Join-Path $OutDir "01_PrepareSchema_cmd.txt")
  
  Force-Replication -OutDir $OutDir -Attempt 1
  
  #----------------------------------------------------------------------
  # PrepareAD
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[4/6] PrepareAD を実行中..."
  Write-Host "      → Exchange組織とコンテナを作成します"
  Invoke-Setup -SetupExe $SetupExePath `
    -Args @($license, "/PrepareAD", "/OrganizationName:`"$OrganizationName`"") `
    -LogFile (Join-Path $OutDir "02_PrepareAD_cmd.txt")
  
  Force-Replication -OutDir $OutDir -Attempt 2
  
  #----------------------------------------------------------------------
  # PrepareAllDomains（オプション）
  #----------------------------------------------------------------------
  if ($PrepareAllDomains) {
    Write-Host ""
    Write-Host "[5/6] PrepareAllDomains を実行中..."
    Write-Host "      → 全ドメインにExchange関連オブジェクトを作成します"
    Invoke-Setup -SetupExe $SetupExePath `
      -Args @($license, "/PrepareAllDomains") `
      -LogFile (Join-Path $OutDir "03_PrepareAllDomains_cmd.txt")
    
    Force-Replication -OutDir $OutDir -Attempt 3
  } else {
    Write-Host ""
    Write-Host "[5/6] PrepareAllDomains をスキップ（-PrepareAllDomains オプションなし）"
  }
  
  #----------------------------------------------------------------------
  # スキーマバージョン（実行後）
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[6/6] スキーマバージョン（実行後）を取得..."
  $versionAfter = Get-SchemaVersion
  Write-Host "      → ADスキーマ:       $($versionAfter.ADSchemaVersion)"
  Write-Host "      → Exchangeスキーマ: $($versionAfter.ExchangeSchemaVersion)"
  $versionAfter | ConvertTo-Json | Out-File (Join-Path $OutDir "schema_version_after.json") -Encoding UTF8
  
  #----------------------------------------------------------------------
  # 比較結果
  #----------------------------------------------------------------------
  $comparison = @"
#===============================================================================
# スキーマバージョン比較
#===============================================================================

【実行前】
  ADスキーマ:       $($versionBefore.ADSchemaVersion)
  Exchangeスキーマ: $($versionBefore.ExchangeSchemaVersion)

【実行後】
  ADスキーマ:       $($versionAfter.ADSchemaVersion)
  Exchangeスキーマ: $($versionAfter.ExchangeSchemaVersion)

【参考：Exchangeスキーマバージョン】
  Exchange 2016 CU23: 15334
  Exchange 2019 CU14: 17003

"@
  
  $comparison | Out-File (Join-Path $OutDir "schema_version_comparison.txt") -Encoding UTF8
  
  # 最終レプリケーションチェック
  Write-Host ""
  Write-Host "最終レプリケーションチェック..."
  & dcdiag /test:replications | Out-File (Join-Path $OutDir "dcdiag_replications_final.txt") -Encoding UTF8
  
  Write-Host ""
  Write-Host "============================================================"
  Write-Host " 完了"
  Write-Host "============================================================"
  Write-Host $comparison
  Write-Host ""
  Write-Host "【次のステップ】"
  Write-Host "  1. レプリケーションが完了するまで待機（数分〜数十分）"
  Write-Host "  2. dcdiag /test:replications で確認"
  Write-Host "  3. メール属性投入（Set-ADMailAddressesFromCsv.ps1）"
  Write-Host ""
  Write-Host "【参考】Exchange setup logs: C:\ExchangeSetupLogs"
}
catch {
  Write-Error $_
  throw
}
finally {
  Stop-Transcript
}

Write-Host ""
Write-Host "出力先: $OutDir"
