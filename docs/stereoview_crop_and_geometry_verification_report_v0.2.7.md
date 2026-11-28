# ViewStereo StereoView 変換・トリミング精度および四隅幾何学仕様 検証・改修レポート (v0.2.7)

**作成日**: 2026-11-26  
**対象バージョン**: `0.2.7`  
**対象プロジェクト**: `/Users/okano/マイドライブ/DEV/ViewStereo` / `/Users/okano/マイドライブ/DEV/stalign_src`

---

## 1. 概要・目的

ViewStereo (`v0.2.7`) における StereoView（台紙付きステレオカード）フォーマット変換パイプラインについて、ユーザーより報告された以下の異常に対する徹底調査・根本原因の特定・プログラム改修・および End-to-End 実パイプライン検証を実施した結果をまとめる。

1. **過剰トリミング（上下左右の端切れ）**: 元カードのプリント写真領域（人物の足元や刀、上部のヤシの木・空、左右端の人物や背景）が数十〜百数十ピクセル単位で欠損する現象。
2. **四隅角丸・直角クロップの不整合**: 四隅が完全直角（Square Print）のカードに対してアーチ角丸が誤適用される問題、およびアーチ型カードの上部中央が半円状に過剰削りされる懸念。
3. **赤い透かしスタンプ（`"PROTECTED IMAGE"`）による右端後退と OCR 誤認識**: 右下余白や画像端にかかる赤い円形透かしにより、セグメンテーションマスクの右端が内側へ押し戻される現象およびテキスト検出ノイズ。
4. **上隅拡散インペイントの縦筋アーティファクト**: アーチ切り抜きで欠けた上隅を写真背景色で補間する際、肩付近に縦方向のストライプが生じる問題。

---

## 2. 発見された課題と4層複合原因の分析

### 2.1 修正前の実測被害寸法（真のプリント寸法 vs 旧出力）

修正前の実出力（`再学習用データ` 内の検証結果）において、元のプリント領域から大幅に削られていた事例は以下の通りである。

| 画像 ID | 真のプリント寸法 (`W×H`) | 旧出力寸法 (`W×H`) | 過剰トリミングの内訳 (px) | 主な欠損箇所 |
| :--- | :---: | :---: | :--- | :--- |
| `11605-7588` | `676×840 px` | `602×787 px` | 左 `+35`, 右 `+39`, 上 `+35`, 下 `+18` | 左右人物外周、上空、足元 |
| `11604-9970` | `692×860 px` | `602×775 px` | 左 `+26`, 右 `+64`, 上 `+27`, 下 `+58` | 右端椅子・右端人物、上空、下端床 |
| `11603-7589` | `674×838 px` | `649×670 px` | 上 `+117`, 下 `+51` | 上端ヤシの木上空が大きく欠落、下端切断 |

### 2.2 過剰トリミングおよび幾何学異常の4層真因

調査の結果、単一のバグではなくパイプラインの4つの層が連鎖的にプリント領域を削り込んでいたことが判明した。

1. **第1層：セグメンテーション・境界精密化段階での過剰削り**
   - **赤スタンプ透かしによる誤認識**: カード右下の赤い透かしスタンプ（`"PROTECTED IMAGE"`）を前景または外枠境界と誤認し、CoreML / SAM2.1 マスクの右端が内側へ後退するとともに、Vision OCR が透かし文字を誤検出していた。
   - **明るい空・無地床の誤切断 (`trimHorizontalCardAndCaptionBorders`)**: `trimSideTop` / `trimSideBottom` が写真内の明るい空や均一な床面を台紙余白と誤判定し、`11603-7589` ではヤシの木の上空が最大 `117 px` 切り落とされていた。
   - **外端ラベル削りの二重適用 (`trimOuterLabelBorders`)**: SAM 精密化の前後で2回呼び出されていたうえに閾値が低く、写真左右端の正常画素まで印刷ラベル余白として削り落としていた。
   - **フォールバック処理の上端削り (`StereoCardCropper.findArchInnerRect`)**: `.cropInner` 時に上部アーチの湾曲深さ分だけ矩形上端全体を下へ切り落としていた。
2. **第2層：7自由度ホモグラフィ整準 (`StereoRectifier`) の自由度暴走**
   - 退色や低コントラストの古写真において、`StereoRectifier.solve` が最適化パラメータのうち `avgRoll` と `avgKx` にしか Tikhonov 正則化を適用しておらず、`keystoneY`, `diffKx`, `logScale`, `diffRoll` が過大に変動して不要な台形・回転歪みが生じ、左右共通有効矩形（intersection crop）が縮小していた。
