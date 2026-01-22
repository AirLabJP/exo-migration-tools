<#
.SYNOPSIS
  テスト用メールボックス作成スクリプト

.DESCRIPTION
  メールフロー検証用のテストアカウントを作成します。
  Entra IDに直接ユーザーを作成し、ライセンスを付与してEXOメールボックスを生成します。

  【用途】
  - テストドメインでのメール経路検証
  - 本番切替前の送受信テスト
  - ADスキーマ拡張前のルーティング確認

  【作成されるもの】
  - Entra IDユーザー（クラウドオンリー）
  - EXOメールボックス（ライセンス付与後）

.PARAMETER TestDomain
  テストドメイン（例: test.contoso.co.jp）

.PARAMETER UserPrefix
  ユーザー名のプレフィックス（例: testuser → testuser01, testuser02...）

.PARAMETER Count
  作成するテストユーザー数（デフォルト: 3）

.PARAMETER SkuId
  割り当てるライセンスのSkuId（例: Exchange Online Plan 1）

.PARAMETER Password
  初期パスワード（省略時は自動生成）

.PARAMETER WhatIfMode
  実際には作成せず、確認のみ

.PARAMETER OutDir
  出力先フォルダ

.EXAMPLE
  # テストユーザー3人作成（WhatIfで確認）
  .\New-TestMailboxes.ps1 -TestDomain "test.contoso.co.jp" -WhatIfMode

  # 本番実行
  .\New-TestMailboxes.ps1 -TestDomain "test.contoso.co.jp" -Count 5

  # ライセンス指定
  .\New-TestMailboxes.ps1 -TestDomain "test.contoso.co.jp" -SkuId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.NOTES
  - Microsoft.Graph モジュールが必要
  - Connect-MgGraph で接続済みであること
  - User.ReadWrite.All, Directory.ReadWrite.All スコープが必要
  - ライセンス付与後、メールボックス作成には数分〜数十分かかる
#>

# テスト用途のため、パスワードを平文で扱う必要がある（自動生成してファイル出力するため）
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '')]
param(
  [Parameter(Mandatory=$true)]
  [string]$TestDomain,
  
  [string]$UserPrefix = "testuser",
  
  [int]$Count = 3,
  
  [string]$SkuId,
  
  [string]$Password,
  
  [switch]$WhatIfMode,
  
  [string]$OutDir = ".\test_mailboxes"
)

# エラーアクションの設定
$ErrorActionPreference = "Stop"

# 出力先フォルダ作成
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$OutDir = Join-Path $OutDir $ts
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Start-Transcript -Path (Join-Path $OutDir "run.log") -Force

Write-Host "============================================================"
Write-Host " テスト用メールボックス作成"
Write-Host "============================================================"
Write-Host "テストドメイン: $TestDomain"
Write-Host "ユーザー数: $Count"
Write-Host "出力先: $OutDir"
Write-Host ""

if ($WhatIfMode) {
  Write-Host "【WhatIfモード】実際の作成は行いません" -ForegroundColor Yellow
  Write-Host ""
}

#----------------------------------------------------------------------
# Graph接続確認
#----------------------------------------------------------------------
Write-Host "[1/5] Microsoft Graph 接続確認..."

try {
  Import-Module Microsoft.Graph.Users -ErrorAction Stop
  Import-Module Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop
  $context = Get-MgContext -ErrorAction Stop
  if (-not $context) {
    throw "Graphに接続されていません"
  }
  Write-Host "      → 接続済み: $($context.Account)"
  Write-Host "      → TenantId: $($context.TenantId)"
} catch {
  throw "Microsoft Graphに接続されていません。Connect-MgGraph -Scopes 'User.ReadWrite.All','Directory.ReadWrite.All' を実行してください。"
}

#----------------------------------------------------------------------
# ライセンス確認
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[2/5] 利用可能なライセンスを確認..."

$availableSkus = Get-MgSubscribedSku | Where-Object { $_.CapabilityStatus -eq "Enabled" }

