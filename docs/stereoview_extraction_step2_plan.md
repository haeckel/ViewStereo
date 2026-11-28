# 歴史的ステレオカード抽出：Step 2（1クリック補正 UI・3クラスモデル再学習）方針・引き継ぎ書

作成日: 2026-11-27  
対象アプリ: `ViewStereo`（関連コア: `stalign_src/Packages/StereoCore`）

---

## 1. 位置づけと全体ロードマップ

本ドキュメントは、設計資料 [歴史的ステレオカード抽出技術設計.pdf](file:///Users/okano/マイドライブ/DEV/ViewStereo/docs/歴史的ステレオカード抽出技術設計.pdf) に基づく段階的刷新プロジェクトにおいて、**Step 1 の完了を受けて Step 2 を新しいチャットから迷わず開始するための実装方針・引き継ぎ書**である。

### 全体フェーズ構成
1. **Step 1（完了）**: 切り抜き＆貼り付け基盤の刷新（SAM 2.1 対称2パス改善 ＋ GPU 4ステップ境界仕上げ ＋ RGB/マスク同時ワープ ＋ 左右交差マスク貼付）
2. **Step 2（本フェーズ）**: **1クリック正負点補正 UI（Model-in-the-Loop）＋ 事前学習済み 3クラス専用モデル再学習＆統合**
3. **Step 3（将来展望）**: 片側のみに写り込んだ赤スタンプ・局所傷の修復（SMR+：対向目ワープ補完、および MI-GAN / Big-LaMa による ROI インペイント）

### 確定方針（全ステップ共通の基本仕様）
- **「案1（元カードの実輪郭を活かす）」を標準採用**:
  - 深いドーム型アーチ、緩やかな肩角丸、全四隅角丸、完全直角のそれぞれについて、**元プリントの実輪郭**を尊重して抽出・再貼付する。
  - 写真が存在しない外側の余白領域を、浅い共通角丸に合わせて強引に補間（色拡散・捏造）しない。

---

## 2. Step 1 完了サマリー（実装済み資産と検証結果）

### 2.1 変更・追加済みファイル一覧と主要シンボル

| ファイル | 主要シンボル・実装内容 |
| :--- | :--- |
| [MetalWarpRenderer.swift](file:///Users/okano/マイドライブ/DEV/stalign_src/Packages/StereoCore/Sources/StereoCore/MetalWarpRenderer.swift) | `warpHomographyBilinearMask` カーネル、`warpMask8(...)`（画像 RGB と同一ホモグラフィ行列でアルファマスクを同時ワープ） |
| [StereoCardMaskRefiner.swift](file:///Users/okano/マイドライブ/DEV/ViewStereo/Sources/ViewStereo/Models/StereoCardMaskRefiner.swift) | `StereoCardMaskRefiner.shared.refineMask`（`upsampleBilinearFloat` → `MPSImageGuidedFilter` [`kd=9, epsilon=2.0e-2, band=3`] → `CIMorphologyMinimum` → `CIGaussianBlur` [`0.65px`]、ソフトウェアレンダラ／全ゼロ出力フォールバック付き） |
| [StereoCardSegmenter.swift](file:///Users/okano/マイドライブ/DEV/ViewStereo/Sources/ViewStereo/Models/StereoCardSegmenter.swift) | 深いアーチ対応（`rx=0.50, ry=0.12...0.45`）、SAM 2.1 Tiny の `.pointsAndBox` 2パス（正3点、負点に四隅・中央谷間・対向写真中央、`fillRatio >= 0.78`, `iou >= 0.62`, `area >= expected * 0.72`）、ImageEncoder / MaskDecoder の NaN/Inf 検知と `.cpuAndGPU` / `.cpuOnly` フォールバック、`extendBoundaryColorsOutsideMask`（5px 境界色パディング）、`OriginalCardMountContext.unmaskedAlphaL/R`、`StereoCardMountRenderer` での `printAlphaMask` 直接貼付 |
| [ViewStereoModels.swift](file:///Users/okano/マイドライブ/DEV/ViewStereo/Sources/ViewStereo/Models/ViewStereoModels.swift) | RGB＋マスク同時ホモグラフィワープとトリミング伝播（`trimEdgeColorFringe`, `trimToTightBoundingBox`）、`buildIntersectionMask`（AND 交差マスク ＋ 左右面積比・交差率安全チェック：`LR < 85% || Inter < 80%` で警告、`LR < 72% || Inter < 65%` で大きい側へフォールバック） |

### 2.2 Step 1 実カード検証結果（9枚）
- `MaskRefinerOrientation`: `topAvg=255, botAvg=0`（期待値 `top>=200, bot<=30`）
- `MetalRenderer=true`、MPS エラーなし・NaN クラッシュなし
- 検証対象 9枚すべて `ok=true`、`maskWarn=none`
- 左右マスク一致率・交差率: **`LR=98.6%〜100.0%`**、**`Inter=98.6%〜100.0%`**
- 深いドーム（`11603-7589`, `11602-7575-1`, `11600-6702-1`, `65日光の瀧=color`, `11604-9970`）、四隅角丸（`11601-7257`, `13df9e55-..._6407`）、直角（`11409-6066`, `1c6a3919-..._1818x1008`）のすべてで黄色三日月残り・肌色ぼかし帯・切り抜き崩壊が解消済み
- 一時検証コード除去後のクリーン Release ビルド完了、[ViewStereo.app](file:///Users/okano/マイドライブ/DEV/ViewStereo/ViewStereo.app) および [build/ViewStereo.app](file:///Users/okano/マイドライブ/DEV/ViewStereo/build/ViewStereo.app) の両方へ最新バイナリとリソースバンドルを反映し、ad-hoc 署名（`codesign --force --deep --sign -`）および厳格検証（`codesign --verify --deep --strict`）済み

### 2.3 Step 1（Option B）で判明した設計上の重要教訓
次の2点は、Step 2 の対話的 UI やバッチ推論でも**絶対に後退させない**不変条件とする：
1. **Box＋正負点＋面積／Fill Ratio 制約の維持**: SAM 2.1 は Box なしの点プロンプト単独だと前景被写体（人物や小物）へ収縮する「紙工作切り抜き崩壊」が起きやすいため、原則として `.pointsAndBox` および面積比・Fill Ratio フィルタを維持すること。
2. **Guided Filter の穏やかなエッジ追従設定**: `MPSImageGuidedFilter` に強すぎる設定（例: `epsilon=1e-3`）を与えるとアーチ輪郭に沿ってノコギリ歯状のジャギーが発生する。滑らかな幾何確率マップ（または滑らかなモデル確率マップ）に対し、穏やかな設定（`kd=9, epsilon=2.0e-2, band=3` 相当）を基準とすること。

---

## 3. Step 2 技術方針（2つの柱）

Step 2 では、個別のカード不具合を対症療法パッチ（CPU RGB 閾値）で追う「もぐら叩き」構造から完全に脱却するため、**UI による即座救済・データ蓄積** と **専用モデルの刷新** の2本柱を連携させる。

### 柱 A：1クリック正負点補正 UI ＋ Model-in-the-Loop（教師データ自動蓄積）

#### 目的
自動抽出が外れた少数の難読カードに対して、コード改修なしで画面上から **1〜2 クリックで正確に修正できる手段** をユーザーに提供し、同時にその修正結果を学習用教師データとして自動的に資産化する。

#### 関連ファイル
- UI: [ContentView.swift](file:///Users/okano/マイドライブ/DEV/ViewStereo/Sources/ViewStereo/Views/ContentView.swift)
- 状態管理・パイプライン接続: [ViewStereoModels.swift](file:///Users/okano/マイドライブ/DEV/ViewStereo/Sources/ViewStereo/Models/ViewStereoModels.swift)
- SAM 2.1 推論・マスク生成: [StereoCardSegmenter.swift](file:///Users/okano/マイドライブ/DEV/ViewStereo/Sources/ViewStereo/Models/StereoCardSegmenter.swift)

#### 要件
1. **左右プリント別のクリック補正操作**:
   - 元カードプレビュー（または専用の補正モード／オーバーレイ）上で、「左写真／右写真」の編集対象を選択。
   - **クリック＝正プロンプト（緑点：写真内側）**、**Option/Alt＋クリック または モード切替＝負プロンプト（赤点：台紙・外側）** を配置でき、「1手戻す（Undo）」「リセット（初期自動プロンプトへ戻る）」を備える。
2. **ImageEncoder 埋め込みキャッシュによる低遅延インタラクティブ更新**:
   - 重い `SAM2_1TinyImageEncoderFLOAT16` の特徴抽出結果をカードごとにメモリキャッシュし、ユーザーがクリックするたびには軽量な `SAM2_1TinyPromptEncoderFLOAT16` ＋ `SAM2_1TinyMaskDecoderFLOAT16` のみを再実行して即座にマスクプレビューを更新する。
   - Step 1 で実装した NaN/Inf 検知と `.cpuAndGPU` / `.cpuOnly` フォールバックを対話推論パスにもそのまま継承する。
3. **Step 1 後段パイプラインへのシームレス接続**:
   - ユーザーが確定（または即時適用）した生マスクに対して、既存の GPU 4ステップ仕上げ（`StereoCardMaskRefiner.shared.refineMask`）→ `MetalWarpRenderer.warpMask8` による同時ワープ → `buildIntersectionMask` による左右交差マスク貼付をそのまま通し、最終カード生成に反映する。
4. **承認済み 3クラスマスク PNG 自動書き出し（Model-in-the-Loop）**:
   - 修正確定・保存時に、元カード画像と対になる **3クラスラベル PNG（`0=台紙/背景, 1=左写真, 2=右写真`）** を専用データセットディレクトリへ自動（または承認ボタンで）書き出す。
5. **SAM 2.1 `Small` モデル評価（任意オプション）**:
   - 初期推論および少ないクリック数での追従精度がさらに必要な場合、`Tiny` から `Small` への差し替え可否（メモリ・速度・精度のトレードオフ）を評価・検討する。

---

### 柱 B：事前学習済み 3クラス専用モデル再学習とバッチ統合

#### 現行の課題（[train_card_seg.py](file:///Users/okano/マイドライブ/DEV/ViewStereo/tools/train_card_seg.py)）
- 現行モデル `StereoCardSeg.mlmodelc` は `StereoCardUNet` による **合成データのみ・スクラッチ学習・2クラス（`0:台紙/背景, 1:写真窓`）・512×256** の軽量 CoordConv U-Net である。
- 実カードの劣化表現（明るい空と台紙の同化、黄ばみ、赤スタンプ、極薄余白、中央の暗い影や癒着）を直接学習していないため、モデル単体の精度限界を大量の CPU 閾値パッチで補う構成になっている。

#### 既存画像資産
- [学習用データ](file:///Users/okano/マイドライブ/DEV/ViewStereo/学習用データ)（現在 **209 枚**）
- [再学習用データ](file:///Users/okano/マイドライブ/DEV/ViewStereo/再学習用データ)（現在 **18 枚**）

#### 新モデルの設計方針
1. **3クラス出力への刷新**:
   - クラス定義を `0: 台紙/背景`, `1: 左写真`, `2: 右写真` の **3クラス** とする。
   - 左右をクラスレベルで分離することで、中央境界での左右癒着（1つの塊に結合してしまう現象）を構造的に防止する。
2. **事前学習済みバックボーン ＋ 実カード教師データ学習**:
   - EfficientNet 系 U-Net++ または SegFormer 系など、事前学習済みエンコーダを持つセグメンテーションモデルをベースとする。
   - 柱 A の検証・補正を通じて整備した実カードの正解 3クラスマスク（目標 **100〜200 枚**）を用いてファインチューニングする。
3. **実戦的データ拡張（Data Augmentation）**:
   - Albumentations / Augraphy 系の経年劣化・紙質テクスチャ拡張、低コントラスト化、極薄余白（フレームぎりぎり）クロップ拡張。
   - **赤スタンプ合成拡張（重要）**: 写真の上に「PROTECTED IMAGE」等の赤文字・スタンプを合成する際、**正解マスクは写真の領域（クラス 1 または 2）を維持**させ、スタンプ部分でマスクが欠けない耐性を学習させる。
4. **Core ML 変換と高速バッチエンジン統合**:
   - PyTorch 学習済みモデルを Core ML（`.mlpackage` → `.mlmodelc`）へ変換し、`ViewStereo` バンドルリソースに組み込む。
   - 通常のバッチ処理・自動読込では高速な新 3クラスモデルを主エンジンとし、面積比不均衡・低信頼度・形状異常を検知した場合のみ **Step 1 強化版 SAM 2.1 へ自動フォールバック** する二段構えにする。
5. **旧 CPU RGB パッチ群の段階的整理**:
   - 新 3クラスモデル＋GPU 境界仕上げの統合検証が通った段階で、`StereoCardSegmenter.swift` 内に蓄積した脆弱な CPU 上の色閾値トリミング／補正パッチ群を安全に整理・削減する。

---

## 4. Step 2 実装マイルストーン（推奨手順）

| フェーズ | 内容 | 主な成果物・完了条件 |
| :--- | :--- | :--- |
| **Phase 2-1** | SAM 2.1 埋め込みキャッシュ＆対話的プロンプト推論 API 整備 | `StereoCardSegmenter` に画像埋め込みキャッシュと、任意点の正負プロンプト配列＋Box から左右マスクを再生成するメソッドを実装 |
| **Phase 2-2** | SwiftUI 1クリック正負点補正 UI ＋ 3クラスマスク PNG 書き出し | `ContentView` / `ViewStereoModels` に補正クリック UI・ライブプレビュー・確定時の再ワープ貼付・3クラス PNG 書き出しを実装 |
| **Phase 2-3** | 実カード教師データの整備 | Step 1 自動出力＋Phase 2-2 UI 補正を使い、`再学習用データ`（18枚）および `学習用データ`（209枚）から 100〜200 枚規模の 3クラス正解セットを構築 |
| **Phase 2-4** | 3クラス事前学習モデル学習スクリプト実装・学習・Core ML 変換 | 3クラスモデル（U-Net++ 等）＋劣化／赤スタンプ拡張で学習し、検証セット（特に `再学習用データ` 群）で従来比精度向上を確認し `.mlmodelc` 化 |
| **Phase 2-5** | アプリ統合・フォールバック接続・回帰検証・配布ビルド | 高速バッチ推論＋SAM 2.1 フォールバックを統合し、全検証ケース確認の上、`ViewStereo.app` と `build/ViewStereo.app` を更新・署名 |

---

## 5. Step 3 展望（参考：本フェーズでは未着手）

Step 2 完了後、必要に応じて以下の修復機能へ進む：
- **SMR+（対向目ワープ修復）**: 右下隅の赤スタンプ等「片側のみに写り込んだノイズ・欠損」に対し、視差／ホモグラフィ整合させた反対側の目（本物の写真画素）からテクスチャを転写・ブレンドして AI 捏造なしで消去する。
- **MI-GAN / Big-LaMa ROI 修復**: 対向目にも写っていない物理的な穴や欠けに対してのみ、`.cpuAndGPU` 指定・ROI クロップ限定で生成修復を行う。

---

## 6. ビルド・運用ルール（新チャット引き継ぎチェックリスト）

新しいチャットで実装・ビルドを行う際は、ワークスペースの [AGENTS.md](file:///Users/okano/マイドライブ/DEV/AGENTS.md) に従い以下を必ず遵守する。

1. **ビルド成果物の2箇所配置・署名義務**:
   - `swift build -c release --disable-sandbox --package-path /Users/okano/マイドライブ/DEV/ViewStereo` でビルド後、最新バイナリと `ViewStereo_ViewStereo.bundle`（および更新された `.mlmodelc` リソース）を次の**両方**へ反映すること：
     - `/Users/okano/マイドライブ/DEV/ViewStereo/ViewStereo.app`
     - `/Users/okano/マイドライブ/DEV/ViewStereo/build/ViewStereo.app`
   - 反映後、`codesign --force --deep --sign -` と `touch` を両バンドルに適用し、`codesign --verify --deep --strict` で検証すること。
2. **ステレオカード幾何学仕様**:
   - Step 1 で確定した「案1（元カードの実輪郭尊重）」を維持し、下部直角カードは 100% 直角、下部角丸カードは下角丸を活かすこと。

---

## 7. 新しいチャット開始用の引き継ぎプロンプト例

Step 2 を開始する際は、新しいチャットを開いて以下をそのまま貼り付けてください：

```text
@ViewStereo/docs/stereoview_extraction_step2_plan.md を読んで前提を把握してください。
Step 1（案1ベース・GPUガイドフィルタ＋同時ワープ＋左右交差マスク）は完了しています。
今回から Step 2 を進めます。まずは Phase 2-1（SAM 2.1 埋め込みキャッシュ＆対話的プロンプト推論 API）と Phase 2-2（SwiftUI 1クリック正負点補正 UI ＋ 3クラスマスク PNG 書き出し）の設計と実装計画からお願いします。
```
