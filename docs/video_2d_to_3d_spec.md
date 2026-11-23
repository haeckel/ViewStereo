# ViewStereo 技術検討書および機能仕様書：Apple Depth Pro 2 動画 2D→3D 変換・空間ビデオ生成（Video 2D-to-3D Conversion & Spatial Video Specification）

**対象バージョン**: ViewStereo v0.2.2+ (Phase 1: 動画 2D→3D MVP / Phase 2: Metal GPU 高速化＆アーカイブ映像復元連携)  
**改訂版**: Rev 1.1（2026年11月23日 改訂 — AVFoundation I/O・色空間・ROI・カット検出・MV-HEVC メタデータ・メモリプール・再生ポリシー・容量チェックを詳細化）  
**関連プロダクト**: `ViewStereo`, `StereoStudioCore`, `DepthStereo`

---

## 1. 背景と目的

ViewStereo v0.1.7〜v0.1.8 において、全 9 種の単眼深度推定 Core ML モデル（**Apple Depth Pro 2 Small / Base / Large** を含む）の管理機構と、インテリジェント立体窓最適化（`computeDepthWindowSetup`）付き 2D→3D DIBR 合成パイプラインを実装した。

特に **Apple Depth Pro 2** は Core ML の **Stateful Inference（`MLState`、macOS 15+）** によって前フレームの内部隠れ状態を次フレームへ引き継げるため、従来のフレーム独立型単眼深度モデルで問題となる **時間的フリッカー（奥行きのチラつき）** を大幅に抑制した動画深度推定が可能である。

