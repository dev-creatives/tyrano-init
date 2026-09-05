# tyrano-init

TyranoScript V6 の新規プロジェクトを自動作成する Windows PowerShell スクリプトです。Windows 11 標準の PowerShell だけで動作します。

## 実行方法

ダウンロードした `tyrano-init.ps1` のプロパティを開き、必要なら「許可する（ブロックの解除）」をチェックしてから実行してください。PowerShellで次のように起動します。

```powershell
.\tyrano-init.ps1
```
```powershell
.\tyrano-init.ps1 -ProjectId my-novel_2026 -ProjectName '私のノベル' -Destination 'C:\Games'
```
```powershell
.\tyrano-init.ps1 -Gui
```
```powershell
.\tyrano-init.ps1 -Console
```

引数を省略するとGUIが起動します（エクスプローラーの「PowerShellで実行」でも同じです）。名前と作成先を入力する簡易ウィザードです。

対話式コンソールを使う場合は `-Console` を指定します。引数を指定した場合もコンソール処理になります。

プロジェクトIDは半角英数字、ハイフン、アンダースコアだけを使用してください。ゲーム表示名はブラウザのタブやアプリのウィンドウに表示されます。表示名とディレクトリー名を空欄にするとプロジェクトIDが使われます。ディレクトリー名を指定した場合も、プロジェクトIDは `Config.tjs` の内部識別子として別に保存されます。

スクリプトは公式の [TyranoScript V6 ダウンロードページ](https://tyrano.jp/dl/v6) から最新版として表示されたスタンダードパッケージを取得します。ネットワーク接続が必要です。作成先に同名フォルダーがある場合は上書きしません。

## 作成後の操作

作成後、[TyranoStudio V6](https://tyrano.jp/dl/v6) を別途入手し、プロジェクト内の `index.html` を選択してください。
この後の操作詳細は[公式チュートリアル](https://tyrano.jp/usage/tutorial/ready_v5)を参照してください。

## 技術情報

### ダウンロードキャッシュ

取得したパッケージは既定で `%LOCALAPPDATA%\tyrano-init\cache` に保存します。同じ公式ダウンロードURLの有効なZIPファイルがキャッシュにあれば、次回以降の作成時は再ダウンロードせずに利用します。`-Refresh` を付けて実行すると、キャッシュを使わずにパッケージを再取得します。

### 開発者向けテスト

PowerShellで次を実行します。

```powershell
.\tests\test.ps1
```