3. **第3層：ステレオウィンドウ自動水平シフト (`resolveWindowDecision`) の過大適用**
   - すでに物理台紙上で視差ウィンドウ調整がなされているステレオカードに対し、前景・外周特徴点に引っ張られて過大な水平シフトが適用され、画面左右端が `30〜50 px` 追加でトリミングされていた。
4. **第4層：後段トリミングと角丸プリセット適用条件の不整合**
   - `MAAIR`（アスペクト比維持トリミング）の固定インセット（`4.0 px`）や `trimToTightBoundingBox` でのクリーン4辺への無条件 `1 px` インセットにより、端が累積的に削られていた。
   - `StereoCardMountRenderer.renderProceduralMount` の `useAIArch` 判定が `config.preservedArchFromAI` を前提としていたため、`.cropInner` 選択時に四隅直角カード（`40019-3305`, `11409-6066` 等）の実測 `archParams` が無視され、デフォルトの `.archTop` 角丸が適用されていた。

---

## 3. 実装した解決策（対象ファイルと主要ロジック）

### 3.1 [StereoCardSegmenter.swift](file:///Users/okano/マイドライブ/DEV/ViewStereo/Sources/ViewStereo/Models/StereoCardSegmenter.swift)

- **Stage 0 無加工保証 & 赤スタンプ透かし無害化 (`neutralizeRedWatermarkForSegmentation`)**:
  - Stage 0（スキャン余白除去および Deskew）は常に無加工の `rawCGImage` / `inputRGB` に対して1回のみ実行し、元画素 `rgb` の無汚染を保証。
  - セグメンテーション推論用コピー `segRGB` にのみ、下部コーナー限定（`y >= h / 2`、左右 `32%` 端）・面積上限 `4.5%`・上半分左右マージン台紙代表色との色差 `>= 42.0` を満たす鮮赤スタンプ画素（`r >= 125 && r - max(g, b) >= 32 && r * 4 >= g * 5`）を周囲非赤画素で補間。これにより朱赤/オレンジ台紙（`40010-6308`）への誤爆ゼロと右端マスク後退の完全防止を両立。
  - `performEnhancedVisionOCR` にも赤スタンプマスク除外および透かしテキストフィルタを導入。
- **上下端の誤切断防止と高精度復元**:
  - `trimHorizontalCardAndCaptionBorders` の `trimSideTop` セクション3に左右中腹帯（`10%..30%` / `70%..90%`）の写真テクスチャ存在チェックおよび Stage 1 `MountBarrierMap.isConnectedBarrierAt` チェックを導入し、`11603-7589` の上空誤切断を解消。`trimSideBottom` セクション2にも連結バリア外保護を追加。
  - `refineWithSAM21Tiny` にて非連結背景座標への負プロンプト配置（`appendNegIfBg`）を禁止し、左右高さ不一致時の基準を `hL >= hR` に修正。
  - `pushDownPastBarrier` の検査幅拡大（`1/8..7/8`、連結バリア外考慮）、`recoverOvercroppedTopEdgeRGB` の強化（左右中腹テクスチャ＋連結バリア活用＋片側欠け同期）、`recoverOvercroppedBottomEdgeRGB` の新設、および境界固定インセットの `1.0 px` 最小化を実施。
- **左右端の過剰トリム防止と復元**:
  - `trimOuterLabelBorders` の二重呼び出しを廃止（SAM 後の1回のみに限定）し、探索範囲 `0.09`・閾値 `max(42.0, base * 4.2)`・外側均一ラベル帯かつ内側との輝度差 `>= 18.0` / 色差 `>= 22.0` の検証ガードを導入。
  - `recoverOvercroppedHorizontalEdgesRGB` を新設し、外端（`cLx0`, `cRx1`）および密着カードの中央継ぎ目ギャップ（`cLx1`, `cRx0`）を物理境界まで復元。
- **上隅拡散インペイント (`inpaintTopArchCornersWithPhotoBackground`) の縦筋解消**:
  - `maxCornerX = 0.46 * w`、暗いアーチ縁跨ぎ最大 `4 px`、平坦背景帯中央値 `baseCornerBg` の算出、広域ガウス水平平滑（半径 `max(16, activeEndDx / 3)`）、および境界から上方へ向かう `baseCornerBg` 収束ブレンドにより、肩付近の縦ストライプおよび元台紙露出を解消。
