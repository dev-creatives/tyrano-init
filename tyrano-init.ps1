[CmdletBinding()]
param(
    [string]$ProjectName,
    [string]$Destination,
    [switch]$Gui
)

$ErrorActionPreference = 'Stop'
$script:DownloadPage = 'https://tyrano.jp/dl/v6'
$script:UserAgent = 'tyrano-init/1.0'

function Get-LatestPackageUrl {
    param([string]$Html, [string]$PageUrl = $script:DownloadPage)

    # The official page labels the current package with 最新版. Keep parsing
    # deliberately narrow so an old-version link is never selected by mistake.
    $dq = [char]34
    $pattern = '(?is)<a\b[^>]*href\s*=\s*' + $dq + '([^' + $dq + ']+\.zip(?:\?[^' + $dq + ']*)?)' + $dq + '[^>]*>.*?最新版.*?</a>'
    $match = [regex]::Match($Html, $pattern)
    if (-not $match.Success) {
        $pattern = '(?is)<a\b[^>]*>.*?最新版.*?<[^>]+href\s*=\s*' + $dq + '([^' + $dq + ']+\.zip(?:\?[^' + $dq + ']*)?)' + $dq
        $match = [regex]::Match($Html, $pattern)
    }
    if (-not $match.Success) { throw '公式ダウンロードページから最新版のZIPリンクを見つけられませんでした。ページ構成が変更された可能性があります。' }
    $base = New-Object -TypeName Uri -ArgumentList $PageUrl
    $resolved = New-Object -TypeName Uri -ArgumentList $base, $match.Groups[1].Value
    return $resolved.AbsoluteUri
}

function Get-ProjectSourceDirectory {
    param([string]$ExtractedDirectory)
    $indexes = @(Get-ChildItem -LiteralPath $ExtractedDirectory -Filter 'index.html' -File -Recurse -Force)
    if ($indexes.Count -eq 0) { throw 'ZIP内に index.html が見つかりません。TyranoScriptのスタンダードパッケージではない可能性があります。' }
    if ($indexes.Count -gt 1) { throw 'ZIP内に index.html が複数あります。使用するパッケージを特定できません。' }
    return $indexes[0].Directory.FullName
}

function Write-ProjectGitIgnore {
    param([string]$ProjectDirectory)
    $content = @('# OS metadata', 'Thumbs.db', 'desktop.ini', '.DS_Store', '', '# Editor-local settings', '.vscode/', '.idea/', '') -join [Environment]::NewLine
    [IO.File]::WriteAllText((Join-Path $ProjectDirectory '.gitignore'), $content, (New-Object Text.UTF8Encoding($false)))
}

function Copy-DirectoryContents {
    param([string]$Source, [string]$Target)
    New-Item -ItemType Directory -Path $Target -Force | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $Target $_.Name) -Recurse -Force
    }
}

