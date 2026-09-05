[CmdletBinding()]
param(
    [string]$ProjectId,
    [string]$ProjectName,
    [string]$DirectoryName,
    [string]$Destination,
    [switch]$Gui,
    [switch]$Console,
    [switch]$Refresh
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

function Get-TyranoCacheDirectory {
    param([string]$CacheDirectory)
    if ([string]::IsNullOrWhiteSpace($CacheDirectory)) {
        $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        return (Join-Path $localAppData 'tyrano-init\cache')
    }
    return [IO.Path]::GetFullPath($CacheDirectory)
}

function Get-TyranoPackageCachePath {
    param(
        [Parameter(Mandatory)][string]$PackageUrl,
        [Parameter(Mandatory)][string]$CacheDirectory
    )
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($PackageUrl)
        $hash = [BitConverter]::ToString($sha256.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }
    return (Join-Path $CacheDirectory ($hash + '.zip'))
}

function Test-TyranoPackageArchive {
    param([Parameter(Mandatory)][string]$ZipPath)
    if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) { return $false }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
        try { return $archive.Entries.Count -gt 0 } finally { $archive.Dispose() }
    } catch {
        return $false
    }
}

function Get-TyranoPackage {
    param(
        [string]$CacheDirectory,
        [switch]$Refresh,
        [scriptblock]$Progress = { param($message) Write-Host $message },
        [scriptblock]$GetDownloadPage,
        [scriptblock]$DownloadPackage
    )
    if ($null -eq $GetDownloadPage) {
        $GetDownloadPage = { Invoke-WebRequest -Uri $script:DownloadPage -UseBasicParsing -UserAgent $script:UserAgent }.GetNewClosure()
    }
    if ($null -eq $DownloadPackage) {
        $DownloadPackage = { param($url, $path) Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing -UserAgent $script:UserAgent }.GetNewClosure()
    }

    & $Progress '公式ページから最新版の情報を取得しています…'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $page = & $GetDownloadPage
    $url = Get-LatestPackageUrl -Html $page.Content
    $resolvedCacheDirectory = Get-TyranoCacheDirectory -CacheDirectory $CacheDirectory
    New-Item -ItemType Directory -Path $resolvedCacheDirectory -Force | Out-Null
    $cachePath = Get-TyranoPackageCachePath -PackageUrl $url -CacheDirectory $resolvedCacheDirectory

    if (-not $Refresh -and (Test-TyranoPackageArchive -ZipPath $cachePath)) {
        & $Progress ('ダウンロード済みパッケージを使用します: ' + $cachePath)
        return [pscustomobject]@{ Url = $url; ZipPath = $cachePath; FromCache = $true }
    }

    $partialPath = $cachePath + '.partial-' + [Guid]::NewGuid().ToString([char]78)
    try {
        & $Progress ('ダウンロード中: ' + $url)
        & $DownloadPackage $url $partialPath
        if (-not (Test-TyranoPackageArchive -ZipPath $partialPath)) { throw 'ダウンロードしたZIPが空、破損、またはTyranoScriptパッケージではありません。' }
        Move-Item -LiteralPath $partialPath -Destination $cachePath -Force
    } finally {
        if (Test-Path -LiteralPath $partialPath) { Remove-Item -LiteralPath $partialPath -Force -ErrorAction SilentlyContinue }
    }
    return [pscustomobject]@{ Url = $url; ZipPath = $cachePath; FromCache = $false }
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
        [Parameter(Mandatory)][AllowEmptyString()][string]$Title,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Directory,
        [Parameter(Mandatory)][string]$ParentDirectory,
        [scriptblock]$Progress = { param($message) Write-Host $message },
        [string]$CacheDirectory,
        [switch]$Refresh,
        [scriptblock]$GetDownloadPage,
        [scriptblock]$DownloadPackage
    )
    $settings = Resolve-ProjectSettings -Id $Id -Title $Title -Directory $Directory
    $parent = [IO.Path]::GetFullPath($ParentDirectory)
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $project = Join-Path $parent $settings.Directory
    if (Test-Path -LiteralPath $project) { throw "出力先は既に存在します（上書きしません）：$project" }

    $guid = [Guid]::NewGuid().ToString([char]78)
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('tyrano-init-' + $guid)
    $extract = Join-Path $temp 'extracted'
    try {
        New-Item -ItemType Directory -Path $temp, $extract -Force | Out-Null
        $package = Get-TyranoPackage -CacheDirectory $CacheDirectory -Refresh:$Refresh -Progress $Progress -GetDownloadPage $GetDownloadPage -DownloadPackage $DownloadPackage
        & $Progress 'ZIPを展開しています…'
        Expand-Archive -LiteralPath $package.ZipPath -DestinationPath $extract -Force
        $source = Get-ProjectSourceDirectory -ExtractedDirectory $extract
        & $Progress 'プロジェクトファイルを配置しています…'
        Copy-DirectoryContents -Source $source -Target $project
        Set-TyranoProjectMetadata -ProjectDirectory $project -ProjectId $settings.Id -ProjectTitle $settings.Title
        Write-ProjectGitIgnore -ProjectDirectory $project
        & $Progress ('完了: ' + $project)
        $result = [pscustomobject]@{ Path = $project; PackageUrl = $package.Url; UsedCache = $package.FromCache }
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        return $result
    } catch {
        if (Test-Path -LiteralPath $project) { Remove-Item -LiteralPath $project -Recurse -Force }
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Start-Console {
    param(
        [string]$InitialProjectId = $ProjectId,
        [string]$InitialProjectName = $ProjectName,
        [string]$InitialDirectoryName = $DirectoryName,
        [string]$InitialDestination = $Destination,
        [switch]$Refresh,
        [scriptblock]$ReadInput = { param($prompt) Read-Host $prompt },
        [scriptblock]$ProjectCreator = ${function:New-TyranoProject}
    )
    $id = $InitialProjectId; $title = $InitialProjectName; $directory = $InitialDirectoryName; $destination = $InitialDestination
    if ([string]::IsNullOrWhiteSpace($id)) { $id = & $ReadInput 'プロジェクトID（半角英数字・ハイフン・アンダースコア）' }
    if ([string]::IsNullOrWhiteSpace($title)) { $title = & $ReadInput 'ゲーム表示名（空欄でID）' }
    if ([string]::IsNullOrWhiteSpace($directory)) { $directory = & $ReadInput 'ディレクトリー名（空欄でID）' }
    if ([string]::IsNullOrWhiteSpace($destination)) { $destination = & $ReadInput '作成先フォルダー（空欄で現在のフォルダー）'; if ([string]::IsNullOrWhiteSpace($destination)) { $destination = (Get-Location).Path } }
    try {
        $result = & $ProjectCreator -Id $id -Title $title -Directory $directory -ParentDirectory $destination -Refresh:$Refresh
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
        [Parameter(Mandatory)][string]$InitialDestination,
        [switch]$Refresh,
        [scriptblock]$ProjectCreator = ${function:New-TyranoProject},
        [scriptblock]$ShowMessage = {
            param($message, $title, $buttons, $icon)
            if ($null -eq $buttons) { return [Windows.Forms.MessageBox]::Show($message, $title) }
            return [Windows.Forms.MessageBox]::Show($message, $title, $buttons, $icon)
        }
    )
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $defaultDestination = $InitialDestination
    $form = New-Object Windows.Forms.Form; $form.Text = 'TyranoScript 初期セットアップ'; $form.Size = New-Object Drawing.Size(600, 350); $form.StartPosition = 'CenterScreen'
    $label1 = New-Object Windows.Forms.Label; $label1.Text = 'プロジェクトID'; $label1.Location = New-Object Drawing.Point(20, 22); $label1.AutoSize = $true
    $idBox = New-Object Windows.Forms.TextBox; $idBox.Name = 'projectIdBox'; $idBox.Location = New-Object Drawing.Point(170, 18); $idBox.Width = 390; $idBox.Text = $InitialProjectId
    $label2 = New-Object Windows.Forms.Label; $label2.Text = 'ディレクトリー名（空欄でID）'; $label2.Location = New-Object Drawing.Point(20, 62); $label2.AutoSize = $true
    $directoryBox = New-Object Windows.Forms.TextBox; $directoryBox.Name = 'directoryNameBox'; $directoryBox.Location = New-Object Drawing.Point(170, 58); $directoryBox.Width = 390; $directoryBox.Text = $InitialDirectoryName
    $label3 = New-Object Windows.Forms.Label; $label3.Text = 'ゲーム表示名（空欄でID）'; $label3.Location = New-Object Drawing.Point(20, 102); $label3.AutoSize = $true
    $nameBox = New-Object Windows.Forms.TextBox; $nameBox.Name = 'projectNameBox'; $nameBox.Location = New-Object Drawing.Point(170, 98); $nameBox.Width = 390; $nameBox.Text = $InitialProjectName
    $label4 = New-Object Windows.Forms.Label; $label4.Text = '作成先フォルダー'; $label4.Location = New-Object Drawing.Point(20, 142); $label4.AutoSize = $true
    $destBox = New-Object Windows.Forms.TextBox; $destBox.Name = 'destinationBox'; $destBox.Location = New-Object Drawing.Point(170, 138); $destBox.Width = 310; $destBox.Text = $defaultDestination
    $browse = New-Object Windows.Forms.Button; $browse.Name = 'browseButton'; $browse.Text = '参照…'; $browse.Location = New-Object Drawing.Point(490, 136)
    $browse.Add_Click({ param($sender, $eventArgs); $dialog = New-Object Windows.Forms.FolderBrowserDialog; if ($dialog.ShowDialog() -eq 'OK') { $form = $sender.FindForm(); @($form.Controls.Find('destinationBox', $true))[0].Text = $dialog.SelectedPath } })
    $status = New-Object Windows.Forms.Label; $status.Name = 'statusLabel'; $status.Text = '必要項目を入力してください。'; $status.Location = New-Object Drawing.Point(20, 185); $status.Size = New-Object Drawing.Size(540, 45)
    $run = New-Object Windows.Forms.Button; $run.Name = 'createButton'; $run.Text = '作成'; $run.Location = New-Object Drawing.Point(450, 250); $run.Width = 110
    $form.Tag = [pscustomobject]@{ ProjectCreator = $ProjectCreator; ShowMessage = $ShowMessage; Refresh = [bool]$Refresh }
    $runHandler = {
        param($sender, $eventArgs)
        $form = $sender.FindForm()
        $idBox = @($form.Controls.Find('projectIdBox', $true))[0]
        $nameBox = @($form.Controls.Find('projectNameBox', $true))[0]
        $directoryBox = @($form.Controls.Find('directoryNameBox', $true))[0]
        $destBox = @($form.Controls.Find('destinationBox', $true))[0]
        $status = @($form.Controls.Find('statusLabel', $true))[0]
        $projectCreator = $form.Tag.ProjectCreator
        $showMessage = $form.Tag.ShowMessage
        try {
            $sender.Enabled = $false
            $status.Text = '処理中…'
            $progress = { param($message) $status.Text = $message; [Windows.Forms.Application]::DoEvents() }.GetNewClosure()
            $result = & $projectCreator -Id $idBox.Text -Title $nameBox.Text -Directory $directoryBox.Text -ParentDirectory $destBox.Text -Refresh:$form.Tag.Refresh -Progress $progress
            & $showMessage "作成しました。`n$($result.Path)\index.html" '完了'
            $form.Close()
        } catch {
            & $showMessage $_.Exception.Message 'エラー' 'OK' 'Error'
        } finally {
            $sender.Enabled = $true
        }
    }
    $run.Add_Click($runHandler)
    $form.AcceptButton = $run
    $form.Controls.AddRange(@($label1, $idBox, $label2, $directoryBox, $label3, $nameBox, $label4, $destBox, $browse, $status, $run))
    return $form
}

function Start-Gui {
    param([switch]$Refresh)
    $defaultDestination = if ([string]::IsNullOrWhiteSpace($Destination)) { (Get-Location).Path } else { $Destination }
    $form = New-TyranoForm -InitialProjectId $ProjectId -InitialProjectName $ProjectName -InitialDirectoryName $DirectoryName -InitialDestination $defaultDestination -Refresh:$Refresh
    [Windows.Forms.Application]::Run($form)
}

if ($MyInvocation.InvocationName -ne '.') {
    # Explorer's "Run with PowerShell" supplies no reliable marker that can
    # be distinguished from a terminal launch. No-argument launches therefore
    # open the GUI; use -Console for interactive text mode.
    if ($Gui -or (-not $Console -and [string]::IsNullOrWhiteSpace($ProjectId) -and [string]::IsNullOrWhiteSpace($ProjectName) -and [string]::IsNullOrWhiteSpace($DirectoryName) -and [string]::IsNullOrWhiteSpace($Destination))) { Start-Gui -Refresh:$Refresh }
    else { exit (Start-Console -Refresh:$Refresh) }
}