if (-not $SkuId) {
  # Exchange Online関連のライセンスを探す
  $exoSkus = $availableSkus | Where-Object { 
    $_.ServicePlans | Where-Object { $_.ServicePlanName -like "*EXCHANGE*" }
  }
  
  if ($exoSkus.Count -gt 0) {
    Write-Host ""
    Write-Host "【利用可能なExchange Onlineライセンス】"
    $idx = 1
    foreach ($sku in $exoSkus) {
      $available = $sku.PrepaidUnits.Enabled - $sku.ConsumedUnits
      Write-Host "  [$idx] $($sku.SkuPartNumber) (残: $available)"
      Write-Host "      SkuId: $($sku.SkuId)"
      $idx++
    }
    Write-Host ""
    Write-Host "ライセンスを指定するには -SkuId パラメータを使用してください"
    
    # 最も残数が多いものを選択
    $selectedSku = $exoSkus | Sort-Object { $_.PrepaidUnits.Enabled - $_.ConsumedUnits } -Descending | Select-Object -First 1
    $SkuId = $selectedSku.SkuId
    Write-Host "      → 自動選択: $($selectedSku.SkuPartNumber)"
  } else {
    Write-Host "      → 警告: Exchange Online関連のライセンスが見つかりません" -ForegroundColor Yellow
    Write-Host "      → ライセンスなしでユーザーのみ作成します"
  }
} else {
  $selectedSku = $availableSkus | Where-Object { $_.SkuId -eq $SkuId }
  if (-not $selectedSku) {
    Write-Host "      → 警告: 指定されたSkuIdが見つかりません: $SkuId" -ForegroundColor Yellow
  } else {
    Write-Host "      → 指定ライセンス: $($selectedSku.SkuPartNumber)"
  }
}