本仕様では、この Depth Pro 2 の動画適性と [`StereoStudioCore`](file:///Users/okano/マイドライブ/DEV/StereoStudioCore/Sources/StereoStudioCore/Export/VideoExporter.swift) の空間ビデオ（MV-HEVC）エンコード基盤を統合し、ViewStereo における **2D 動画 → 高品位 3D 動画（空間ビデオ / SBS / アナグリフ）変換機能** を定義する。

### 1.1 DepthStereo との明確な役割分担

| プロダクト | 動画における主な役割 |
| :--- | :--- |
| **DepthStereo** | 静止画 1 枚からの 3D メッシュ投影・スイングカメラ演出・クリエイティブな空間ビデオ制作 |
| **ViewStereo** | **入力 2D 動画（ホームビデオ・8mm フィルム・アーカイブ映像等）の時間的一貫性ある 3D ステレオ動画変換**、および Phase 2 での `NAFNetDeblur` / `StereoColorizer` との統合による **歴史的モノクロ映像のカラー 3D 復元** |

---

## 2. システムアーキテクチャと処理パイプライン

### 2.1 全体データフロー

```
[入力 2D 動画 (.mp4 / .mov / .m4v)]
        │
        ▼ (AVAssetReaderVideoCompositionOutput: preferredTransform 自動正立化 + SDR Rec.709 トーンマッピング)
┌────────────────────────────────────────────────────────────────────┐
│ 1. 有効領域 (ROI) 検出 ＆ シーンカット検出                          │
│    ・黒帯（レターボックス / ピラーボックス）を除外した ROI を算出     │
│    ・64×36 輝度 MAD / 16ビンヒストグラム / 暗転復帰 / クールダウン   │
│    └─ カット・暗転復帰検知時: MLState & EMA 統計を即時リセット        │
└────────────────────────────────────────────────────────────────────┘
        │
        ▼
┌────────────────────────────────────────────────────────────────────┐
│ 2. Stateful 深度推論 (ViewStereoVideoDepthSession)                  │
│    ・Apple Depth Pro 2 (S/B/L): MLState を継続保持 (macOS 15+)      │
│    ・他 Core ML モデル / Vision: フレーム独立推論 + EMA             │
└────────────────────────────────────────────────────────────────────┘
        │ (inverse_depth / disparity: 0.0=奥 〜 1.0=手前)
        ▼
┌────────────────────────────────────────────────────────────────────┐
│ 3. ROI 限定・時間的正規化 ＆ ウィンドウ・ダンピング                  │
│    ・ROI 内の 2%〜98% パーセンタイル (pLow, pHigh) を EMA で平滑化   │
│    ・ROI 内のゼロ視差面 focusRatio を EMA で平滑化（飛び出し安定化）  │
└────────────────────────────────────────────────────────────────────┘
        │
        ▼
┌────────────────────────────────────────────────────────────────────┐
│ 4. 対称 1D DIBR 合成 ＆ CVPixelBufferPool 再利用                    │
│    ・Phase 1: 高速 CPU 並列ワーピング + Adaptor の PixelBufferPool  │
│    ・Phase 2: Metal コンピュートシェーダー (ゼロコピー GPU + 境界補間)│
└────────────────────────────────────────────────────────────────────┘
        │ (Left / Right プール済み CVPixelBuffer + 元 PTS)
        ▼
┌────────────────────────────────────────────────────────────────────┐
│ 5. 動画エンコード＆音声合成 (StereoStudioCore / VideoExporter)       │
│    ・先頭 PTS は映像/音声の早い方を基準に startSession              │
│    ・Spatial Video (MV-HEVC .mov / 空間メタデータ完全付与)          │
│    ・Side-by-Side 3D Video (HEVC / H.264 .mp4)                      │
│    ・Anaglyph 3D Video (Dubois .mp4)                                │
│    ・音声: コンテナ互換コーデック維持または AAC 256kbps 再エンコード  │
└────────────────────────────────────────────────────────────────────┘
```

### 2.2 モジュール配置

| コンポーネント | 所属モジュール | 役割 |
| :--- | :--- | :--- |
| **`ViewStereoVideoDepthSession`** | `ViewStereo` | 動画専用の Stateful 深度推論セッション（`MLState` 保持、ROI 検出、暗転・クールダウン付きシーンカット検出、EMA 時間正規化、ウィンドウ・ダンピング） |
| **`ViewStereoVideoProcessor`** | `ViewStereo` | `AVAssetReaderVideoCompositionOutput` による正立・SDR 統一デコード、プログレッシブプレビュー生成、書き出しパイプライン、推定ファイルサイズ／空き容量チェック、進捗・キャンセル制御 |
| **`VideoExporter`（拡張）** | `StereoStudioCore` | 遅延 `startSession(atSourceTime:)`（先頭 PTS オフセット対応）、`CVPixelBufferPool` 再利用、MV-HEVC 空間メタデータ完全付与（FoV / Baseline / DisparityAdjustment / HeroEye）、音声トラックエンコード |
| **`ViewStereoViewModel` / `ContentView`** | `ViewStereo` | 3-Pane ツリーブラウザの動画認識、再生ポリシー準拠タイムライン制御、書き出し前空き容量警告、動画書き出し UI |

---

## 3. コア技術仕様

### 3.1 映像 I/O・回転メタデータ・色空間・音声・PTS 仕様（AVFoundation）

1. **回転メタデータ（`preferredTransform`）の正立化**
   - iPhone 縦撮り動画等はピクセルが横向きで格納され、トラックの `preferredTransform` で 90°/270° 回転が指定されている。未正立のまま深度推論・水平 DIBR を行うと視差方向が上下に回転し立体視が破綻する。
   - **仕様**: デコード段に `AVAssetReaderVideoCompositionOutput` ＋ `AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)` を必ず使用し、**推論・DIBR の前段階で正立ピクセルへ変換**する。書き出し動画には回転メタデータを付与せず、正立ピクセルとして出力する。
2. **HDR 動画（10-bit HLG / Dolby Vision / Rec.2020）の扱い**
   - iPhone 撮影動画の多くは 10-bit HDR であるため、変換方針を明示しないと 8-bit BGRA デコード時に白飛びや色褪せが生じる。
   - **Phase 1 仕様（SDR Rec.709 統一）**: `AVMutableVideoComposition` の色空間プロパティに `AVVideoColorPrimaries_ITU_R_709_2` / `AVVideoTransferFunction_ITU_R_709_2` / `AVVideoYCbCrMatrix_ITU_R_709_2` を明示設定し、AVFoundation 標準の HDR→SDR トーンマッピングを経由して 8-bit sRGB/Rec.709 として推論・DIBR・書き出しを行う。
   - **Phase 2 以降**: 10-bit HDR（HLG / Rec.2020）ネイティブ維持パイプライン（推論入力のみ SDR トーンマップ、DIBR 描画と MV-HEVC エンコードは 10-bit `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` 等を維持）を拡張予定。
3. **音声トラックとコンテナ互換性**
   - `.mov` 内の Linear PCM や ALAC 音声をそのまま `.mp4` コンテナへパススルーすると `AVAssetWriter` が失敗する。
   - **仕様**: 出力コンテナと互換性のあるコーデック（例：AAC）のみパススルー可能とし、**コンテナ非互換コーデック（PCM / ALAC 等）または汎用安全パス（Phase 1 標準）では `AVAssetReaderTrackOutput` で Linear PCM へデコードした上で AAC 256kbps（48kHz / Stereo）へ再エンコード**して出力する。
4. **先頭 PTS オフセットと VFR（可変フレームレート）対応**
   - トリミング済み動画や iPhone 動画では先頭フレームの `PTS` が `0` でない場合がある。
   - **仕様**: `AVAssetWriter` は `startWriting()` のみ事前実行し、映像・音声それぞれの最初の `CMSampleBuffer` の `PTS` を比較して **より早い方の先頭 `PTS` を基準に `startSession(atSourceTime: firstPTS)` を 1 回だけ呼ぶ**。以降の全フレームは元サンプルの `PTS` をそのまま維持して投入し、VFR 環境でも音ズレを構造的に防止する。

### 3.2 Stateful 推論・ROI・シーンカット検出・時間的正規化

1. **`MLState` のライフサイクル管理（macOS 15+）**
   - クリップ変換開始時に `let state = model.makeState()` を 1 回だけ生成して保持し、連続フレームへ同一 `state` を渡す。
   - 設定 `releaseAIModelsAfterGeneration == true` の場合でも、**動画処理中はフレームごとに解放せず、書き出し完了・キャンセル・セッション破棄時に 1 回だけ `releaseCachedModels()` を実行**する。
2. **アスペクト比と有効映像領域（ROI）ベースのパーセンタイル／`focusRatio` 計算**
   - 縦動画（9:16）や 4:3 アーカイブ映像、あるいは黒帯（レターボックス／ピラーボックス）を含む映像で黒帯を含めて 2%〜98% パーセンタイルや `focusRatio` を算出すると、黒帯の深度値に引っ張られて正規化が破綻する。
   - **仕様**: 各フレーム（または初回／カット境界フレーム）で上下左右の黒帯（平均輝度 $< 8/255$ かつ分散極小の連続帯）を検出し、**有効映像領域 ROI（正規化矩形 `uMin..uMax, vMin..vMax`）内のピクセルのみを対象にパーセンタイル `(pLow, pHigh)` および `focusRatio` を算出**する。
3. **シーンカット検出のエッジケース対策**
   - 64×36 縮小輝度による隣接フレーム間の MAD（`> 0.28`）および 16 ビン輝度ヒストグラム L1 距離（`> 0.45`）に加え、以下の 2 条件を組み込む：
     - **最小カット長クールダウン（フラッシュ誤検知防止）**: 直前のリセットから `minCutCooldownFrames = 10` フレーム未満の場合は急激な輝度変化（ストロボ・フラッシュ等）による連続リセットを抑止する。
     - **暗転フェード検出**: フレーム平均輝度が `0.04` 未満（完全暗転／黒フレーム）を検知した際に暗転フラグを立て、輝度が復帰した最初のフレームで `MLState` および EMA 履歴を自動リセットする（クロスディゾルブ／暗転フェード後の残像防止）。
4. **時間的正規化（EMA / Lock Depth Range）とウィンドウ・ダンピング**
   - **EMA 正規化（デフォルト）**: 生パーセンタイル $(p_{\text{low}, t}, p_{\text{high}, t})$ に対し、$\alpha \in [0.02, 1.0]$ で指数移動平均を適用（カット／暗転復帰時は $\alpha = 1.0$ で即時追従）。
   - **固定レンジ（`Lock Depth Range`）**: 固定カメラ映像向けに、基準フレームの $(p_{\text{low}}, p_{\text{high}})$ を完全固定。
   - **ゼロ視差面ダンピング**: ROI 内の外周 8% 帯域の飛び出しを抑えつつ算出した `focusRatio` も EMA で緩やかに追従させる。
5. **シーク時ウォームアップと GOP デコード負荷（プログレッシブ更新）**
   - 長い GOP を持つ H.264/HEVC 動画でシーク確定時に直前フレーム群（$t - 3\Delta t \dots t$）を同期デコードすると応答が数秒止まる恐れがある。
   - **仕様**: タイムラインのドラッグ終了時は、まず **ターゲット時刻 $t$ の単フレーム推論結果を即座に表示** し、その直後にバックグラウンドの **キャンセル可能タスクで $t - 2\Delta t, t - \Delta t, t$ のウォームアップ推論を実行し、完了時にキャンバスをプログレッシブに上書き更新** する（ユーザーが次のシーク／再生を開始した場合は即座にキャンセル）。

### 3.3 MV-HEVC 空間メタデータ ＆ `CVPixelBufferPool` 設計

1. **MV-HEVC 空間メタデータの完全付与（`StereoStudioCore/VideoExporter`）**
   - Apple Vision Pro / iOS で正しく空間ビデオとして認識・快適再生させるため、QuickTime メタデータおよび VideoToolbox / CoreMedia 圧縮プロパティに以下をすべて明示設定する：
     - `com.apple.quicktime.spatial.format-version = "1.0"`
     - `com.apple.quicktime.spatial.aggressors-seen = 0`
     - `kVTCompressionPropertyKey_MVHEVCVideoLayerIDs = [0, 1]`
     - `kVTCompressionPropertyKey_MVHEVCViewIDs = [0, 1]`
     - `kVTCompressionPropertyKey_MVHEVCLeftAndRightViewIDs = [0, 1]`
     - `kVTCompressionPropertyKey_HasLeftStereoEyeView = true` / `HasRightStereoEyeView = true`
     - `kVTCompressionPropertyKey_StereoCameraBaseline`（標準 `65000` μm = 65mm）
     - `kVTCompressionPropertyKey_HorizontalDisparityAdjustment`（`0`）
     - `kCMFormatDescriptionExtension_HorizontalFieldOfView`（ミリ度単位、例：`55000` = 55°）
     - `kCMFormatDescriptionExtension_HeroEye`（左眼 `kCMFormatDescriptionHeroEye_Left`）
2. **`CVPixelBufferPool` によるバッファ再利用**
   - 4K 動画等で毎フレーム `CVPixelBufferCreate` を行うとメモリ断片化やスパイクが発生する。
   - **仕様**: `AVAssetWriterInputPixelBufferAdaptor.pixelBufferPool` および `AVAssetWriterInputTaggedPixelBufferGroupAdaptor.pixelBufferPool` から `CVPixelBufferPoolCreatePixelBuffer` でバッファを取得・再利用する（プール未生成時のみ `CVPixelBufferCreate` へフォールバック）。
   - バックプレッシャー制御として `isReadyForMoreMediaData` を監視し、未処理フレームの滞留を最大 2〜3 フレーム以内に抑える。

### 3.4 推奨エンジンとパフォーマンス目安

| エンジン | 解像度 | ピークメモリ | 動画での推奨用途 |
| :--- | :---: | :---: | :--- |
| **Apple Depth Pro 2 Small** | 854×480 | 約 1.5 GB | 長尺動画の高速変換・タイムラインプレビュー |
| **Apple Depth Pro 2 Base** | 854×480 | 約 2.5 GB | **標準推奨**（速度と境界精度のバランス） |
| **Apple Depth Pro 2 Large** | 854×480 | 約 4.0 GB | 短尺アーカイブ映像・Vision Pro 空間ビデオ最高品質書き出し |
| その他 Core ML モデル | モデル依存 | 0.2〜2.2 GB | 利用可能（`MLState` 非対応のため EMA 平滑化で動作し、UI 上で Depth Pro 2 を推奨案内） |

---

## 4. UI / UX・パフォーマンス・安全性仕様

### 4.1 タイムラインのリアルタイム再生ポリシー
- Depth Pro 2 推論＋CPU DIBR（Phase 1）を 4K / 30fps・60fps で完全リアルタイム再生することは負荷が高いため、以下の動作ポリシーを明確に定義する：
  1. **再生中（Play）**: プレビュー解像度を **最大長辺 720px 以下** に自動制限して高速推論・高速 DIBR を行い、前フレームの推論が完了していない場合は **フレームスキップを許容** して UI フリーズを防止する（`MLState` は継続維持）。
  2. **停止・コマ送り・シーク確定時**: **最大長辺 1280px** の高精細プレビューへ自動切替し、細部の立体感・エッジ品質を確認可能とする（Depth Pro 2 利用時はプログレッシブ・ウォームアップ更新を実施）。

### 4.2 書き出し前のディスク空き容量チェック
- 空間ビデオ（MV-HEVC）や Full SBS の長尺書き出しは数 GB 以上になる場合がある。
- **仕様**: 書き出し開始前に、動画尺・出力解像度・フォーマットから推定ビットレート（例：1080p Spatial/SBS で約 25〜40 Mbps、4K で約 60〜100 Mbps）をもとに **推定出力サイズ** を算出し、出力先ボリュームの空き容量（`URLResourceKey.volumeAvailableCapacityForImportantUsageKey`）と比較する。
- **安全マージン（推定サイズ × 1.2 + 200 MB）を下回る場合は、書き出し前に `NSAlert` で空き容量不足を警告** し、ユーザーが中止または続行を選択できるようにする。

### 4.3 3-Pane ワークスペースでの動画操作
- **左ツリーブラウザ**: `.mp4` / `.mov` / `.m4v` を認識し、`AVAssetImageGenerator` サムネイルと `VIDEO` バッジを表示。
- **中央キャンバス下部**: 動画選択時のみ `videoTimelineBar`（再生/一時停止 `Space`、前後 1 フレーム送り、シークスライダー、現在時刻/総尺）を表示。
- **右インスペクター**: Depth Pro 2 推奨ガイド、`Virtual Baseline (%)` / `Depth Gamma` / `Temporal Smoothing` / `Lock Depth Range` / `Auto Cut Detection`、および動画専用 `exportFooter`（形式選択・進捗バー・処理 fps・キャンセル）。

---

## 5. 段階的実装ロードマップ

### Phase 1（MVP：動画 2D→3D 変換 ＆ 空間ビデオ書き出し）
- [x] `StereoStudioCore/VideoExporter.swift` の拡張（`CVPixelBufferPool` 再利用、先頭 `PTS` 基準の遅延 `startSession`、MV-HEVC 空間メタデータ完全付与、AAC 音声エンコード）
- [x] `ViewStereoVideoDepthSession` の実装（Depth Pro 2 `MLState` 継続、ROI 黒帯除外、暗転・クールダウン付きシーンカット検出、EMA 時間正規化、`focusRatio` ダンピング）
- [x] `ViewStereoVideoProcessor` の実装（`AVAssetReaderVideoCompositionOutput` 正立＋SDR Rec.709 トーンマッピング、プログレッシブ・ウォームアッププレビュー、ディスク空き容量チェック、書き出し＆キャンセル）
- [x] 3-Pane ツリーブラウザの動画ファイル対応、再生ポリシー準拠タイムライン UI、動画書き出し UI、日英ローカライズ

### Phase 2（GPU 高速化 ＆ アーカイブ映像復元パイプライン統合）
- [x] **Metal GPU DIBR コンピュートシェーダー**: `ViewStereoMetalDIBR` による 1 パス左右生成（共有メモリ `MTLBuffer` + 背景優先・エッジ保護オクルージョン補間で輪郭チラつきを抑制、非対応環境は CPU フォールバック）
- [x] **10-bit HDR ネイティブ維持パイプライン**: `isHDR` 自動判定に基づき、`videoPreserveHDR` 有効時は Rec.2020 / HLG（Main10 HEVC）でデコード・書き出しを実施
- [x] **アーカイブ復元パイプライン連携**: `NAFNetDeblur`（光学デブラー）・`StereoColorizer`（AI カラー化）・ヴィンテージトーン補正を動画プレビューおよび書き出しに統合
- [x] **既存 3D 動画（SBS）の救済変換**: 片側破損・過大視差の SBS 動画から片眼（左／右）を抽出して Depth Pro 2 で快適視差 3D 動画へ再構築

---

## 6. 制約事項・既知リスクと検証項目

### 6.1 OS・ハードウェア・Phase 1 既知制限
- **macOS 15.0+**: `MLState` による Depth Pro 2 Stateful 推論のフル活用が可能。macOS 14.x ではフレーム独立推論＋EMA 時間正規化で動作する。
- **DIBR オクルージョン境界の時間的チラつき（Phase 1 既知制限）**: 深度マップが時間的に安定していても、前景の輪郭周辺に生じるオクルージョン（遮蔽解除領域）の 1D 補間がフレーム独立であるため、輪郭に微細なジリつきが生じる場合がある。Phase 2 の Metal GPU シェーダーにおける背景優先サンプリングおよび時間一貫エッジ補間で対処する。
- **HDR ソース（Phase 1 既知制限）**: Phase 1 では SDR Rec.709 へトーンマッピングして出力する（白飛び・色褪せを防止）。HDR 維持は Phase 2 対象。

### 6.2 検証項目
1. **回転・縦動画検証**: iPhone 縦撮り動画（90° `preferredTransform`）が正立し、水平方向に正しい立体視差が付与されること。
2. **HDR トーンマッピング検証**: iPhone HDR (HLG/Dolby Vision) 動画で白飛び・色褪せが起きないこと。
3. **ROI 黒帯除外検証**: レターボックス／ピラーボックス付き動画で黒帯に引っ張られず自然な奥行きレンジになること。
4. **時間的一貫性・カット・暗転検証**: 人物横切り時の Depth Pumping が抑えられ、フラッシュで誤リセットせず、カット境界および暗転復帰時に残像が残らないこと。
5. **先頭 PTS オフセット・VFR・音声同期検証**: トリミング済み VFR 動画（先頭 PTS > 0、PCM/ALAC 音声含む）で `.mov` / `.mp4` 双方とも音ズレやエラーなく書き出せること。
6. **Apple Vision Pro / QuickTime 空間メタデータ検証**: 出力 MV-HEVC `.mov` に FoV / Baseline / DisparityAdjustment / HeroEye メタデータが正しく格納され、空間ビデオとして再生できること。
7. **メモリプール・容量チェック・キャンセル安全性**: 長尺書き出しでメモリスパイクせず、空き容量不足時に事前警告が出ること、キャンセル時にリソースと一時ファイルがクリーン解放されること。
