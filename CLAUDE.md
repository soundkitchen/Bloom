# CLAUDE.md

Bloom の開発でアシスタントが従う方針と、プロジェクトの要点。

## 言語(重要)

**コミットメッセージ・ドキュメント・コードコメント・PR 本文は日本語で書く。**
技術用語(API 名・コード識別子)は原語のままで可。`Co-Authored-By:` などの定型 trailer は英語のまま。

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
- リポジトリは Dropbox 配下。`.git` も同期したまま使う(単一マシン前提)。コミットはユーザーが明示的に頼んだときだけ
- `.metal` の構造体と Swift 側の `SimParams` / `Stamp` はメモリレイアウトを一致させること(片方だけ変えると壊れる)