function New-TyranoProject {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ParentDirectory,
        [scriptblock]$Progress = { param($message) Write-Host $message }
    )
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -match '[\\/:*?"<>|]') { throw 'プロジェクト名が空、またはWindowsで使えない文字を含んでいます。' }
    $parent = [IO.Path]::GetFullPath($ParentDirectory)
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $project = Join-Path $parent $Name
    if (Test-Path -LiteralPath $project) { throw "出力先は既に存在します（上書きしません）：$project" }

    $guid = [Guid]::NewGuid().ToString([char]78)
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('tyrano-init-' + $guid)
    $zip = Join-Path $temp 'package.zip'
    $extract = Join-Path $temp 'extracted'
    try {
        New-Item -ItemType Directory -Path $temp, $extract -Force | Out-Null
        & $Progress '公式ページから最新版の情報を取得しています…'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $page = Invoke-WebRequest -Uri $script:DownloadPage -UseBasicParsing -UserAgent $script:UserAgent
        $url = Get-LatestPackageUrl -Html $page.Content
        & $Progress ('ダウンロード中: ' + $url)
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -UserAgent $script:UserAgent
        if ((Get-Item -LiteralPath $zip).Length -lt 1024) { throw 'ダウンロードしたZIPが空または不完全です。' }
        & $Progress 'ZIPを展開しています…'
        Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
        $source = Get-ProjectSourceDirectory -ExtractedDirectory $extract
        & $Progress 'プロジェクトファイルを配置しています…'
        Copy-DirectoryContents -Source $source -Target $project
        Write-ProjectGitIgnore -ProjectDirectory $project
        & $Progress ('完了: ' + $project)
        $result = [pscustomobject]@{ Path = $project; PackageUrl = $url }
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        return $result
    } catch {
        if (Test-Path -LiteralPath $project) { Remove-Item -LiteralPath $project -Recurse -Force }
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Start-Console {
    if ([string]::IsNullOrWhiteSpace($ProjectName)) { $ProjectName = Read-Host 'プロジェクト名（例: MyNovel）' }
    if ([string]::IsNullOrWhiteSpace($Destination)) { $Destination = Read-Host '作成先フォルダー（空欄で現在のフォルダー）'; if ([string]::IsNullOrWhiteSpace($Destination)) { $Destination = (Get-Location).Path } }
    try {
        $result = New-TyranoProject -Name $ProjectName -ParentDirectory $Destination
        Write-Host "`nプロジェクトを作成しました。TyranoStudio V6で次のファイルを選択してください：`n$($result.Path)\index.html" -ForegroundColor Green
        Write-Host 'TyranoStudio V6: https://tyrano.jp/dl/v6'
    } catch { Write-Error $_.Exception.Message; return 1 }
    return 0
}

function Start-Gui {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $form = New-Object Windows.Forms.Form; $form.Text = 'TyranoScript 初期セットアップ'; $form.Size = New-Object Drawing.Size(560, 250); $form.StartPosition = 'CenterScreen'
    $label1 = New-Object Windows.Forms.Label; $label1.Text = 'プロジェクト名'; $label1.Location = New-Object Drawing.Point(20, 22); $label1.AutoSize = $true
    $nameBox = New-Object Windows.Forms.TextBox; $nameBox.Location = New-Object Drawing.Point(150, 18); $nameBox.Width = 360; $nameBox.Text = $ProjectName
    $label2 = New-Object Windows.Forms.Label; $label2.Text = '作成先フォルダー'; $label2.Location = New-Object Drawing.Point(20, 62); $label2.AutoSize = $true
    $destBox = New-Object Windows.Forms.TextBox; $destBox.Location = New-Object Drawing.Point(150, 58); $destBox.Width = 280; $destBox.Text = $Destination
    $browse = New-Object Windows.Forms.Button; $browse.Text = '参照…'; $browse.Location = New-Object Drawing.Point(440, 56); $browse.Add_Click({ $dialog = New-Object Windows.Forms.FolderBrowserDialog; if ($dialog.ShowDialog() -eq 'OK') { $destBox.Text = $dialog.SelectedPath } })
    $status = New-Object Windows.Forms.Label; $status.Text = 'プロジェクト名と作成先を入力してください。'; $status.Location = New-Object Drawing.Point(20, 105); $status.Size = New-Object Drawing.Size(500, 45)
    $run = New-Object Windows.Forms.Button; $run.Text = '作成'; $run.Location = New-Object Drawing.Point(400, 165); $run.Width = 110
    $run.Add_Click({ try { $run.Enabled = $false; $status.Text = '処理中…'; $result = New-TyranoProject -Name $nameBox.Text -ParentDirectory $destBox.Text -Progress { param($m) $status.Text = $m; [Windows.Forms.Application]::DoEvents() }; [Windows.Forms.MessageBox]::Show("作成しました。`n$($result.Path)\index.html", '完了'); $status.Text = '完了しました。' } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'エラー', 'OK', 'Error') } finally { $run.Enabled = $true } })
    $form.Controls.AddRange(@($label1, $nameBox, $label2, $destBox, $browse, $status, $run)); [Windows.Forms.Application]::Run($form)
}

if ($MyInvocation.InvocationName -ne '.') { if ($Gui) { Start-Gui } else { exit (Start-Console) } }
