<#
.SYNOPSIS
  複数ドメインのDNSレコード一括取得スクリプト（強化版）

.DESCRIPTION
  40ドメイン等の複数ドメインに対して、MX/SPF/DKIM/DMARC/TLS-RPT/MTA-STS/BIMIを一括取得します。
  外部DNS（公開情報）を取得するため、どこからでも実行可能です。

  【収集する情報】
  - MXレコード（メール受信先）+ A/AAAA妥当性検証
  - SPFレコード（送信者認証）+ 品質チェック・複数定義検出
  - DMARCレコード（認証ポリシー）+ rua/pct解析
  - DKIMレコード（署名検証）+ CNAME判定
  - TLS-RPTレコード（TLS配送レポート）+ rua解析
  - MTA-STSレコード（厳格TLS送信）+ STSv1判定
  - BIMIレコード（ブランドロゴ）
  - 弱点フラグ（セキュリティ上の問題を自動検出）

  【出力ファイルと確認ポイント】
  dns_records.csv          ← ★重要: 全ドメインのDNSレコード一覧（要約・人が読む用）
  dns_records.json         ← 詳細データ（機械可読）
  dns_records.xml          ← 詳細データ（PowerShell互換）
  domains_mx_hosts.csv     ← ★重要: MXホスト一覧とA/AAAA妥当性
  domains_no_spf.txt       ← SPFが未設定のドメイン
  domains_no_dmarc.txt     ← DMARCが未設定のドメイン
  domains_with_issues.csv  ← ★重要: 弱点フラグが付いたドメイン
  summary.txt              ← 統計サマリー

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
$mxHostsResults = New-Object System.Collections.Generic.List[object]

