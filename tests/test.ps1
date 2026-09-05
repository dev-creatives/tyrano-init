$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tyrano-init.ps1')

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
}

$html = '<a href="/download/studio/test.zip">最新版をダウンロード</a>'
Assert ((Get-LatestPackageUrl -Html $html) -eq 'https://tyrano.jp/download/studio/test.zip') '最新版リンクの解析'
Assert ((Resolve-ProjectSettings -Id 'my-game_2026' -Title '' -Directory '').Title -eq 'my-game_2026') '表示名のIDフォールバック'
Assert ((Resolve-ProjectSettings -Id 'my-game_2026' -Title '' -Directory '').Directory -eq 'my-game_2026') 'ディレクトリー名のIDフォールバック'
Assert ((Get-TyranoCacheDirectory) -eq (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'tyrano-init\cache')) '既定のパッケージキャッシュ先'
$packageSource = (Get-Command Get-TyranoPackage).ScriptBlock.ToString()
Assert (-not ($packageSource -match '\$script:DownloadPage|\$script:UserAgent')) 'GUIイベントから実行してもダウンロード設定を解決できること'
$invalidId = $false
try { Resolve-ProjectSettings -Id 'my-game.test' -Title '' -Directory '' | Out-Null } catch { $invalidId = $true }
Assert $invalidId 'IDの不正文字検証'

