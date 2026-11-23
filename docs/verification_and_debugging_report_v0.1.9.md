# ViewStereo 総合検証・デバッグ・品質改善レポート (v0.1.9)

**実施日**: 2026年11月24日  
**対象バージョン**: ViewStereo v0.1.9 (Build 1)  
**対象プラットフォーム**: macOS 14.0+ (Apple Silicon arm64)  
**署名ステータス**: Developer ID Application: IZUMI OKANO (83V7E97Y25) 適合  

---

## 📌 概要

ViewStereoの全機能（19世紀歴史的ステレオカード自動セグメンテーション、7自由度対称ホモグラフィ整準、デジタルリマウント、片目AI Depth 3Dサルベージ、動画2D-to-3D変換）が出揃った段階において、プロダクション品質への総仕上げとして以下の5つのフェーズによる総合点検・デバッグ・負荷検証を実施しました。

1. **フェーズ1: UI・ローカライズ・ショートカットの静的チェック**
2. **フェーズ2: 状態遷移・キャッシュ整合性・メモリ解放の精査**
3. **フェーズ3: 実機・実データ動作テストおよびエッジケース確認**
4. **フェーズ4: メモリリーク・パフォーマンス・連続負荷テスト**
5. **フェーズ5: リリースビルド ＆ 配布パッケージ（DMG）検証**

本検証により、**潜在的なメモリリークの解消**、**特定の特殊カードで発生していたプロセス強制終了（Fatal error クラッシュ）の根絶**、**日英ローカライズの100%対称化**、および**327MBの署名済みDMG生成**を完了しました。

---

## 🔍 フェーズ1: UI・ローカライズ・ショートカットの静的チェック

### 1. 検出された課題
* **ハードコードされた日本語（全32箇所）**:
  * **警告バナー（3箇所）**: `ViewStereoModels.swift` 内で `let warn = "⚠️ 特徴点不足 (アライメント信頼性低)"`, `"⚠️ ステレオ不成立 (左右不一致)"`, `"⚠️ 左右逆の疑い (偽視)"` が直接日本語で代入され、英語環境でも日本語が表示される不具合。
  * **ツールチップ（10箇所）**: `ContentView.swift` 内の `.customTooltip(...)` で左右スワップ、比較、処理中止、位置合わせリセット、鶏卵紙/明治手彩色風プリセット適用などが直接日本語記述。
  * **ウェルカム・ガイドカード（9箇所）**: ドラッグ＆ドロップ前の未読み込み画面ガイドカード4枚のタイトル・説明文（「作業フォルダを開く」「AI 空間・自動整準」「手彩色風・台紙設定」「空間写真・書き出し」）が直接日本語記述。
  * **エラーメッセージ（10箇所）**: `ViewStereoDepthSynthesizer.swift` および `ViewStereoVideoProcessor.swift` の `NSError.userInfo`。
* **Localizable.strings 未定義のUIキー**:
  * `Card Size`, `Colorization Mode`, `Input Mode`, `Card Mode`, `Pairing`, `OK` など。
* **ショートカットのドキュメント差異**:
  * `README.md` に記載されていた `⌥⌘6: Batch`（Toggle Batch Panel）が `ViewStereoApp.swift` のメニューバーに未定義。

### 2. 実施した改修と結果
* 警告バナー、ツールチップ、ウェルカム画面の全UIテキストを標準英語キー＋`String(localized: ...)` に統一。
* `ja.lproj/Localizable.strings` および `en.lproj/Localizable.strings` に計26キーを追加。**日英共に全493キーが完全に対称一致（未定義・差分 0件）**。
* `ViewStereoApp.swift` の `CommandMenu("Panels")` に `Button("Toggle Batch Processing Panel")`（`⌥⌘6`）を追加し、インスペクターのバッチ展開状態と同期。
* ショートカットの重複・競合: **0件（完全クリーン）**。

---

## 🔄 フェーズ2: 状態遷移・キャッシュ整合性・メモリ解放

### 1. 検出された潜在バグ
1. **左右スワップ（`isSwapped`）の引き継ぎバグ**:
   * ある画像で `X` キーを押してスワップした後、別の画像を開いても `isSwapped = true` が残り、正視の画像が逆視で表示されてしまう問題。