try {
  # トランスクリプト開始
  Start-Transcript -Path (Join-Path $OutDir "run.log") -Force
  $transcriptStarted = $true

  Write-Host "============================================================"
  Write-Host " DNS レコード一括取得（強化版）"
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
      MX_A_AAAA妥当 = ""
      SPF = ""
      SPF複数定義 = ""
      SPF品質 = ""
      DMARC = ""
      DMARC複数定義 = ""
      DMARC_rua = ""
      DMARC_pct = ""
      DKIMセレクタ = ""
      DKIM = ""
      DKIM_CNAME = ""
      TLSRPT = ""
      TLSRPT_rua = ""
      MTASTS = ""
      MTASTS_STSv1 = ""
      BIMI = ""
      弱点フラグ = ""
      エラー = ""
    }

    $errors = @()
    $issues = @()

    # MXレコード + A/AAAA妥当性検証
    try {
      $resolveParams = @{ Name = $domain; Type = "MX"; ErrorAction = "Stop" }
      if ($DnsServer) { $resolveParams.Server = $DnsServer }

      $mx = Resolve-DnsName @resolveParams
      $mxRecords = $mx | Where-Object { $_.Type -eq "MX" } | Sort-Object Preference
      $record.MX = ($mxRecords.NameExchange -join "; ")
      $record.MX優先度 = ($mxRecords.Preference -join "; ")

      # MXホストのA/AAAA検証
      $mxValid = $true
      foreach ($mxHost in $mxRecords) {
        $hostName = $mxHost.NameExchange.TrimEnd('.')
        $hasA = $false
        $hasAAAA = $false
        $isCname = $false

        # CNAME禁止チェック
        try {
          $cnameParams = @{ Name = $hostName; Type = "CNAME"; ErrorAction = "SilentlyContinue" }
          if ($DnsServer) { $cnameParams.Server = $DnsServer }
          $cname = Resolve-DnsName @cnameParams
          if ($cname -and $cname.Type -eq "CNAME") {
            $isCname = $true
            $issues += "MX_CNAME_禁止($hostName)"
            $mxValid = $false
          }
        } catch { }

        # A/AAAAレコード必須チェック
        try {
          $aParams = @{ Name = $hostName; Type = "A"; ErrorAction = "SilentlyContinue" }
          if ($DnsServer) { $aParams.Server = $DnsServer }
          $aRecord = Resolve-DnsName @aParams
          if ($aRecord -and ($aRecord | Where-Object { $_.Type -eq "A" })) { $hasA = $true }
        } catch { }

        try {
          $aaaaParams = @{ Name = $hostName; Type = "AAAA"; ErrorAction = "SilentlyContinue" }
          if ($DnsServer) { $aaaaParams.Server = $DnsServer }
          $aaaaRecord = Resolve-DnsName @aaaaParams
          if ($aaaaRecord -and ($aaaaRecord | Where-Object { $_.Type -eq "AAAA" })) { $hasAAAA = $true }
        } catch { }

        if (-not $hasA -and -not $hasAAAA -and -not $isCname) {
          $issues += "MX_NoA_AAAA($hostName)"
          $mxValid = $false
        }

        # MXホスト詳細を記録
        $mxHostsResults.Add([PSCustomObject]@{
          ドメイン = $domain
          MXホスト = $hostName
          優先度 = $mxHost.Preference
          HasA = $hasA
          HasAAAA = $hasAAAA
          IsCNAME = $isCname
          妥当 = (-not $isCname -and ($hasA -or $hasAAAA))
        })
      }
      $record.MX_A_AAAA妥当 = if ($mxValid) { "OK" } else { "NG" }
    } catch {
      $errors += "MX: $($_.Exception.Message)"
      $issues += "NoMX"
    }

    # SPFレコード（TXTレコード内のv=spf1）+ 品質チェック・複数定義検出
    try {
      $resolveParams = @{ Name = $domain; Type = "TXT"; ErrorAction = "Stop" }
      if ($DnsServer) { $resolveParams.Server = $DnsServer }

      $txt = Resolve-DnsName @resolveParams
      $spfRecords = $txt | Where-Object { $_.Strings -match "v=spf1" }

      if ($spfRecords) {
        # 複数定義検出
        $spfCount = ($spfRecords | Measure-Object).Count
        if ($spfCount -gt 1) {
          $record.SPF複数定義 = "警告: $spfCount 件（最初を採用）"
          $issues += "SPF_複数定義"
        } else {
          $record.SPF複数定義 = "なし"
        }

        # 先頭一致で正規化（最初のレコードを採用）
        $spfFirst = $spfRecords | Select-Object -First 1
        $record.SPF = ($spfFirst.Strings -join "")

        # SPF品質チェック
        $spfQuality = @()

        # +all チェック（危険）
        if ($record.SPF -match "\+all") {
          $spfQuality += "+all(危険)"
          $issues += "SPF_+all"
        }
        # ~all チェック（ソフトフェイル）
        if ($record.SPF -match "~all") {
          $spfQuality += "~all(softfail)"
          $issues += "SPF_softfail"
        }
        # ?all チェック（中立）
        if ($record.SPF -match "\?all") {
          $spfQuality += "?all(neutral)"
          $issues += "SPF_neutral"
        }
        # ptr チェック（非推奨）
        if ($record.SPF -match "\bptr\b") {
          $spfQuality += "ptr(非推奨)"
          $issues += "SPF_ptr"
        }
        # include/redirect/a/mx/ip4/ip6の参照カウント
        $lookupCount = 0
        $lookupCount += ([regex]::Matches($record.SPF, '\binclude:')).Count
        $lookupCount += ([regex]::Matches($record.SPF, '\bredirect=')).Count
        $lookupCount += ([regex]::Matches($record.SPF, '\ba:')).Count
        $lookupCount += ([regex]::Matches($record.SPF, '\bmx:')).Count
        $lookupCount += ([regex]::Matches($record.SPF, '\bmx\b')).Count
        $lookupCount += ([regex]::Matches($record.SPF, '\ba\b')).Count
        if ($lookupCount -ge 8) {
          $spfQuality += "参照${lookupCount}(>=8警告)"
          $issues += "SPF_参照過多"
        }

        $record.SPF品質 = if ($spfQuality.Count -gt 0) { $spfQuality -join "; " } else { "OK" }
      } else {
        $issues += "NoSPF"
      }
    } catch {
      $errors += "SPF: $($_.Exception.Message)"
      $issues += "NoSPF"
    }

    # DMARCレコード（_dmarc.domain）+ rua/pct解析・複数定義検出
    try {
      $dmarcDomain = "_dmarc.$domain"
      $resolveParams = @{ Name = $dmarcDomain; Type = "TXT"; ErrorAction = "Stop" }
      if ($DnsServer) { $resolveParams.Server = $DnsServer }

      $dmarc = Resolve-DnsName @resolveParams
      $dmarcRecords = $dmarc | Where-Object { $_.Strings -match "v=DMARC1" }

      if ($dmarcRecords) {
        # 複数定義検出
        $dmarcCount = ($dmarcRecords | Measure-Object).Count
        if ($dmarcCount -gt 1) {
          $record.DMARC複数定義 = "警告: $dmarcCount 件（最初を採用）"
          $issues += "DMARC_複数定義"
        } else {
          $record.DMARC複数定義 = "なし"
        }

        # 先頭一致で正規化（最初のレコードを採用）
        $dmarcFirst = $dmarcRecords | Select-Object -First 1
        $record.DMARC = ($dmarcFirst.Strings -join "")

        # rua解析
        if ($record.DMARC -match "rua=([^;]+)") {
          $record.DMARC_rua = $Matches[1].Trim()
        } else {
          $issues += "DMARC_No_rua"
        }

        # pct解析
        if ($record.DMARC -match "pct=(\d+)") {
          $pctValue = [int]$Matches[1]
          $record.DMARC_pct = $pctValue.ToString()
          if ($pctValue -lt 100) {
            $issues += "DMARC_pct_low($pctValue)"
          }
        } else {
          $record.DMARC_pct = "100(default)"
        }

        # DMARC弱点チェック
        if ($record.DMARC -match "p=none") {
          $issues += "DMARC_p_none"
        }
      } else {
        $issues += "NoDMARC"
      }
    } catch {
      # DMARCはオプションなのでエラーにしない
      $issues += "NoDMARC"
    }

    # DKIMレコード（複数セレクタを試行）+ CNAME判定
    foreach ($selector in $DkimSelectors) {
      try {
        $dkimDomain = "$selector._domainkey.$domain"

        # まずCNAMEチェック
        $cnameParams = @{ Name = $dkimDomain; Type = "CNAME"; ErrorAction = "SilentlyContinue" }
        if ($DnsServer) { $cnameParams.Server = $DnsServer }
        $dkimCname = Resolve-DnsName @cnameParams

        if ($dkimCname -and ($dkimCname | Where-Object { $_.Type -eq "CNAME" })) {
          $cnameTarget = ($dkimCname | Where-Object { $_.Type -eq "CNAME" }).NameHost
          $record.DKIMセレクタ = $selector
          $record.DKIM_CNAME = $cnameTarget
          $record.DKIM = "CNAME→$cnameTarget"
          break
        }

        # TXTレコード取得
        $resolveParams = @{ Name = $dkimDomain; Type = "TXT"; ErrorAction = "Stop" }
        if ($DnsServer) { $resolveParams.Server = $DnsServer }

        $dkim = Resolve-DnsName @resolveParams
        $dkimRecord = $dkim | Where-Object { $_.Strings -match "v=DKIM1" -or $_.Strings -match "k=rsa" }
        if ($dkimRecord) {
          $record.DKIMセレクタ = $selector
          $record.DKIM = ($dkimRecord.Strings -join "")
          $record.DKIM_CNAME = "直接TXT"
          break  # 見つかったら終了
        }
      } catch {
        # DKIMセレクタが見つからない場合は次を試す
      }
    }

    # TLS-RPTレコード（_smtp._tls.domain）+ rua解析
    try {
      $tlsrptDomain = "_smtp._tls.$domain"
      $resolveParams = @{ Name = $tlsrptDomain; Type = "TXT"; ErrorAction = "Stop" }
      if ($DnsServer) { $resolveParams.Server = $DnsServer }

      $tlsrpt = Resolve-DnsName @resolveParams
      $tlsrptRecord = $tlsrpt | Where-Object { $_.Strings -match "v=TLSRPTv1" }
      if ($tlsrptRecord) {
        $record.TLSRPT = ($tlsrptRecord.Strings -join "")

        # rua解析
        if ($record.TLSRPT -match "rua=([^;]+)") {
          $record.TLSRPT_rua = $Matches[1].Trim()
        }
      }
    } catch {
      # TLS-RPTはオプション
    }

    # MTA-STSレコード（_mta-sts.domain TXT）+ STSv1判定
    try {
      # _mta-sts.domain TXTレコードを確認
      $mtastsTxtDomain = "_mta-sts.$domain"
      $resolveParams = @{ Name = $mtastsTxtDomain; Type = "TXT"; ErrorAction = "Stop" }
      if ($DnsServer) { $resolveParams.Server = $DnsServer }

      $mtastsTxt = Resolve-DnsName @resolveParams
      $mtastsRecord = $mtastsTxt | Where-Object { $_.Strings -match "v=STSv1" }
      if ($mtastsRecord) {
        $record.MTASTS = ($mtastsRecord.Strings -join "")
        $record.MTASTS_STSv1 = "OK"
      } else {
        # v=STSv1がない場合
        if ($mtastsTxt) {
          $record.MTASTS = ($mtastsTxt.Strings -join "")
          $record.MTASTS_STSv1 = "NG(v=STSv1なし)"
          $issues += "MTASTS_Invalid"
        }
      }
    } catch {
      # MTA-STSはオプション - mta-sts.domain のA/AAAAも確認
      try {
        $mtastsHostDomain = "mta-sts.$domain"
        $resolveParams = @{ Name = $mtastsHostDomain; Type = "A"; ErrorAction = "SilentlyContinue" }
        if ($DnsServer) { $resolveParams.Server = $DnsServer }

        $mtastsHost = Resolve-DnsName @resolveParams
        if ($mtastsHost) {
          $record.MTASTS = "ホストあり(TXTなし)"
        }
      } catch { }
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

  # MXホスト一覧（A/AAAA妥当性検証結果）
  if ($mxHostsResults.Count -gt 0) {
    $mxHostsResults | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "domains_mx_hosts.csv")
    Write-Host "  → MXホスト一覧: domains_mx_hosts.csv"
  }

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

  # SPF/DMARC複数定義を抽出
  $spfMultiple = $results | Where-Object { $_.SPF複数定義 -and $_.SPF複数定義 -ne "なし" }
  $dmarcMultiple = $results | Where-Object { $_.DMARC複数定義 -and $_.DMARC複数定義 -ne "なし" }

  #----------------------------------------------------------------------
  # サマリー作成
  #----------------------------------------------------------------------

  # MX妥当性の集計
  $mxValidCount = ($results | Where-Object { $_.MX_A_AAAA妥当 -eq "OK" }).Count
  $mxInvalidCount = ($results | Where-Object { $_.MX_A_AAAA妥当 -eq "NG" }).Count

  # SPF品質の集計
  $spfOkCount = ($results | Where-Object { $_.SPF品質 -eq "OK" }).Count
  $spfWarningCount = ($results | Where-Object { $_.SPF品質 -and $_.SPF品質 -ne "OK" }).Count

  $summary = @"
