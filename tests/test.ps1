$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tyrano-init.ps1')

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
}
$html = '<a href="/download/studio/test.zip">最新版をダウンロード</a>'
Assert ((Get-LatestPackageUrl -Html $html) -eq 'https://tyrano.jp/download/studio/test.zip') '最新版リンクの解析'
Assert ((Resolve-ProjectSettings -Id 'my-game_2026' -Title '' -Directory '').Title -eq 'my-game_2026') '表示名のIDフォールバック'
Assert ((Resolve-ProjectSettings -Id 'my-game_2026' -Title '' -Directory '').Directory -eq 'my-game_2026') 'ディレクトリー名のIDフォールバック'
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
