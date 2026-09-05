[CmdletBinding()]
param(
    [string]$ProjectId,
    [string]$ProjectName,
    [string]$DirectoryName,
    [string]$Destination,
    [switch]$Gui,
    [switch]$Console
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
    # .gitignore is a cross-platform repository file; always emit LF.
    $content = @('# OS metadata', 'Thumbs.db', 'desktop.ini', '.DS_Store', '', '# Editor-local settings', '.vscode/', '.idea/', '') -join "`n"
    [IO.File]::WriteAllText((Join-Path $ProjectDirectory '.gitignore'), $content, (New-Object Text.UTF8Encoding($false)))
}

function Copy-DirectoryContents {
    param([string]$Source, [string]$Target)
    New-Item -ItemType Directory -Path $Target -Force | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $Target $_.Name) -Recurse -Force
    }
}

function Resolve-ProjectSettings {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Title,
        [string]$Directory
    )
    if ([string]::IsNullOrWhiteSpace($Id) -or $Id -notmatch '^[A-Za-z0-9_-]+$') {
        throw 'プロジェクトIDは半角英数字、ハイフン、アンダースコアだけで指定してください。'
    }
    if ([string]::IsNullOrWhiteSpace($Title)) { $Title = $Id }
    if ($Title -match '[\r\n"]') { throw 'ゲーム表示名に改行またはダブルクォートは使用できません。' }
    if ([string]::IsNullOrWhiteSpace($Directory)) { $Directory = $Id }
    if ($Directory -match '[\\/:*?"<>|]' -or $Directory -match '[\. ]$') { throw 'ディレクトリー名にWindowsで使えない文字は使用できません。' }
    return [pscustomobject]@{ Id = $Id; Title = $Title; Directory = $Directory }
}

function Set-TyranoProjectMetadata {
    param(
        [Parameter(Mandatory)][string]$ProjectDirectory,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$ProjectTitle
    )
    $configPath = Join-Path $ProjectDirectory 'data\system\Config.tjs'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw 'Config.tjs が見つかりません。TyranoScriptプロジェクトとして認識できません。' }
    $text = [IO.File]::ReadAllText($configPath)
    $lines = $text -split "`r?`n", 0
    $foundId = $false; $foundTitle = $false
    $updated = foreach ($line in $lines) {
        if ($line -match '^\s*;projectID\s*=') { $foundId = $true; ';projectID = ' + $ProjectId + ';' }
        elseif ($line -match '^\s*;System\.title\s*=') { $foundTitle = $true; ';System.title = "' + $ProjectTitle + '";' }
        else { $line }
    }
    if (-not $foundId -or -not $foundTitle) { throw 'Config.tjsにprojectIDまたはSystem.titleの設定が見つかりません。' }
    [IO.File]::WriteAllText($configPath, ($updated -join "`r`n"), (New-Object Text.UTF8Encoding($false)))

    $studioPath = Join-Path $ProjectDirectory 'studio_config.json'
    if (Test-Path -LiteralPath $studioPath -PathType Leaf) {
        try {
            $studio = Get-Content -LiteralPath $studioPath -Raw | ConvertFrom-Json
            if ($null -eq $studio.pobj) { $studio | Add-Member -NotePropertyName pobj -NotePropertyValue ([pscustomobject]@{}) }
            $studio.pobj.project_id = $ProjectId
            $studio.pobj.title = $ProjectTitle
            $studio.pobj.path = $ProjectDirectory
            [IO.File]::WriteAllText($studioPath, ($studio | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
        } catch { throw "studio_config.jsonの更新に失敗しました: $($_.Exception.Message)" }
    }
}

function New-TyranoProject {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$ParentDirectory,
        [scriptblock]$Progress = { param($message) Write-Host $message }
    )
    $settings = Resolve-ProjectSettings -Id $Id -Title $Title -Directory $Directory
    $parent = [IO.Path]::GetFullPath($ParentDirectory)
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $project = Join-Path $parent $settings.Directory
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
        Set-TyranoProjectMetadata -ProjectDirectory $project -ProjectId $settings.Id -ProjectTitle $settings.Title
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
    if ([string]::IsNullOrWhiteSpace($ProjectId)) { $ProjectId = Read-Host 'プロジェクトID（半角英数字・ハイフン・アンダースコア）' }
    if ($null -eq $ProjectName) { $ProjectName = Read-Host 'ゲーム表示名（空欄でID）' }
    if ($null -eq $DirectoryName) { $DirectoryName = Read-Host 'ディレクトリー名（空欄でID）' }
    if ([string]::IsNullOrWhiteSpace($Destination)) { $Destination = Read-Host '作成先フォルダー（空欄で現在のフォルダー）'; if ([string]::IsNullOrWhiteSpace($Destination)) { $Destination = (Get-Location).Path } }
    try {
        $result = New-TyranoProject -Id $ProjectId -Title $ProjectName -Directory $DirectoryName -ParentDirectory $Destination
        Write-Host "`nプロジェクトを作成しました。TyranoStudio V6で次のファイルを選択してください：`n$($result.Path)\index.html" -ForegroundColor Green
        Write-Host 'TyranoStudio V6: https://tyrano.jp/dl/v6'
    } catch { Write-Error $_.Exception.Message; return 1 }
    return 0
}

