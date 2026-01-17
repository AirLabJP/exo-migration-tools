<#
.SYNOPSIS
  複数ドメインのDNSレコード一括取得スクリプト

.DESCRIPTION
  40ドメイン等の複数ドメインに対して、MX/SPF/DKIM/DMARCを一括取得します。
  外部DNS（公開情報）を取得するため、どこからでも実行可能です。

  【収集する情報】
  - MXレコード（メール受信先）
  - SPFレコード（送信者認証）
  - DMARCレコード（認証ポリシー）
  - DKIMレコード（署名検証）

  【出力ファイルと確認ポイント】
  dns_records.csv      ← ★重要: 全ドメインのDNSレコード一覧
  domains_no_spf.txt   ← SPFが未設定のドメイン
  domains_no_dmarc.txt ← DMARCが未設定のドメイン
  summary.txt          ← 統計サマリー

.PARAMETER DomainsFile
  ドメイン一覧ファイルパス（1行1ドメイン、#でコメント）

.PARAMETER Domains
  ドメイン配列（直接指定する場合）

.PARAMETER DkimSelectors
  DKIMセレクタ配列（デフォルト: selector1, selector2, google, default, dkim）

.PARAMETER OutRoot
  出力先ルートフォルダ

.PARAMETER DnsServer
  使用するDNSサーバー（省略時はシステムデフォルト）

.EXAMPLE
  # ファイルから読み込み
  .\Collect-DNSRecords.ps1 -DomainsFile domains.txt -OutRoot C:\temp\inventory

.EXAMPLE
  # 配列で直接指定
  .\Collect-DNSRecords.ps1 -Domains @("example.co.jp","example.com")
#>
param(
  [string]$DomainsFile,
  [string[]]$Domains,
  [string[]]$DkimSelectors = @("selector1","selector2","google","default","dkim"),
  [string]$OutRoot = ".\inventory",
  [string]$Tag = (Get-Date -Format "yyyyMMdd_HHmmss"),
  [string]$DnsServer
)

# 出力先フォルダ作成
$OutDir = Join-Path $OutRoot ("dns_" + $Tag)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Start-Transcript -Path (Join-Path $OutDir "run.log") -Force

Write-Host "============================================================"
Write-Host " DNS レコード一括取得"
Write-Host "============================================================"
Write-Host "出力先: $OutDir"
Write-Host ""

#----------------------------------------------------------------------
# ドメインリストの読み込み
#----------------------------------------------------------------------
if ($DomainsFile -and (Test-Path $DomainsFile)) {
  $domainList = Get-Content $DomainsFile | Where-Object { $_ -and $_ -notmatch '^\s*#' }
  Write-Host "ドメインファイル: $DomainsFile"
} elseif ($Domains) {
  $domainList = $Domains
} else {
  throw "エラー: -DomainsFile または -Domains を指定してください"
}

Write-Host "対象ドメイン数: $($domainList.Count)"
Write-Host "DKIMセレクタ: $($DkimSelectors -join ', ')"
Write-Host ""

#----------------------------------------------------------------------
# DNS取得処理
#----------------------------------------------------------------------
Write-Host "[処理中] DNSレコードを取得しています..."
Write-Host ""

$results = New-Object System.Collections.Generic.List[object]
$current = 0