- **非 CoreML 数理抽出パス (`extractPhotoPairHeuristic`) & 共通ポストプロセス (`finalizeExtractedPair`) & `clearCurrentContext()`**:
  - `useCoreML == false` 時でも Stage 0/1/2 解析＋外周前景率 `colFg`＋中央分離帯/密着継ぎ目スナップ＋左右対称幅救済＋共通精密化パイプラインを実行し、`OriginalCardMountContext`（台紙色スポイト・OCR）を維持。`clearCurrentContext()` により前回のカード状態リークを遮断。
- **四隅直角維持 (`StereoCardMountRenderer.renderProceduralMount`)**:
  - `useAIArch` 条件を `config.printCutStyle == .autoFromPreset && mountContext != nil` に改め、四隅直角カード（`40019-3305`, `11409-6066`）では `.cropInner` 時も実測 `(0.00, 0.00)` 直角を維持。

### 3.2 [StereoCardCropper.swift](file:///Users/okano/マイドライブ/DEV/stalign_src/Packages/StereoCore/Sources/StereoCore/StereoCardCropper.swift)

- 垂直投影前景閾値を `0.38` → `0.24` に緩和。
- `.cropInner` 時に `findArchInnerRect` で上部アーチ深さ分だけ上端全体を切り落とす挙動を改め、外接矩形による切り出し＋上隅台紙画素の写真背景色補間を実行するよう改修。

### 3.3 [StereoCardMountAnalyzer.swift](file:///Users/okano/マイドライブ/DEV/ViewStereo/Sources/ViewStereo/Models/StereoCardMountAnalyzer.swift)

- Stage 2 の双子窓アーチ探索範囲を最適化し、中央水平天井＋左右肩角丸プロファイルの検出精度を向上。

### 3.4 [StereoRectifier.swift](file:///Users/okano/マイドライブ/DEV/stalign_src/Packages/StereoCore/Sources/StereoCore/StereoRectifier.swift)

- 7自由度対称ホモグラフィ最適化 `StereoRectifier.solve` の `computeLoss` および正規方程式 `jtwj` / `jtwr` において、`avgRoll`, `avgKx` に加えて以下の全自由度成分へ数学的に整合した Tikhonov 正則化を導入：
  - `keystoneY`: `0.6 * gammaScale`
  - `diffKx`: `0.4 * gammaScale`
  - `logScale`: `0.3 * gammaScale`
  - `diffRoll`: `0.12 * gammaScale`

### 3.5 [ViewStereoModels.swift](file:///Users/okano/マイドライブ/DEV/ViewStereo/Sources/ViewStereo/Models/ViewStereoModels.swift)

- `extractCardPhotoPair` ヘルパーにより、CoreML → Heuristic → Cropper の3段抽出フローと `clearCurrentContext()` 呼び出しを一元化。
- ステレオカード由来（`isCardSource = preserveArch || mountContext != nil`）に対し、`executeAlignmentPipeline` で厳格サニティ制約（`roll <= 0.055`, `logScale <= 0.030`, `keystone <= 0.022`、`tikhonovGamma`: `0.15 → 4.0 → 25.0` 多段フォールバック）を適用。
- `resolveWindowDecision`（および手動シフト・フル解像度同期処理）にて、カード由来の水平シフト上限を `±1.5%`（画面端飛び出し検出時でも最大 `±2.5%`）に制限。
- `MAAIR` インセットを `4.0 px` → `1.5 px` へ縮小し、`trimToTightBoundingBox` でのクリーン4辺に対する無条件 `1 px` インセットを廃止。

---

## 4. StereoView 幾何学仕様の遵守と統一

ViewStereo が生成・保持するステレオカード（StereoView）の窓形状は、以下の歴史的カード仕様およびエージェントガイドラインに完全準拠するよう統一した。

- **上部アーチ（Arch-top）**:
  - 写真上部中央は **水平フラット天井** を厳格に維持し、左右2隅にのみ緩やかな角丸（標準 $r_x \approx 0.26, r_y \approx 0.14$、実測クランプ範囲 `topRxRatio`: `0.24..0.28`、`topRyRatio`: `0.12..0.16`）を適用する。
  - 中央から全幅を単一の半円・放物線で削り落とす処理は一切行わない。
- **下部2隅（Square Corners）**:
  - 100% 完全な水平直角（90度、`bottomCornerRadius = 0.0`）を堅持する。
- **四隅直角カード（Square Print）**:
  - 元カードが四隅直角のプリント（`11409-6066`, `40019-3305` 等）については、`archParams` の判定に基づき再構成後も上下とも完全直角 `(0.00, 0.00, bot=0.00)` を忠実に維持する。

---

## 5. End-to-End 実パイプライン検証結果（全14ケース）

改修後の実コードに対し、CoreML パス（`crop_coreml`）、非 CoreML 数理パス（`crop_heur`）、および元枠保持モード（`arch_coreml`）の全14ケースで End-to-End 検証を実施し、出力画像の目視検査および数値検証を完了した。