function New-TyranoForm {
    param(
        [string]$InitialProjectId,
        [string]$InitialProjectName,
        [string]$InitialDirectoryName,
        [Parameter(Mandatory)][string]$InitialDestination
    )
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $defaultDestination = $InitialDestination
    $form = New-Object Windows.Forms.Form; $form.Text = 'TyranoScript 初期セットアップ'; $form.Size = New-Object Drawing.Size(600, 350); $form.StartPosition = 'CenterScreen'
    $label1 = New-Object Windows.Forms.Label; $label1.Text = 'プロジェクトID'; $label1.Location = New-Object Drawing.Point(20, 22); $label1.AutoSize = $true
    $idBox = New-Object Windows.Forms.TextBox; $idBox.Name = 'projectIdBox'; $idBox.Location = New-Object Drawing.Point(170, 18); $idBox.Width = 390; $idBox.Text = $InitialProjectId
    $label2 = New-Object Windows.Forms.Label; $label2.Text = 'ゲーム表示名（空欄でID）'; $label2.Location = New-Object Drawing.Point(20, 62); $label2.AutoSize = $true
    $nameBox = New-Object Windows.Forms.TextBox; $nameBox.Name = 'projectNameBox'; $nameBox.Location = New-Object Drawing.Point(170, 58); $nameBox.Width = 390; $nameBox.Text = $InitialProjectName
    $label3 = New-Object Windows.Forms.Label; $label3.Text = 'ディレクトリー名（空欄でID）'; $label3.Location = New-Object Drawing.Point(20, 102); $label3.AutoSize = $true
    $directoryBox = New-Object Windows.Forms.TextBox; $directoryBox.Name = 'directoryNameBox'; $directoryBox.Location = New-Object Drawing.Point(170, 98); $directoryBox.Width = 390; $directoryBox.Text = $InitialDirectoryName
    $label4 = New-Object Windows.Forms.Label; $label4.Text = '作成先フォルダー'; $label4.Location = New-Object Drawing.Point(20, 142); $label4.AutoSize = $true
    $destBox = New-Object Windows.Forms.TextBox; $destBox.Name = 'destinationBox'; $destBox.Location = New-Object Drawing.Point(170, 138); $destBox.Width = 310; $destBox.Text = $defaultDestination
    $browse = New-Object Windows.Forms.Button; $browse.Text = '参照…'; $browse.Location = New-Object Drawing.Point(490, 136); $browse.Add_Click({ $dialog = New-Object Windows.Forms.FolderBrowserDialog; if ($dialog.ShowDialog() -eq 'OK') { $destBox.Text = $dialog.SelectedPath } })
    $status = New-Object Windows.Forms.Label; $status.Text = '必要項目を入力してください。'; $status.Location = New-Object Drawing.Point(20, 185); $status.Size = New-Object Drawing.Size(540, 45)
    $run = New-Object Windows.Forms.Button; $run.Name = 'createButton'; $run.Text = '作成'; $run.Location = New-Object Drawing.Point(450, 250); $run.Width = 110
    $run.Add_Click({ try { $run.Enabled = $false; $status.Text = '処理中…'; $result = New-TyranoProject -Id $idBox.Text -Title $nameBox.Text -Directory $directoryBox.Text -ParentDirectory $destBox.Text -Progress { param($m) $status.Text = $m; [Windows.Forms.Application]::DoEvents() }; [Windows.Forms.MessageBox]::Show("作成しました。`n$($result.Path)\index.html", '完了'); $form.Close() } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'エラー', 'OK', 'Error') } finally { $run.Enabled = $true } })
    $form.AcceptButton = $run
    $form.Controls.AddRange(@($label1, $idBox, $label2, $nameBox, $label3, $directoryBox, $label4, $destBox, $browse, $status, $run))
    return $form
}

function Start-Gui {
    $defaultDestination = if ([string]::IsNullOrWhiteSpace($Destination)) { (Get-Location).Path } else { $Destination }
    $form = New-TyranoForm -InitialProjectId $ProjectId -InitialProjectName $ProjectName -InitialDirectoryName $DirectoryName -InitialDestination $defaultDestination
    [Windows.Forms.Application]::Run($form)
}

if ($MyInvocation.InvocationName -ne '.') {
    # Explorer's "Run with PowerShell" supplies no reliable marker that can
    # be distinguished from a terminal launch. No-argument launches therefore
    # open the GUI; use -Console for interactive text mode.
    if ($Gui -or (-not $Console -and [string]::IsNullOrWhiteSpace($ProjectId) -and [string]::IsNullOrWhiteSpace($ProjectName) -and [string]::IsNullOrWhiteSpace($DirectoryName) -and [string]::IsNullOrWhiteSpace($Destination))) { Start-Gui }
    else { exit (Start-Console) }
}