foreach ($domain in $domainList) {
  $domain = $domain.Trim()
  if (-not $domain) { continue }
  
  $current++
  Write-Host "  [$current/$($domainList.Count)] $domain"
  
  $record = [PSCustomObject]@{
    ドメイン = $domain
    MX = ""
    MX優先度 = ""
    SPF = ""
    DMARC = ""
    DKIMセレクタ = ""
    DKIM = ""
    エラー = ""
  }
  
  $errors = @()
  
  # MXレコード
  try {
    $resolveParams = @{ Name = $domain; Type = "MX"; ErrorAction = "Stop" }
    if ($DnsServer) { $resolveParams.Server = $DnsServer }
    
    $mx = Resolve-DnsName @resolveParams
    $mxRecords = $mx | Where-Object { $_.Type -eq "MX" } | Sort-Object Preference
    $record.MX = ($mxRecords.NameExchange -join "; ")
    $record.MX優先度 = ($mxRecords.Preference -join "; ")
  } catch {
    $errors += "MX: $($_.Exception.Message)"
  }
  
  # SPFレコード（TXTレコード内のv=spf1）
  try {
    $resolveParams = @{ Name = $domain; Type = "TXT"; ErrorAction = "Stop" }
    if ($DnsServer) { $resolveParams.Server = $DnsServer }
    
    $txt = Resolve-DnsName @resolveParams
    $spf = $txt | Where-Object { $_.Strings -match "v=spf1" }
    if ($spf) {
      $record.SPF = ($spf.Strings -join "")
    }
  } catch {
    $errors += "SPF: $($_.Exception.Message)"
  }
  
  # DMARCレコード（_dmarc.domain）
  try {
    $dmarcDomain = "_dmarc.$domain"
    $resolveParams = @{ Name = $dmarcDomain; Type = "TXT"; ErrorAction = "Stop" }
    if ($DnsServer) { $resolveParams.Server = $DnsServer }
    
    $dmarc = Resolve-DnsName @resolveParams
    $dmarcRecord = $dmarc | Where-Object { $_.Strings -match "v=DMARC1" }
    if ($dmarcRecord) {
      $record.DMARC = ($dmarcRecord.Strings -join "")
    }
  } catch {
    # DMARCはオプションなのでエラーにしない
  }
  
  # DKIMレコード（複数セレクタを試行）
  foreach ($selector in $DkimSelectors) {
    try {
      $dkimDomain = "$selector._domainkey.$domain"
      $resolveParams = @{ Name = $dkimDomain; Type = "TXT"; ErrorAction = "Stop" }
      if ($DnsServer) { $resolveParams.Server = $DnsServer }
      
      $dkim = Resolve-DnsName @resolveParams
      $dkimRecord = $dkim | Where-Object { $_.Strings -match "v=DKIM1" -or $_.Strings -match "k=rsa" }
      if ($dkimRecord) {
        $record.DKIMセレクタ = $selector
        $record.DKIM = ($dkimRecord.Strings -join "")
        break  # 見つかったら終了
      }
    } catch {
      # DKIMセレクタが見つからない場合は次を試す
    }
  }
  
  if ($errors.Count -gt 0) {
    $record.エラー = ($errors -join "; ")
  }
  
  $results.Add($record)
}

#----------------------------------------------------------------------
# 結果出力
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[出力中] 結果をファイルに保存しています..."

$results | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "dns_records.csv")

# SPF/DMARC未設定ドメインを抽出
$noSpf = $results | Where-Object { -not $_.SPF }
$noDmarc = $results | Where-Object { -not $_.DMARC }

if ($noSpf.Count -gt 0) {
  $noSpf.ドメイン | Out-File (Join-Path $OutDir "domains_no_spf.txt") -Encoding UTF8
}

if ($noDmarc.Count -gt 0) {
  $noDmarc.ドメイン | Out-File (Join-Path $OutDir "domains_no_dmarc.txt") -Encoding UTF8
}

#----------------------------------------------------------------------
# サマリー作成
#----------------------------------------------------------------------
$summary = @"
#===============================================================================
# DNS レコード取得サマリー
#===============================================================================

【対象ドメイン】 $($results.Count)

【取得結果】
  MXあり:    $(($results | Where-Object { $_.MX }).Count)
  SPFあり:   $(($results | Where-Object { $_.SPF }).Count)
  DMARCあり: $(($results | Where-Object { $_.DMARC }).Count)
  DKIMあり:  $(($results | Where-Object { $_.DKIM }).Count)
  エラー:    $(($results | Where-Object { $_.エラー }).Count)

【注意が必要なドメイン】
  SPF未設定:   $($noSpf.Count) 件 → domains_no_spf.txt
  DMARC未設定: $($noDmarc.Count) 件 → domains_no_dmarc.txt

#-------------------------------------------------------------------------------
# 確認すべきファイル
#-------------------------------------------------------------------------------

  ★ dns_records.csv
     → 全ドメインのDNSレコード一覧
     → MX列でメール受信先を確認
     → EXO移行後はMXを *.mail.protection.outlook.com に変更

  ★ domains_no_spf.txt / domains_no_dmarc.txt
     → 認証設定が未設定のドメイン
     → 移行を機に設定することを推奨

#-------------------------------------------------------------------------------
# EXO移行時のDNS変更
#-------------------------------------------------------------------------------

  【MXレコード】
  移行後: <tenant>.mail.protection.outlook.com
  優先度: 0 または 10

  【SPFレコード】
  追加: include:spf.protection.outlook.com

  【DKIMレコード】
  EXO管理画面でDKIM署名を有効化後、CNAMEを設定

"@

$summary | Out-File (Join-Path $OutDir "summary.txt") -Encoding UTF8

Write-Host ""
Write-Host "============================================================"
Write-Host " 完了"
Write-Host "============================================================"
Write-Host $summary

if ($noSpf.Count -gt 0) {
  Write-Host ""
  Write-Host "【SPF未設定ドメイン】"
  $noSpf.ドメイン | ForEach-Object { Write-Host "  - $_" }
}

Stop-Transcript
Write-Host ""
Write-Host "出力先: $OutDir"