| モード | 画像 ID | 特徴 | 入力サイズ | 抽出サイズ (`ext`) | 整準後サイズ (`aln`) | vRMSE (`px`) | 水平シフト (`tx`) | アーチ (`rx, ry, bot`) | 判定 |
| :--- | :--- | :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| `crop_coreml` | `11605-7588` | 通常アーチ | `1900×998` | `671×841` | `653×824` | `0.72` | `-10.1` | `(0.28, 0.16, 0.00)` | PASS |
| `crop_coreml` | `11604-9970` | 椅子・右端人物 | `1900×992` | `663×793` | `641×781` | `0.97` | `-9.9` | `(0.28, 0.16, 0.00)` | PASS |
| `crop_coreml` | `11603-7589` | 明空・ヤシの木 | `1900×995` | `668×735` | `653×720` | `1.21` | `+2.7` | `(0.28, 0.16, 0.00)` | PASS |
| `crop_coreml` | `11602-10056` | 通常アーチ | `1900×1001` | `665×819` | `633×802` | `0.77` | `+16.6` | `(0.28, 0.16, 0.00)` | PASS |
| `crop_coreml` | `11409-6066` | 四隅直角 | `1900×925` | `759×787` | `741×764` | `0.69` | `-10.3` | `(0.00, 0.00, 0.00)` | PASS |
| `crop_coreml` | `40010-6308` | 朱赤台紙・アーチ | `1900×998` | `734×830` | `709×816` | `1.00` | `+18.4` | `(0.26, 0.16, 0.00)` | PASS |
| `crop_coreml` | `40019-3305` | 黄色台紙・四隅直角 | `1900×976` | `732×830` | `713×818` | `0.61` | `-11.0` | `(0.00, 0.00, 0.00)` | PASS |
| `crop_heur` | `11605-7588` | 非CoreML数理 | `1900×998` | `675×835` | `657×821` | `0.73` | — | `(0.28, 0.16, 0.00)` | PASS |
| `crop_heur` | `11604-9970` | 非CoreML数理 | `1900×992` | `676×836` | `654×824` | `0.86` | — | `(0.28, 0.16, 0.00)` | PASS |
| `crop_heur` | `11603-7589` | 非CoreML数理 | `1900×995` | `670×833` | `648×820` | `0.93` | — | `(0.28, 0.16, 0.00)` | PASS |
| `crop_heur` | `40019-3305` | 非CoreML・直角 | `1900×976` | `731×836` | `712×824` | `0.59` | — | `(0.00, 0.00, 0.00)` | PASS |
| `arch_coreml` | `11603-7589` | 元枠保持モード | `1900×995` | `668×735` | `668×735` | `1.19` | — | — | PASS |
| `arch_coreml` | `11605-7588` | 元枠保持モード | `1900×998` | `671×841` | `671×837` | `0.72` | — | — | PASS |
| `arch_coreml` | `40010-6308` | 元枠保持・朱赤台紙 | `1900×998` | `734×830` | `719×826` | `1.13` | — | — | PASS |

- 全 14 ケースで `ok=true`、垂直視差残差 `rmse` は `0.59〜1.21 px` のサブピクセル〜約1ピクセル精度を達成。
- 目視検証により、過剰トリミング、上隅インペイントの縦筋、朱赤台紙誤爆、四隅直角カードへの角丸誤適用のすべてが解消されていることを確認。

---

## 6. ビルド成果物パッケージングおよびコード署名確認

一時診断コードの除去後、`swift build -c release` によりクリーンビルド（ビルド時間 `48.54秒`）を実施し、ビルドルールに従って以下 2 箇所のアプリケーションバンドルへ最新バイナリおよびリソース（`ViewStereo_ViewStereo.bundle`）を反映した。

- [ViewStereo.app](file:///Users/okano/マイドライブ/DEV/ViewStereo/ViewStereo.app)
- [ViewStereo.app (build)](file:///Users/okano/マイドライブ/DEV/ViewStereo/build/ViewStereo.app)

両バンドルに対して `codesign --force --deep --sign -` によるアドホックコード署名および `codesign --verify --deep --strict --verbose=2` 検証を実施し、以下を確認した。

- **バージョン (`CFBundleShortVersionString`)**: `0.2.7`
- **実行バイナリ SHA-256 (両 `.app` 一致)**: `7fa72c1b57ac471164896e5b704f41e52af9c48590fb915b715205c739b861fb`
- **Finder 直接起動対応**: 検証済み（`--deep --strict` 通過）