#----------------------------------------------------------------------
# パスワード生成
#----------------------------------------------------------------------
if (-not $Password) {
  # ランダムパスワード生成（16文字、大小文字・数字・記号）
  $chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*"
  $Password = -join ((1..16) | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
  Write-Host ""
  Write-Host "[3/5] パスワードを自動生成..."
  Write-Host "      → パスワードは出力ファイルに記録されます"
} else {
  Write-Host ""
  Write-Host "[3/5] パスワードを指定..."
}

#----------------------------------------------------------------------
# ユーザー作成
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[4/5] ★ テストユーザーを作成..."

$results = @()
$successCount = 0
$errorCount = 0

for ($i = 1; $i -le $Count; $i++) {
  $num = $i.ToString("00")
  $upn = "$UserPrefix$num@$TestDomain"
  $displayName = "Test User $num"
  $mailNickname = "$UserPrefix$num"
  
  Write-Host ""
  Write-Host "  [$i/$Count] $upn"
  
  if ($WhatIfMode) {
    Write-Host "    [WhatIf] 作成予定"
    $results += [PSCustomObject]@{
      UserPrincipalName = $upn
      DisplayName = $displayName
      ObjectId = "N/A"
      Password = $Password
      LicenseAssigned = if ($SkuId) { "予定" } else { "なし" }
      Status = "WHATIF"
      Message = "WhatIfモード"
    }
  } else {
    try {
      # ユーザー作成
      $passwordProfile = @{
        Password = $Password
        ForceChangePasswordNextSignIn = $false
      }
      
      $newUser = New-MgUser `
        -UserPrincipalName $upn `
        -DisplayName $displayName `
        -MailNickname $mailNickname `
        -AccountEnabled:$true `
        -PasswordProfile $passwordProfile `
        -UsageLocation "JP" `
        -ErrorAction Stop
      
      Write-Host "    → ユーザー作成完了: $($newUser.Id)"
      
      # ライセンス付与
      $licenseAssigned = "なし"
      if ($SkuId) {
        try {
          $addLicenses = @(
            @{ SkuId = $SkuId }
          )
          Set-MgUserLicense -UserId $newUser.Id -AddLicenses $addLicenses -RemoveLicenses @() -ErrorAction Stop
          $licenseAssigned = "完了"
          Write-Host "    → ライセンス付与完了" -ForegroundColor Green
        } catch {
          $licenseAssigned = "失敗: $($_.Exception.Message)"
          Write-Host "    → ライセンス付与失敗: $_" -ForegroundColor Yellow
        }
      }
      
      $results += [PSCustomObject]@{
        UserPrincipalName = $upn
        DisplayName = $displayName
        ObjectId = $newUser.Id
        Password = $Password
        LicenseAssigned = $licenseAssigned
        Status = "SUCCESS"
        Message = "作成完了"
      }
      $successCount++
      
    } catch {
      Write-Host "    → エラー: $($_.Exception.Message)" -ForegroundColor Red
      $results += [PSCustomObject]@{
        UserPrincipalName = $upn
        DisplayName = $displayName
        ObjectId = "N/A"
        Password = $Password
        LicenseAssigned = "N/A"
        Status = "ERROR"
        Message = $_.Exception.Message
      }
      $errorCount++
    }
  }
}

# 結果をCSV出力（パスワード含む - 取り扱い注意）
$results | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutDir "test_users.csv")

#----------------------------------------------------------------------
# 削除用スクリプト生成
#----------------------------------------------------------------------
Write-Host ""
Write-Host "[5/5] クリーンアップスクリプトを生成..."

$cleanupScript = @"
# テストユーザー削除スクリプト
# 生成日時: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
# 対象ドメイン: $TestDomain
#
# 使用方法:
#   Connect-MgGraph -Scopes "User.ReadWrite.All"
#   .\cleanup_test_users.ps1

`$testUsers = @(
$(($results | Where-Object { $_.Status -eq "SUCCESS" -or $_.Status -eq "WHATIF" } | ForEach-Object { "  `"$($_.UserPrincipalName)`"" }) -join ",`n")
)

foreach (`$upn in `$testUsers) {
  try {
    Remove-MgUser -UserId `$upn -Confirm:`$false -ErrorAction Stop
    Write-Host "[削除完了] `$upn" -ForegroundColor Green
  } catch {
    Write-Host "[エラー] `$upn: `$_" -ForegroundColor Red
  }
}
"@

$cleanupScript | Out-File (Join-Path $OutDir "cleanup_test_users.ps1") -Encoding UTF8

#----------------------------------------------------------------------
# サマリー
#----------------------------------------------------------------------
$summary = @"
#===============================================================================
# テスト用メールボックス作成 サマリー
#===============================================================================

【実行日時】$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
【モード】$(if ($WhatIfMode) { "WhatIf（ドライラン）" } else { "本番実行" })

【作成情報】
  テストドメイン: $TestDomain
  ユーザー数:     $Count
  成功:           $successCount
  エラー:         $errorCount

【ライセンス】
  SkuId: $(if ($SkuId) { $SkuId } else { "なし" })
  $(if ($selectedSku) { "SkuPartNumber: $($selectedSku.SkuPartNumber)" } else { "" })

【出力ファイル】
  test_users.csv            ← 作成したユーザー一覧（パスワード含む！取り扱い注意）
  cleanup_test_users.ps1    ← テストユーザー削除用スクリプト

#-------------------------------------------------------------------------------
# 注意事項
#-------------------------------------------------------------------------------

⚠️ test_users.csv にはパスワードが含まれています
   - 安全に管理してください
   - テスト完了後は削除を推奨

#-------------------------------------------------------------------------------
# 次のステップ
#-------------------------------------------------------------------------------

"@

if ($WhatIfMode) {
  $summary += @"
  WhatIfモードでした。実際に作成するには -WhatIfMode なしで再実行してください。

"@
} else {
  $summary += @"
  1. メールボックス作成を待機（ライセンス付与後、数分〜数十分）
  
  2. EXOでメールボックス作成を確認:
     Get-Mailbox -Identity "$UserPrefix*"
  
  3. テストメール送信:
     .\lab-env\Send-TestEmail.ps1 -To "$UserPrefix01@$TestDomain" -Subject "テスト"
  
  4. テスト完了後、クリーンアップ:
     .\$OutDir\cleanup_test_users.ps1

"@
}

$summary | Out-File (Join-Path $OutDir "summary.txt") -Encoding UTF8

Write-Host ""
Write-Host "============================================================"
Write-Host " 完了"
Write-Host "============================================================"
Write-Host $summary

if ($errorCount -gt 0) {
  Write-Host "【警告】$errorCount 件のエラーが発生しました" -ForegroundColor Red
}

Stop-Transcript
Write-Host ""
Write-Host "出力先: $OutDir"

# 終了コード
if ($errorCount -gt 0) { exit 1 } else { exit 0 }
