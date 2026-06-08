# CLAUDE.md

Bloom の開発でアシスタントが従う方針と、プロジェクトの要点。

## 言語(重要)

**コミットメッセージ・ドキュメント・コードコメント・PR 本文は日本語で書く。**
技術用語(API 名・コード識別子)は原語のままで可。`Co-Authored-By:` などの定型 trailer は英語のまま。

## Git 運用 / 開発フロー(重要)

リモート: `origin` = `git@github.com:soundkitchen/Bloom.git`(`main` が `origin/main` を追跡)。

機能実装・バグフィックスは **topic ブランチ → PR → 別スレッドでレビュー → マージ** の順で進める:

1. **topic ブランチを切る**(`main` から)。命名: 機能は `feature/<名前>`、修正は `fix/<名前>`
2. そのブランチで実装・コミット(コミットメッセージは日本語)
3. **`origin` に push して Pull Request を作成**(`gh pr create`)。PR 本文は日本語(末尾の定型 trailer は英語)
4. **別スレッド(別の会話)でレビューを受ける**。レビューが通ってからマージする
5. マージ後に topic ブランチを削除

- **`main` へ直接コミット/マージしない**(初期セットアップ等の例外を除く)。レビュー前のマージは行わない
- push・PR 作成・マージはユーザーが明示的に頼んだときに行う(勝手に push しない)
- **ドキュメントを実装と同期させてからコミットする**: 機能追加・修正で挙動や構成が変わったら、同じブランチ/PR の中で関連ドキュメント(`docs/idea.md` ロードマップ・`docs/architecture.md`・必要に応じて `README.md`/`CLAUDE.md`・`docs/devlog/`)も更新し、コードとドキュメントに差異が無い状態にしてからコミット/PR にする

## プロジェクト概要

雑なストロークが流体シミュレーションとブラシ補助で水彩・水墨のような絵になる macOS ネイティブ(Swift + Metal)の 2D 描画アプリ。構想とロードマップは `docs/idea.md`。

## ビルド・実行

XcodeGen + xcodebuild 構成。`project.yml` が真実で、`Bloom.xcodeproj` は生成物(git 管理外)。

```sh
make gen    # project.yml から Bloom.xcodeproj を生成(project.yml を変えたら実行)
make build  # ビルド
make test   # ユニットテスト
make run    # アプリ起動
make demo   # デモストロークを自動実行し /tmp/bloom-snap に wet/dry PNG を出力
```

検証モード(キャンバス全面・自動スナップショット。`--snapshot-dir <dir>` 付き):
- `--demo` … wet.png / dry.png
- `--demo-dwell` … 置きっぱなしの溜まり(320px キャンバス)
- `--demo-layers` … レイヤー合成・順序・表示切替
- `--demo-undo` … ストロークの取り消し
- `--demo-saveload` … `.bloom` 保存→消去→読込で復元
- `--demo-anim` … 数フレーム → GIF / スプライトシート / PNG 連番
- `--demo-onion` … オニオンスキン(前フレームのゴースト)

描き味やレンダリングの変更は、この PNG スナップショットを目視で確認しながら詰める。

## 構成

- `BloomCore/`(framework・AppKit 非依存) … 描画コア。`SimulationEngine`(滲みシミュレーション + レイヤー/フレーム + 合成)、`Simulation.metal`(GPU カーネル)、`AnimationExport`(GIF/スプライト/連番)、`InputSample`(入力抽象 + 擬似筆圧)
- `BloomApp/`(app・AppKit + MetalKit) … `CanvasView`(入力 → コア API)、`InspectorView`(ブラシ/色/レイヤー)、`TimelineView`(フレーム/再生/オニオン)、`AppDelegate`(ウィンドウ・メニュー・再生)
- `BloomCoreTests/` … ユニットテスト
- `docs/` … `idea.md`(構想)、`architecture.md`(コードの現在形)、`devlog/`(日付つき経緯)、`images/`

設計原則: **UI とコアの分離**(コアはヘッドレスで動き、将来の MCP サーバも同じコマンド API を叩く)。詳細は `docs/architecture.md`。

## 注意点

- Xcode 26+ は Metal ツールチェーンが別コンポーネント。未導入なら `xcodebuild -downloadComponent MetalToolchain`
- 署名は手動 + 証明書ハッシュ直指定(`project.yml`)。ハッシュはマシン固有なので別マシンでは `security find-identity -v -p codesigning` で差し替え
- DerivedData はリポジトリ外(`~/Library/Developer/Xcode/DerivedData/Bloom-cli`)。Dropbox 同期のノイズを避けるため
- リポジトリは Dropbox 配下。`.git` も同期したまま使う(単一マシン前提)。履歴の遠隔バックアップは GitHub(`origin`)。コミット/push/マージは「Git 運用」節に従い、ユーザーが明示的に頼んだときだけ
- `.metal` の構造体と Swift 側の `SimParams` / `Stamp` はメモリレイアウトを一致させること(片方だけ変えると壊れる)
