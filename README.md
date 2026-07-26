# 黒板サンプル（chalkboard_sample）

maths アプリの体験「こくばん」から、以下の4要素だけを自己完結のサンプルとして
切り出したもの。maths リポジトリ本体には依存しない。

- 黒板（背景）: 深緑のビネット + 拭き跡・チョーク粉のムラ（`CustomPainter`）
- チョークによる描画: フラグメントシェーダの粒状ノイズで粉っぽい掠れを表現
- 黒板消し: 同じノイズを `BlendMode.dstOut` で使い「まだらに消えて掠れが残る」
- 全クリア

## ファイル構成

```
chalkboard_sample/
  lib/main.dart        # サンプル全体（1ファイル完結）
  shaders/chalk.frag   # チョーク/黒板消し共通の粒状ノイズシェーダ
  README.md
```

## 新しいサンプルプロジェクトへの組み込み方

1. プロジェクトを作る:

   ```sh
   flutter create chalkboard_sample
   cd chalkboard_sample
   ```

2. このフォルダの `lib/main.dart` と `shaders/chalk.frag` を同じパスへコピーする
   （`shaders/` ディレクトリはプロジェクト直下に新規作成）。

3. `pubspec.yaml` に依存とシェーダ宣言を追加する:

   ```yaml
   dependencies:
     flutter:
       sdk: flutter
     draw_your_image: ^0.12.0   # ストロークの入力・保持・saveLayer 合成

   flutter:
     uses-material-design: true
     shaders:
       - shaders/chalk.frag
   ```

4. 実行する:

   ```sh
   flutter pub get
   flutter run
   ```

## 実装のポイント

- **層構造**: 黒板の地（背景 Painter）→ 透明背景の `Draw`（ストローク層）→ 操作 UI
  の3層 `Stack`。`Draw` は strokes を saveLayer 内で合成するため、黒板消しの
  `BlendMode.dstOut` はストローク層のチョークだけを消し、下の地には影響しない。
- **チョークの掠れ**: `shaders/chalk.frag` が値ノイズ + ハッシュでアルファを
  まだらに抜く。チョークは `srcOver`、黒板消しは同じシェーダを `dstOut` で使う
  （合成モードは Dart 側の `Paint` が決め、シェーダは色・アルファだけを返す）。
- **決定性**: 黒板のムラは固定シード、ストロークの粒はストローク始点由来のシードで
  生成するため、リビルドしても見た目がチラつかない。
- **フォールバック**: シェーダ読み込み前・失敗時はベタ塗り / 均一消しに落ちるので、
  どの環境でも一応動く。
- **筆圧**: チョークは `PathBuilderMode.pressureSensitive` を使うため、Apple Pencil
  等のスタイラスでは筆圧で太さが変わる。黒板消しは均一な帯（`catmullRom`）。

見た目の調整値（色・粒度・掠れ具合など）は `main.dart` の `ChalkboardTuning` に
全部まとまっている。

## 本体アプリとの差分

本体（maths）の「こくばん」からは、サンプルの範囲を絞るため以下を省いている:

- 多言語対応（AppBar ごと削除。全画面を黒板にした）
- 独自の「ぷっくり」ボタン（`PuffyPressable`）→ 素の `GestureDetector` ボタンに置換
- ペン優先のパームリジェクション（指で描き始めた後にペンへ乗り換える処理）
- 動画撮影用 9:16 ガイド枠の隠しコマンド
