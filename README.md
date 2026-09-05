# tyrano-init

TyranoScript V6 の新規プロジェクトを自動作成する Windows PowerShell スクリプトです。Windows 11 標準の PowerShell だけで動作します。

## 実行方法

ダウンロードした `tyrano-init.ps1` のプロパティを開き、必要なら「許可する（ブロックの解除）」をチェックしてから実行してください。PowerShellで次のように起動します。

```powershell
.\tyrano-init.ps1
.\tyrano-init.ps1 -ProjectName MyNovel -Destination 'C:\Games'
.\tyrano-init.ps1 -Gui
.\tyrano-init.ps1 -Console
```

引数を省略するとGUIが起動します（エクスプローラーの「PowerShellで実行」でも同じです）。名前と作成先を入力する簡易ウィザードです。

対話式コンソールを使う場合は `-Console` を指定します。引数を指定した場合もコンソール処理になります。

スクリプトは公式の [TyranoScript V6 ダウンロードページ](https://tyrano.jp/dl/v6) から最新版として表示されたスタンダードパッケージを取得します。ネットワーク接続が必要です。作成先に同名フォルダーがある場合は上書きしません。

作成後、[TyranoStudio V6](https://tyrano.jp/dl/v6) を別途入手し、プロジェクト内の `index.html` を選択してください。

## 開発者向けテスト

PowerShellで次を実行します。

```powershell
.\tests\test.ps1
```
