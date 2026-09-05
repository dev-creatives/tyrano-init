$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tyrano-init.ps1')

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
}

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
Assert ($idControl[0].TabIndex -eq 0) 'GUIのIDのTabIndex'
Assert ($directoryControl[0].TabIndex -eq 1) 'GUIのディレクトリー名のTabIndex'
Assert ($nameControl[0].TabIndex -eq 2) 'GUIのタイトルのTabIndex'
Assert ($destinationControl[0].TabIndex -eq 3) 'GUIの作成先のTabIndex'
Assert ($browseButton[0].TabIndex -eq 4) 'GUIの参照ボタンのTabIndex'
Assert ($createButton[0].TabIndex -eq 5) 'GUIの作成ボタンのTabIndex'
$form.Dispose()

$html = '<a href="/download/studio/test.zip">最新版をダウンロード</a>'
Assert ((Get-LatestPackageUrl -Html $html) -eq 'https://tyrano.jp/download/studio/test.zip') '最新版リンクの解析'
Assert ((Resolve-ProjectSettings -Id 'my-game_2026' -Title '' -Directory '').Title -eq 'my-game_2026') '表示名のIDフォールバック'
Assert ((Resolve-ProjectSettings -Id 'my-game_2026' -Title '' -Directory '').Directory -eq 'my-game_2026') 'ディレクトリー名のIDフォールバック'
$consoleSource = (Get-Command Start-Console).ScriptBlock.ToString()
Assert ($consoleSource -match 'IsNullOrWhiteSpace\(\$ProjectName\).*Read-Host') 'コンソールでタイトル入力を促すこと'
Assert ($consoleSource -match 'IsNullOrWhiteSpace\(\$DirectoryName\).*Read-Host') 'コンソールでディレクトリー名入力を促すこと'
$emptyValuesAccepted = $false
try {
    New-TyranoProject -Id 'binding-test' -Title '' -Directory '' -ParentDirectory ([IO.Path]::GetTempPath()) -Progress { throw 'binding probe' } | Out-Null
} catch { $emptyValuesAccepted = $_.Exception.Message -match 'binding probe' }
Assert $emptyValuesAccepted '空欄のタイトル・ディレクトリー名を受け付けること'
$invalidId = $false
try { Resolve-ProjectSettings -Id 'my-game.test' -Title '' -Directory '' | Out-Null } catch { $invalidId = $true }
Assert $invalidId 'IDの不正文字検証'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('tyrano-test-' + [Guid]::NewGuid())
$src = Join-Path $tmp 'src'; New-Item -ItemType Directory -Path $src -Force | Out-Null
Set-Content -LiteralPath (Join-Path $src 'index.html') -Value '<html />' -Encoding UTF8
$target = Join-Path $tmp 'out'; Copy-DirectoryContents $src $target; Write-ProjectGitIgnore $target
Assert (Test-Path (Join-Path $target 'index.html')) 'index.htmlの配置'
Assert ((Get-Content (Join-Path $target '.gitignore') -Raw) -match 'Thumbs.db') '.gitignoreの内容'
$gitignoreBytes = [IO.File]::ReadAllBytes((Join-Path $target '.gitignore'))
Assert (-not ([Text.Encoding]::UTF8.GetString($gitignoreBytes) -match "`r`n")) '.gitignoreがLFであること'
$configPath = Join-Path $target 'data\system'; New-Item -ItemType Directory -Path $configPath -Force | Out-Null
Set-Content -LiteralPath (Join-Path $configPath 'Config.tjs') -Value (@(';System.title = "Old";', ';projectID = old;') -join "`n") -Encoding UTF8
Set-TyranoProjectMetadata -ProjectDirectory $target -ProjectId 'my-game_2026' -ProjectTitle '私のゲーム'
$config = Get-Content -LiteralPath (Join-Path $configPath 'Config.tjs') -Raw -Encoding UTF8
Assert ($config -match 'System\.title = "私のゲーム"') '表示名のConfig.tjs反映'
Assert ($config -match 'projectID = my-game_2026') 'IDのConfig.tjs反映'
Remove-Item $tmp -Recurse -Force
Write-Host 'PASS: すべてのテストに成功しました。' -ForegroundColor Green
