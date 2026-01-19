<#
.SYNOPSIS
  複数ドメインのDNSレコード一括取得スクリプト

.DESCRIPTION
  40ドメイン等の複数ドメインに対して、MX/SPF/DKIM/DMARC/TLS-RPT/MTA-STS/BIMIを一括取得します。
  外部DNS（公開情報）を取得するため、どこからでも実行可能です。

  【収集する情報】
  - MXレコード（メール受信先）
  - SPFレコード（送信者認証）
  - DMARCレコード（認証ポリシー）
  - DKIMレコード（署名検証）
  - TLS-RPTレコード（TLS配送レポート）
  - MTA-STSレコード（厳格TLS送信）
  - BIMIレコード（ブランドロゴ）
  - 弱点フラグ（セキュリティ上の問題を自動検出）

  【出力ファイルと確認ポイント】
  dns_records.csv         ← ★重要: 全ドメインのDNSレコード一覧（要約・人が読む用）
  dns_records.json        ← 詳細データ（機械可読）
  dns_records.xml         ← 詳細データ（PowerShell互換）
  domains_no_spf.txt      ← SPFが未設定のドメイン
  domains_no_dmarc.txt    ← DMARCが未設定のドメイン
  domains_with_issues.csv ← ★重要: 弱点フラグが付いたドメイン
  summary.txt             ← 統計サマリー

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

# エラーアクションの設定
$ErrorActionPreference = "Stop"

# 出力先フォルダ作成
$OutDir = Join-Path $OutRoot ("dns_" + $Tag)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# グローバル変数（finally句で参照）
$transcriptStarted = $false
$results = $null
$domainList = $null

try {
  # トランスクリプト開始
  Start-Transcript -Path (Join-Path $OutDir "run.log") -Force
  $transcriptStarted = $true

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
      TLSRPT = ""
      MTASTS = ""
      BIMI = ""
      弱点フラグ = ""
      エラー = ""
    }

    $errors = @()
    $issues = @()

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
      $issues += "NoMX"
    }

    # SPFレコード（TXTレコード内のv=spf1）
    try {
      $resolveParams = @{ Name = $domain; Type = "TXT"; ErrorAction = "Stop" }
      if ($DnsServer) { $resolveParams.Server = $DnsServer }

      $txt = Resolve-DnsName @resolveParams
      $spf = $txt | Where-Object { $_.Strings -match "v=spf1" }
      if ($spf) {
        $record.SPF = ($spf.Strings -join "")

        # SPF弱点チェック
        if ($record.SPF -match "~all") {
          $issues += "SPF_softfail"
        }
        if ($record.SPF -match "\?all") {
          $issues += "SPF_neutral"
        }
      } else {
        $issues += "NoSPF"
      }
    } catch {
      $errors += "SPF: $($_.Exception.Message)"
      $issues += "NoSPF"
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

        # DMARC弱点チェック
        if ($record.DMARC -match "p=none") {
          $issues += "DMARC_p_none"
        }
        if ($record.DMARC -match "pct=(\d+)" -and [int]$Matches[1] -lt 100) {
          $issues += "DMARC_pct_low"
        }
      } else {
        $issues += "NoDMARC"
      }
    } catch {
      # DMARCはオプションなのでエラーにしない
      $issues += "NoDMARC"
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

    # TLS-RPTレコード（_smtp._tls.domain）
    try {
      $tlsrptDomain = "_smtp._tls.$domain"
      $resolveParams = @{ Name = $tlsrptDomain; Type = "TXT"; ErrorAction = "Stop" }
      if ($DnsServer) { $resolveParams.Server = $DnsServer }

      $tlsrpt = Resolve-DnsName @resolveParams
      $tlsrptRecord = $tlsrpt | Where-Object { $_.Strings -match "v=TLSRPTv1" }
      if ($tlsrptRecord) {
        $record.TLSRPT = ($tlsrptRecord.Strings -join "")
      }
    } catch {
      # TLS-RPTはオプション
    }

    # MTA-STSレコード（mta-sts.domain の存在確認）
    try {
      $mtastsDomain = "mta-sts.$domain"
      $resolveParams = @{ Name = $mtastsDomain; Type = "A"; ErrorAction = "Stop" }
      if ($DnsServer) { $resolveParams.Server = $DnsServer }

      $mtasts = Resolve-DnsName @resolveParams
      if ($mtasts) {
        $record.MTASTS = "設定あり"
      }
    } catch {
      # MTA-STSはオプション
    }

    # BIMIレコード（default._bimi.domain）
    try {
      $bimiDomain = "default._bimi.$domain"
      $resolveParams = @{ Name = $bimiDomain; Type = "TXT"; ErrorAction = "Stop" }
      if ($DnsServer) { $resolveParams.Server = $DnsServer }

      $bimi = Resolve-DnsName @resolveParams
      $bimiRecord = $bimi | Where-Object { $_.Strings -match "v=BIMI1" }
      if ($bimiRecord) {
        $record.BIMI = ($bimiRecord.Strings -join "")
      }
    } catch {
      # BIMIはオプション
    }

    # 弱点フラグとエラーをまとめる
    if ($issues.Count -gt 0) {
      $record.弱点フラグ = ($issues -join "; ")
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

  # 要約CSV出力（人が読む用）
  $results | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "dns_records.csv")

  # 詳細データ出力（機械可読）
  $results | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutDir "dns_records.json") -Encoding UTF8
  $results | Export-Clixml -Path (Join-Path $OutDir "dns_records.xml") -Encoding UTF8

  # SPF/DMARC未設定ドメインを抽出
  $noSpf = $results | Where-Object { -not $_.SPF }
  $noDmarc = $results | Where-Object { -not $_.DMARC }

  if ($noSpf.Count -gt 0) {
    $noSpf.ドメイン | Out-File (Join-Path $OutDir "domains_no_spf.txt") -Encoding UTF8
  }

  if ($noDmarc.Count -gt 0) {
    $noDmarc.ドメイン | Out-File (Join-Path $OutDir "domains_no_dmarc.txt") -Encoding UTF8
  }

  # 弱点フラグが付いたドメインを抽出
  $withIssues = $results | Where-Object { $_.弱点フラグ }
  if ($withIssues.Count -gt 0) {
    $withIssues | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "domains_with_issues.csv")
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
  MXあり:       $(($results | Where-Object { $_.MX }).Count)
  SPFあり:      $(($results | Where-Object { $_.SPF }).Count)
  DMARCあり:    $(($results | Where-Object { $_.DMARC }).Count)
  DKIMあり:     $(($results | Where-Object { $_.DKIM }).Count)
  TLS-RPTあり:  $(($results | Where-Object { $_.TLSRPT }).Count)
  MTA-STSあり:  $(($results | Where-Object { $_.MTASTS }).Count)
  BIMIあり:     $(($results | Where-Object { $_.BIMI }).Count)
  エラー:       $(($results | Where-Object { $_.エラー }).Count)

