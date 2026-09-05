$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\tyrano-init.ps1')

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
}
$html = '<a href="/download/studio/test.zip">最新版をダウンロード</a>'
Assert ((Get-LatestPackageUrl -Html $html) -eq 'https://tyrano.jp/download/studio/test.zip') '最新版リンクの解析'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('tyrano-test-' + [Guid]::NewGuid())
$src = Join-Path $tmp 'src'; New-Item -ItemType Directory -Path $src -Force | Out-Null
Set-Content -LiteralPath (Join-Path $src 'index.html') -Value '<html />' -Encoding UTF8
$target = Join-Path $tmp 'out'; Copy-DirectoryContents $src $target; Write-ProjectGitIgnore $target
Assert (Test-Path (Join-Path $target 'index.html')) 'index.htmlの配置'
Assert ((Get-Content (Join-Path $target '.gitignore') -Raw) -match 'Thumbs.db') '.gitignoreの内容'
$gitignoreBytes = [IO.File]::ReadAllBytes((Join-Path $target '.gitignore'))
Assert (-not ([Text.Encoding]::UTF8.GetString($gitignoreBytes) -match "`r`n")) '.gitignoreがLFであること'
Remove-Item $tmp -Recurse -Force
Write-Host 'PASS: すべてのテストに成功しました。' -ForegroundColor Green
