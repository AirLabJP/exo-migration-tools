<#
.SYNOPSIS
  CSVからADユーザーへメール属性を一括投入

.DESCRIPTION
  CSVファイルからADユーザーのmail/proxyAddresses属性を一括設定します。
  スキーマ拡張後、SMTP重複チェック後に実行してください。

  【設定内容】
  - mail属性: プライマリSMTPアドレス
  - proxyAddresses: SMTP:<プライマリ>, smtp:<エイリアス>...
  - 既存のX500等は維持

  【出力ファイル】
  apply_report.csv ← 各ユーザーの処理結果
  summary.txt      ← 統計サマリー

.PARAMETER CsvPath
  投入CSVファイルパス
  必須カラム: UserPrincipalName or SamAccountName, PrimarySmtpAddress
  任意カラム: Aliases（セミコロン区切り）

.PARAMETER OutRoot
  出力先ルートフォルダ

.PARAMETER WhatIfMode
  実際には変更せず、変更内容を出力（ドライラン）

.PARAMETER SkipDuplicateCheck
  重複チェックをスキップ（Test-SmtpDuplicates.ps1で事前確認済みの場合）

.EXAMPLE
  # まずWhatIfで確認
  .\Set-ADMailAddressesFromCsv.ps1 -CsvPath mail_addresses.csv -WhatIfMode

  # 問題なければ本番実行
  .\Set-ADMailAddressesFromCsv.ps1 -CsvPath mail_addresses.csv

.NOTES
  - 必要モジュール: ActiveDirectory
  - 実行前にADバックアップを取得
  - Test-SmtpDuplicates.ps1で事前チェック推奨