#===============================================================================
# DNS レコード取得サマリー（強化版）
#===============================================================================

【実行日時】$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

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

【MX妥当性検証】
  A/AAAA正常:   $mxValidCount 件
  問題あり:     $mxInvalidCount 件
  → MXホスト詳細: domains_mx_hosts.csv

【SPF品質チェック】
  品質OK:       $spfOkCount 件
  警告あり:     $spfWarningCount 件

【複数定義検出】
  SPF複数定義:    $($spfMultiple.Count) 件
  DMARC複数定義:  $($dmarcMultiple.Count) 件

【セキュリティ上の注意】
  SPF未設定:         $($noSpf.Count) 件 → domains_no_spf.txt
  DMARC未設定:       $($noDmarc.Count) 件 → domains_no_dmarc.txt
  弱点フラグあり:    $($withIssues.Count) 件 → domains_with_issues.csv

【弱点フラグの意味】

  ▼ MX関連
  NoMX:              MXレコードが未設定（メール受信不可）
  MX_CNAME_禁止:     MXホストがCNAME（RFC違反、要修正）
  MX_NoA_AAAA:       MXホストにA/AAAAレコードなし（配送不可）

  ▼ SPF関連
  NoSPF:             SPFレコードが未設定（なりすまし防止なし）
  SPF_複数定義:      SPFが複数定義（RFC違反、最初のみ有効）
  SPF_+all:          SPF設定が +all（全許可、危険）
  SPF_softfail:      SPF設定が ~all（ソフトフェイル、推奨は -all）
  SPF_neutral:       SPF設定が ?all（中立、推奨は -all）
  SPF_ptr:           SPF設定に ptr（非推奨、DNS負荷）
  SPF_参照過多:      SPF参照が8以上（DNS参照上限10に近い）

  ▼ DMARC関連
  NoDMARC:           DMARCレコードが未設定
  DMARC_複数定義:    DMARCが複数定義（最初のみ有効）
  DMARC_p_none:      DMARCポリシーがp=none（監視のみ、拒否なし）
  DMARC_pct_low:     DMARC適用率が100%未満（一部のみ適用）
  DMARC_No_rua:      DMARCにruaなし（レポート受信不可）

  ▼ MTA-STS関連
  MTASTS_Invalid:    MTA-STSにv=STSv1なし（無効）

#-------------------------------------------------------------------------------
# 確認すべきファイル
#-------------------------------------------------------------------------------

  ★ dns_records.csv
     → 全ドメインのDNSレコード一覧（要約・人が読む用）
     → MX列でメール受信先を確認
     → EXO移行後はMXを *.mail.protection.outlook.com に変更

  ★ domains_mx_hosts.csv
     → MXホスト一覧とA/AAAA妥当性検証結果
     → CNAME禁止、A/AAAA必須の検証結果

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
  例: v=spf1 include:spf.protection.outlook.com -all

  【DKIMレコード】
  EXO管理画面でDKIM署名を有効化後、CNAMEを設定
  selector1._domainkey → selector1-<domain>._domainkey.<tenant>.onmicrosoft.com
  selector2._domainkey → selector2-<domain>._domainkey.<tenant>.onmicrosoft.com

  【DMARCレコード】
  推奨: p=quarantine または p=reject（段階的に移行）
  例: v=DMARC1; p=quarantine; rua=mailto:dmarc@<domain>; pct=100

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