$form = New-TyranoForm -InitialProjectId 'my-game' -InitialProjectName '' -InitialDirectoryName '' -InitialDestination (Get-Location).Path
$idControl = @($form.Controls.Find('projectIdBox', $true))
$nameControl = @($form.Controls.Find('projectNameBox', $true))
$directoryControl = @($form.Controls.Find('directoryNameBox', $true))
$destinationControl = @($form.Controls.Find('destinationBox', $true))
$browseButton = @($form.Controls.Find('browseButton', $true))
$createButton = @($form.Controls.Find('createButton', $true))
Assert ($idControl.Count -eq 1) 'GUIのプロジェクトID入力欄'
Assert ($nameControl.Count -eq 1) 'GUIのプロジェクト名入力欄'
Assert ($directoryControl.Count -eq 1) 'GUIのディレクトリー名入力欄'
Assert ($destinationControl.Count -eq 1) 'GUIの作成先入力欄'
Assert ($browseButton.Count -eq 1) 'GUIの参照ボタン'
Assert ($createButton.Count -eq 1) 'GUIの作成ボタン'
Assert ($idControl[0].Text -eq 'my-game') 'GUIのプロジェクトID初期値'
Assert ($form.AcceptButton -eq $createButton[0]) 'GUIのEnterキー実行設定'
Assert ($idControl[0].Top -lt $directoryControl[0].Top) 'GUIのIDがディレクトリー名より上'
Assert ($directoryControl[0].Top -lt $nameControl[0].Top) 'GUIのディレクトリー名がタイトルより上'
$formSource = (Get-Command New-TyranoForm).ScriptBlock.ToString()
Assert (-not ($formSource -match '\.TabIndex\s*=')) 'GUIでTabIndexを二重管理しないこと'
Assert ($formSource -match 'AddRange\(@\(\$label1,\s*\$idBox,\s*\$label2,\s*\$directoryBox,\s*\$label3,\s*\$nameBox') 'GUIの追加順が画面順であること'
$form.Dispose()

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('tyrano-test-' + [Guid]::NewGuid())
try {
    $template = Join-Path $tmp 'template'
    $configDirectory = Join-Path $template 'data\system'
    New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $template 'index.html') -Value '<html />' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $configDirectory 'Config.tjs') -Value (@(';System.title = "Old";', ';projectID = old;') -join "`n") -Encoding UTF8
    $sourceZip = Join-Path $tmp 'mock-package.zip'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($template, $sourceZip)

    $cacheDirectory = Join-Path $tmp 'cache'
    $downloadCount = [ref]0
    $getDownloadPage = { [pscustomobject]@{ Content = $html } }.GetNewClosure()
    $downloadPackage = {
        param($url, $destinationPath)
        $downloadCount.Value++
        Copy-Item -LiteralPath $sourceZip -Destination $destinationPath -Force
    }.GetNewClosure()

    $firstPackage = Get-TyranoPackage -CacheDirectory $cacheDirectory -GetDownloadPage $getDownloadPage -DownloadPackage $downloadPackage
    Assert (-not $firstPackage.FromCache) '初回はモックパッケージをダウンロードすること'
    Assert ($downloadCount.Value -eq 1) '初回のモックダウンロード回数'
    $secondPackage = Get-TyranoPackage -CacheDirectory $cacheDirectory -GetDownloadPage $getDownloadPage -DownloadPackage $downloadPackage
    Assert $secondPackage.FromCache '2回目はキャッシュを使用すること'
    Assert ($downloadCount.Value -eq 1) 'キャッシュ利用時に再ダウンロードしないこと'
    $refreshedPackage = Get-TyranoPackage -CacheDirectory $cacheDirectory -Refresh -GetDownloadPage $getDownloadPage -DownloadPackage $downloadPackage
    Assert (-not $refreshedPackage.FromCache) 'Refresh指定時は再ダウンロードすること'
    Assert ($downloadCount.Value -eq 2) 'Refresh指定時のモックダウンロード回数'

    $coreProjectCreator = ${function:New-TyranoProject}
    $mockProjectCreator = {
        param($Id, $Title, $Directory, $ParentDirectory, $Progress, [switch]$Refresh)
        if ($null -eq $Progress) { $Progress = { param($message) Write-Host $message } }
        & $coreProjectCreator -Id $Id -Title $Title -Directory $Directory -ParentDirectory $ParentDirectory -Progress $Progress -CacheDirectory $cacheDirectory -Refresh:$Refresh -GetDownloadPage $getDownloadPage -DownloadPackage $downloadPackage
    }.GetNewClosure()
    Assert ($mockProjectCreator -is [scriptblock]) 'テスト用の作成処理がスクリプトブロックであること'

    $consoleResponses = New-Object 'Collections.Generic.Queue[string]'
    foreach ($value in @('cui-id', 'CUI title', 'cui-directory', (Join-Path $tmp 'cui-output'))) { $consoleResponses.Enqueue($value) }
    $consolePrompts = New-Object 'Collections.Generic.List[string]'
    $readConsoleInput = {
        param($prompt)
        $consolePrompts.Add($prompt)
        return $consoleResponses.Dequeue()
    }.GetNewClosure()
    $consoleExitCode = Start-Console -InitialProjectId '' -InitialProjectName '' -InitialDirectoryName '' -InitialDestination '' -ReadInput $readConsoleInput -ProjectCreator $mockProjectCreator
    $consoleProject = Join-Path (Join-Path $tmp 'cui-output') 'cui-directory'
    Assert ($consoleExitCode -eq 0) 'CUI作成処理が成功すること'
    Assert ($consolePrompts.Count -eq 4) 'CUIが全入力項目を尋ねること'
    Assert (Test-Path -LiteralPath (Join-Path $consoleProject 'index.html')) 'CUIがプロジェクトを作成すること'
    $consoleConfig = Get-Content -LiteralPath (Join-Path $consoleProject 'data\system\Config.tjs') -Raw -Encoding UTF8
    Assert ($consoleConfig -match 'System\.title = "CUI title"') 'CUIがタイトルを反映すること'
    Assert ($consoleConfig -match 'projectID = cui-id') 'CUIがIDを反映すること'

    $notifications = New-Object 'Collections.Generic.List[object]'
    $showMessage = {
        param($message, $title, $buttons, $icon)
        $notifications.Add([pscustomobject]@{ Message = $message; Title = $title })
    }.GetNewClosure()
    foreach ($mode in @('click', 'enter')) {
        $guiProjectId = 'gui-' + $mode
        $guiDirectory = 'gui-directory-' + $mode
        $guiParent = Join-Path $tmp ('gui-output-' + $mode)
        $guiForm = New-TyranoForm -InitialProjectId $guiProjectId -InitialProjectName ('GUI ' + $mode) -InitialDirectoryName $guiDirectory -InitialDestination $guiParent -ProjectCreator $mockProjectCreator -ShowMessage $showMessage
        $guiButton = @($guiForm.Controls.Find('createButton', $true))[0]
        $guiForm.Show()
        [Windows.Forms.Application]::DoEvents()
        if ($mode -eq 'click') { $guiButton.PerformClick() } else { $guiForm.AcceptButton.PerformClick() }
        $guiProject = Join-Path $guiParent $guiDirectory
        Assert (Test-Path -LiteralPath (Join-Path $guiProject 'index.html')) ('GUIの' + $mode + '操作でプロジェクトを作成すること: ' + $notifications[$notifications.Count - 1].Message)
        Assert ($notifications[$notifications.Count - 1].Title -eq '完了') ('GUIの' + $mode + '操作で完了通知を表示すること')
        $guiForm.Dispose()
    }
    $defaultGuiParent = Join-Path $tmp 'gui-default-output'
    $defaultGuiOptions = @{ CacheDirectory = $cacheDirectory; GetDownloadPage = $getDownloadPage; DownloadPackage = $downloadPackage }
    $defaultGuiForm = New-TyranoForm -InitialProjectId 'gui-default' -InitialProjectName 'GUI default' -InitialDirectoryName 'gui-default-directory' -InitialDestination $defaultGuiParent -ProjectOptions $defaultGuiOptions -ShowMessage $showMessage
    $defaultGuiForm.Show()
    [Windows.Forms.Application]::DoEvents()
    $defaultGuiForm.AcceptButton.PerformClick()
    $defaultGuiProject = Join-Path $defaultGuiParent 'gui-default-directory'
    Assert (Test-Path -LiteralPath (Join-Path $defaultGuiProject 'index.html')) 'GUIが既定の作成関数でプロジェクトを作成すること'
    Assert ($notifications[$notifications.Count - 1].Title -eq '完了') 'GUIが既定の作成関数で完了通知を表示すること'
    $defaultGuiForm.Dispose()
    Assert ($downloadCount.Value -eq 2) 'CUIとGUIの統合テストでネットワークダウンロードを行わないこと'
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}

Write-Host 'PASS: すべてのテストに成功しました。' -ForegroundColor Green