【セキュリティ上の注意】
  SPF未設定:         $($noSpf.Count) 件 → domains_no_spf.txt
  DMARC未設定:       $($noDmarc.Count) 件 → domains_no_dmarc.txt
  弱点フラグあり:    $($withIssues.Count) 件 → domains_with_issues.csv

【弱点フラグの意味】
  NoMX:           MXレコードが未設定（メール受信不可）
  NoSPF:          SPFレコードが未設定（なりすまし防止なし）
  NoDMARC:        DMARCレコードが未設定（認証失敗時の扱い不明）
  DMARC_p_none:   DMARCポリシーがp=none（監視のみ、拒否なし）
  DMARC_pct_low:  DMARC適用率が100%未満（一部のみ適用）
  SPF_softfail:   SPF設定が ~all（ソフトフェイル、推奨は -all）
  SPF_neutral:    SPF設定が ?all（中立、推奨は -all）

#-------------------------------------------------------------------------------
# 確認すべきファイル
#-------------------------------------------------------------------------------

  ★ dns_records.csv
     → 全ドメインのDNSレコード一覧（要約・人が読む用）
     → MX列でメール受信先を確認
     → EXO移行後はMXを *.mail.protection.outlook.com に変更

  ★ dns_records.json / dns_records.xml
     → 詳細データ（機械可読・分析用）

  ★ domains_with_issues.csv
     → 弱点フラグが付いたドメイン
     → 移行を機にセキュリティ設定を強化することを推奨

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

  【DMARCレコード】
  推奨: p=quarantine または p=reject（段階的に移行）

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

  if ($withIssues.Count -gt 0) {
    Write-Host ""
    Write-Host "【弱点フラグが付いたドメイン】"
    $withIssues | Select-Object -First 10 | ForEach-Object {
      Write-Host "  - $($_.ドメイン): $($_.弱点フラグ)"
    }
    if ($withIssues.Count -gt 10) {
      Write-Host "  ... 他 $($withIssues.Count - 10) 件（domains_with_issues.csv を参照）"
    }
  }

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