2. **片目Depthサルベージモードの残留**:
   * 前の画像で「片目Depth 3D」や「2D→3D変換」を実行した後、次のステレオカードを開いた際、`stereoReconstructionMode` が `.trueStereo` に戻らない問題。
3. **高解像度合成バッファのメモリリーク**:
   * `cachedBaseSideRGB`, `cachedSynthFullLeftRGB`/`RightRGB`, `cachedDisparityMap` および解像度情報が画像切り替え時や `resetToInitialState()`, `resetAlignment()` で解放されず、メモリを占有し続ける問題。
4. **動画切り替え時の静止画バッファ解放漏れ**:
   * 静止画を表示した後に動画（`.mov`/`.mp4`）を開いた際、前の静止画RGBバッファが解放されない問題。

### 2. 実施した改修
[ViewStereoModels.swift](file:///Users/okano/マイドライブ/DEV/ViewStereo/Sources/ViewStereo/Models/ViewStereoModels.swift) に以下のクリーンアップ機構を追加・配線：
```swift
/// 深度合成および高解像度ワープ用の中間キャッシュを完全解放
private func clearDepthSynthesisCache() {
    cachedBaseSideRGB = nil
    cachedBaseW = 0
    cachedBaseH = 0
    cachedDisparityMap = nil
    cachedDepthW = 0
    cachedDepthH = 0
    cachedSynthFullLeftRGB = nil
    cachedSynthFullRightRGB = nil
}

/// 静止画像（RAW・整準・プレビュー）の全バッファを完全クリア
private func clearStaticImageBuffers() {
    rawLeftRGB = nil
    rawRightRGB = nil
    alignedLeftRGB = nil
    alignedRightRGB = nil
    previewRawLeftRGB = nil
    previewRawRightRGB = nil
    previewAlignedLeftRGB = nil
    previewAlignedRightRGB = nil
    rectifiedPreviewLeftRGB = nil
    rectifiedPreviewRightRGB = nil
    originalTrueStereoAlignedL = nil
    originalTrueStereoAlignedR = nil
    clearDepthSynthesisCache()
}
```
* **適用箇所**: `resetToInitialState()`, `resetAlignment()`, `loadSingleSBSImage()`, `loadSeparateImages()`, `loadVideo()`。

---

## 🧪 フェーズ3: 実データ・エッジケース確認

テスト用フォルダ（`test/`, `mov_test/`）の実データを用い、Core MLモデルおよび幾何整準パイプラインの実機検証を実施。

### 検証結果サマリー
* **実ステレオカード（29枚）**:
  * 29枚すべてクラッシュ・不正メモリアクセスなく処理完了。
  * **17枚**: サブピクセル精度（RMSE < 0.5px）で垂直視差が完全ゼロ化され、パーフェクト整準（`Perfect`）。
  * **12枚**: `⚠️ Mismatched (Invalid Stereo)`（手前被写体欠落・貼り間違い・別テイク）および `Excessive Stereo Baseline`（過大基線長）として正確に異常診断が発火。UI上で片目サルベージが適切に案内されることを実証。
* **動画 2D-to-3D メタデータ検証**:
  * `01.mp4`（1620×2160, 30fps, 6.00s 180frames）を `AVAssetReader` 経由で正常に認識。縦動画や特定アスペクト比でもメタデータ抽出が破綻しないことを確認。
* **DIBR 深度ワーピング演算検証**:
  * ゼロ視差平面（`focusRatio`）の配置および左右RGBバッファのバイトサイズがピクセル単位で正確に整合。

---

## ⚡️ フェーズ4: メモリリーク・パフォーマンス・負荷テスト

合計 **70枚**（`test` 29枚 + `Stereoscope` 41枚）の実カードをノンストップで連続処理し、プロセスの物理メモリ（RSS）をリアルタイム監視。

### 1. 負荷テストで発見・解決した致命的クラッシュ
* **エラー内容**: `Fatal error: Range requires lowerBound <= upperBound` (Signal 5)
* **発生状況**: `Stereoscope` フォルダ内の特殊なスキャン余白を持つカードを処理する際、[StereoCardSegmenter.swift](file:///Users/okano/マイドライブ/DEV/ViewStereo/Sources/ViewStereo/Models/StereoCardSegmenter.swift#L3371) の地色サンプリング範囲計算で `lowerBound > upperBound` となりプロセスがクラッシュ。
* **修正**: レンジ生成前の `if lo < hi` ガードを徹底（計6箇所の潜在レンジをすべて安全化）。

### 2. メモリプロファイリング実測データ
```
起動直後メモリ (RSS): 103.5 MB

--- [負荷テスト 1] 'test' フォルダ（29枚連続処理） ---
  [ 5/29 cards] Memory: 915.1 MB
  [10/29 cards] Memory: 859.5 MB
  [15/29 cards] Memory: 998.0 MB
  [20/29 cards] Memory: 861.9 MB
  [25/29 cards] Memory: 910.5 MB
  29枚完了時メモリ: 1043.4 MB

--- [負荷テスト 2] 'Stereoscope' フォルダ（41枚連続処理・全70枚走破） ---
  [10/41 cards] Memory: 1001.4 MB
  [20/41 cards] Memory:  713.9 MB (自動回収)
  [30/41 cards] Memory:  709.8 MB
  [40/41 cards] Memory:  837.8 MB
  全41枚完了時メモリ: 839.4 MB (クラッシュゼロ・完走)
```
* **結論**: Core MLモデルのワーキングセット（約700〜900MB）内で適切にメモリが自動回収されており、**70枚の処理を経てもメモリが右肩上がりに増大し続けるリークは一切存在しない**ことを実証。
* **メインスレッド最適化**: バッチ処理中、中間アイテムごとの重いプレビュー再描画を抑止し、最終アイテムのみに限定することで、UIフリーズと一時オブジェクトの滞留を防止。

---

## 📦 フェーズ5: リリースビルド ＆ 配布パッケージ（DMG）検証

統合リリーススクリプト（`build_dmg.sh`）を用い、Xcode Release構成でのクリーンビルドおよびパッケージングを実行。

### パッケージング結果
* **生成ファイル**: `ViewStereo/website/ViewStereo.dmg` (**327 MB**)
* **コード署名**: `Developer ID Application: IZUMI OKANO (83V7E97Y25)` 署名完了（`valid on disk` / `satisfies Designated Requirement`）
* **バンドル同梱リソース（全数確認済み）**:
  * `NAFNetDeblur.mlmodelc` (AI光学デブラー)
  * `SAM2_1TinyImageEncoderFLOAT16.mlmodelc` (SAM 2.1 Tiny エンコーダ)
  * `SAM2_1TinyMaskDecoderFLOAT16.mlmodelc` (SAM 2.1 Tiny デコーダ)
  * `SAM2_1TinyPromptEncoderFLOAT16.mlmodelc` (SAM 2.1 Tiny プロンプト)
  * `StereoCardSeg.mlmodelc` (カード自動セグメンテーション)
  * `StereoColorizer.mlmodelc` (AIカラー化 / 明治手彩色)
  * `AppIcon.icns`, `Assets.car`, `WelcomeIcon.png`
  * `help_ja.html`, `help_en.html`
  * `ja.lproj/Localizable.strings`, `en.lproj/Localizable.strings` (493キー完全同期)

---

## 🏁 結論

本検証作業により、ViewStereo は以下の品質基準を達成しました：

1. **言語品質**: 英語・日本語環境の双方向で、未翻訳やハードコードのない完全なローカライズ表示を実現。
2. **状態遷移の堅牢性**: ファイル種別（ステレオカード、L/Rペア、2D写真、動画）の切り替えや新規ロード時に、前のデータが残留しないクリーンなライフサイクルを確立。
3. **耐久性**: 異常カードや極端な画像でもプロセスが停止しないクラッシュ耐性と、連続処理時の自己メモリ回収（リークなし）を証明。
4. **配布適合性**: Developer ID署名付きの正規DMGパッケージとしていつでもリリース可能な状態を整備。