#>
param(
  [Parameter(Mandatory=$true)]
  [string]$CsvPath,

  [string]$OutRoot = ".\inventory",

  [switch]$WhatIfMode,
  
  [switch]$SkipDuplicateCheck
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

function Normalize-Mail([string]$s) {
  if ([string]::IsNullOrWhiteSpace($s)) { return $null }
  return $s.Trim().ToLowerInvariant()
}

function To-ProxyPrimary([string]$smtp) { "SMTP:$smtp" }  # Primaryは大文字SMTP
function To-ProxyAlias([string]$smtp) { "smtp:$smtp" }    # Aliasは小文字smtp

function Validate-Email([string]$smtp) {
  if ([string]::IsNullOrWhiteSpace($smtp)) { return $false }
  return ($smtp -match '^[^@\s]+@[^@\s]+\.[^@\s]+$')
}

#----------------------------------------------------------------------
# メイン処理
#----------------------------------------------------------------------
Import-Module ActiveDirectory

$OutDir = New-OutDir -Root $OutRoot -Prefix "ad_mail_apply"
Start-Transcript -Path (Join-Path $OutDir "run.log") -Force

Write-Host "============================================================"
Write-Host " ADメール属性 一括投入"
Write-Host "============================================================"
Write-Host "入力CSV:     $CsvPath"
Write-Host "WhatIfモード: $WhatIfMode"
Write-Host "出力先:      $OutDir"
Write-Host ""

try {
  if (-not (Test-Path $CsvPath)) { throw "CSVファイルが見つかりません: $CsvPath" }
  
  $rows = Import-Csv $CsvPath
  Write-Host "CSV行数: $($rows.Count)"
  
  #----------------------------------------------------------------------
  # 簡易重複チェック
  #----------------------------------------------------------------------
  if (-not $SkipDuplicateCheck) {
    Write-Host ""
    Write-Host "[1/3] CSV内の簡易重複チェック..."
    
    $smtpCount = @{}
    foreach ($row in $rows) {
      $primary = Normalize-Mail $row.PrimarySmtpAddress
      if ($primary) {
        if (-not $smtpCount.ContainsKey($primary)) { $smtpCount[$primary] = 0 }
        $smtpCount[$primary]++
      }
      if ($row.Aliases) {
        foreach ($alias in ($row.Aliases -split ';')) {
          $a = Normalize-Mail $alias
          if ($a) {
            if (-not $smtpCount.ContainsKey($a)) { $smtpCount[$a] = 0 }
            $smtpCount[$a]++
          }
        }
      }
    }
    
    $duplicates = $smtpCount.GetEnumerator() | Where-Object { $_.Value -gt 1 }
    if ($duplicates) {
      Write-Host "      → 【エラー】CSV内に重複があります:"
      $duplicates | ForEach-Object { Write-Host "         $($_.Key): $($_.Value) 件" }
      throw "CSV内に重複SMTPがあります。Test-SmtpDuplicates.ps1で詳細を確認してください。"
    }
    Write-Host "      → OK: CSV内に重複なし"
  } else {
    Write-Host ""
    Write-Host "[1/3] 重複チェックをスキップ"
  }
  
  #----------------------------------------------------------------------
  # 処理実行
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[2/3] ★ メール属性を設定中..."
  if ($WhatIfMode) {
    Write-Host "      → WhatIfモード: 実際には変更しません"
  }
  
  $report = New-Object System.Collections.Generic.List[object]
  $successCount = 0
  $errorCount = 0
  $skipCount = 0
  
  foreach ($row in $rows) {
    $idUpn = $row.UserPrincipalName
    $idSam = $row.SamAccountName
    $primary = Normalize-Mail $row.PrimarySmtpAddress
    $identity = if ($idUpn) { $idUpn } else { $idSam }
    
    # バリデーション
    if (-not $primary -or -not (Validate-Email $primary)) {
      $report.Add([pscustomobject]@{
        ステータス = "エラー"
        識別子 = $identity
        理由 = "PrimarySmtpAddressが不正"
        プライマリSMTP = $row.PrimarySmtpAddress
        エイリアス数 = 0
      })
      $errorCount++
      continue
    }
    
    # エイリアス解析
    $aliases = @()
    $hasInvalidAlias = $false
    if ($row.Aliases) {
      foreach ($a in ($row.Aliases -split ';')) {
        $alias = Normalize-Mail $a
        if (-not $alias) { continue }
        
        if (-not (Validate-Email $alias)) {
          $report.Add([pscustomobject]@{
            ステータス = "エラー"
            識別子 = $identity
            理由 = "エイリアスが不正: $alias"
            プライマリSMTP = $primary
            エイリアス数 = 0
          })
          $hasInvalidAlias = $true
          $errorCount++
          break
        }
        $aliases += $alias
      }
    }
    
    if ($hasInvalidAlias) { continue }
    
    # プライマリと同じエイリアスは除外
    $aliases = $aliases | Where-Object { $_ -ne $primary } | Select-Object -Unique
    
    # ADユーザー検索
    $user = $null
    if ($idUpn) {
      $user = Get-ADUser -Filter "UserPrincipalName -eq '$idUpn'" -Properties mail,proxyAddresses,mailNickname -ErrorAction SilentlyContinue
    }
    if (-not $user -and $idSam) {
      $user = Get-ADUser -Identity $idSam -Properties mail,proxyAddresses,mailNickname -ErrorAction SilentlyContinue
    }
    
    if (-not $user) {
      $report.Add([pscustomobject]@{
        ステータス = "エラー"
        識別子 = $identity
        理由 = "ADユーザーが見つからない"
        プライマリSMTP = $primary
        エイリアス数 = $aliases.Count
      })
      $errorCount++
      continue
    }
    
    # 新しいproxyAddressesを構築
    $desired = New-Object System.Collections.Generic.HashSet[string]
    [void]$desired.Add((To-ProxyPrimary $primary))
    foreach ($a in $aliases) { 
      [void]$desired.Add((To-ProxyAlias $a))
    }
    
    # 既存のproxyAddressesを取得
    $current = @()
    if ($user.proxyAddresses) { $current = @($user.proxyAddresses) }
    
    # 既存アドレスの処理（X500等は維持、SMTPはエイリアスとして追加）
    $newProxy = @()
    foreach ($p in $current) {
      if ($p -match '^(SMTP|smtp):(.+)$') {
        # 既存SMTPはエイリアスとして追加（プライマリは別途設定）
        $addr = Normalize-Mail $Matches[2]
        if ($addr -and $addr -ne $primary) {
          [void]$desired.Add((To-ProxyAlias $addr))
        }
      } else {
        # X500等はそのまま維持
        $newProxy += $p
      }
    }
    
    $newProxy += $desired.ToArray()
    
    # 設定パラメータ
    $setParams = @{
      Identity = $user.DistinguishedName
      Replace = @{ mail = $primary; proxyAddresses = $newProxy }
    }
    
    if ($WhatIfMode) {
      Set-ADUser @setParams -WhatIf
      $report.Add([pscustomobject]@{
        ステータス = "WhatIf"
        識別子 = $user.SamAccountName
        理由 = ""
        プライマリSMTP = $primary
        エイリアス数 = $aliases.Count
      })
      $skipCount++
    } else {
      try {
        Set-ADUser @setParams
        $report.Add([pscustomobject]@{
          ステータス = "成功"
          識別子 = $user.SamAccountName
          理由 = ""
          プライマリSMTP = $primary
          エイリアス数 = $aliases.Count
        })
        $successCount++
      } catch {
        $report.Add([pscustomobject]@{
          ステータス = "エラー"
          識別子 = $user.SamAccountName
          理由 = $_.Exception.Message
          プライマリSMTP = $primary
          エイリアス数 = $aliases.Count
        })
        $errorCount++
      }
    }
  }
  
  #----------------------------------------------------------------------
  # レポート出力
  #----------------------------------------------------------------------
  Write-Host ""
  Write-Host "[3/3] レポートを出力中..."
  
  $report | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "apply_report.csv")
  
  #----------------------------------------------------------------------
  # サマリー
  #----------------------------------------------------------------------
  $summary = @"
#===============================================================================
# ADメール属性 投入サマリー
#===============================================================================

【実行日時】$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
【モード】$(if ($WhatIfMode) { "WhatIf（ドライラン）" } else { "本番実行" })

【処理結果】
  CSV行数:   $($rows.Count)
  成功:      $successCount
  エラー:    $errorCount
  WhatIf:    $skipCount

【確認すべきファイル】
  ★ apply_report.csv
     → 各ユーザーの処理結果

"@
  
  $summary | Out-File (Join-Path $OutDir "summary.txt") -Encoding UTF8
  
  Write-Host ""
  Write-Host "============================================================"
  Write-Host " 完了"
  Write-Host "============================================================"
  Write-Host $summary
  
  if ($errorCount -gt 0) {
    Write-Host "【警告】$errorCount 件のエラーが発生しました"
    Write-Host "        apply_report.csv を確認してください"
  }
  
  if ($WhatIfMode) {
    Write-Host ""
    Write-Host "【次のステップ】"
    Write-Host "  WhatIfモードのため、実際には変更されていません。"
    Write-Host "  問題がなければ -WhatIfMode なしで再実行してください。"
  } else {
    Write-Host ""
    Write-Host "【次のステップ】"
    Write-Host "  1. apply_report.csv でエラーがないか確認"
    Write-Host "  2. ADの変更がEntra Connectで同期されるのを待機"
    Write-Host "  3. EXOで受信者が正しく作成されたか確認"
  }
  
} catch {
  Write-Error $_
  throw
} finally {
  Stop-Transcript
}

Write-Host ""
Write-Host "出力先: $OutDir"
