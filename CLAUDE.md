# catcam

開発運用ルールはグローバル `~/.claude/CLAUDE.md` を正本とする。ここにはこの PJ 固有の事項だけを置く。

## 何を作るか

カメラ映像の「動いている部分」と「顔」を検出し、macOS 風の偽ウィンドウに入れてデスクトップ上に浮かべる Mac ネイティブアプリ。
元ネタは segcam 系の演出だが、中身は**人間の動いている部分を形の似た猫に差し替える**。

- スコープ: ①形マッチングによる猫差し替え ＋ ②顔→猫顔のランドマーク合わせ
- スコープ外: 生成 AI（img2img 等）による猫化。再提案しない

設計の正本は [docs/DESIGN.md](docs/DESIGN.md)。

## 固有の制約

- 対象マシン: **Apple M1 / メモリ 8GB**。性能・メモリ予算は DESIGN.md §6 を守る
- ツールチェーン: Xcode 15.3 / Swift 5.10（macOS 26.6 上）。Swift 6 の言語機能は使わない。SDK 上限は macOS 14.4 API
- ビルドは SwiftPM（`swift build` / `swift test`）。Xcode プロジェクトファイルは持たない
- 処理は全部ローカル。ネットワーク通信をするコードをアプリに入れない（データセット取得はビルド前の手作業 / スクリプト）
- 純粋ロジック（`CatCore`）は AppKit / AVFoundation / Metal に依存させず、TDD で書く

## ディレクトリ責務

| パス | 責務 |
|---|---|
| `Sources/CatCore/` | 純粋ロジック: 二値マスク処理・連結成分・形状記述子・マッチング・トラッキング・相似変換 |
| `Sources/CatCam/` | アプリ本体: カメラ取り込み・Vision 呼び出し・Metal 描画・オーバーレイ・操作パネル |
| `Sources/catlib-builder/` | オフライン CLI: 猫画像 → 切り抜き・記述子・顔ランドマーク → `catlib/` |
| `Tests/CatCoreTests/` | CatCore の単体テスト |
| `catlib/` | 生成物（git 管理外）。猫ライブラリ |
| `data/` | 元データセット置き場（git 管理外） |
