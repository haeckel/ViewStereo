# ViewStereo 技術検討書および機能仕様書：深度推定 AI モデル管理・オンデマンド導入・マルチエンジン対応（AI Depth Model Manager Specification）

**対象バージョン**: ViewStereo v0.2.2  
**作成日**: 2026年11月22日  
**関連プロダクト**: `ViewStereo`, `StereoStudioCore`, `DepthStereo`, `PanorStereo`, `SplatStereo`

---

## 1. 背景と目的

ViewStereo v0.2.0 において「貼り間違い・片側損傷・過大ステレオベース」に対するユーザー主導の**片側クロップ＆2D-3D コンバージョン救済機能**（`ViewStereoDepthSynthesizer`）を導入した。しかし、現行の実装には以下の運用・品質上の課題が残っている。

1. **深度モデルの選択・切り替えができない**
   - 固定の候補ファイル一覧から最初に見つかった 1 モデルのみを暗黙的に使用するため、被写体やメモリ環境に応じた使い分け（例：超高速な DAv2 Small vs 極細輪郭の Depth Pro / Depth Pro 2 Large vs 空マスク付き MoGe-2 Normal）ができない。
2. **アプリ内からモデルをオンデマンド導入できない**
   - 未導入ユーザーが Core ML 深度モデル（Depth Anything V2 / V3 / MoGe-2 / Apple Depth Pro / Depth Pro 2）を入手する UI が存在せず、Apple Vision フォールバックに留まってしまう。
3. **モデルファミリー別の推論・正規化処理が不足**
   - Depth Pro / Depth Pro 2（`inverse_depth` / 実寸深度）、MoGe-2（メトリック深度 + 法線 + 空マスク）、Depth Anything 3 Mono（直接深度 + 空マスク）では入出力形式・`ComputeUnits` 制約・視差の向きが異なる。
4. **ピークメモリ管理**
   - `Depth Pro`（ピーク 2.2 GB）や `Depth Pro 2 Large`（ピーク 4.0 GB）などの大型モデルを保持したまま `NAFNetDeblur` や `StereoColorizer`、高解像度カード描画を実行するとメモリ圧迫の原因になる。

本仕様では、DepthStereo の「AI モデル」設定タブと同等の管理・オンデマンド導入・優先エンジン切替・メモリ管理機能を ViewStereo に実装する。

---

## 2. アーキテクチャ設計（案A：`StereoStudioCore` 共通カタログ＆ダウンローダー）

Stereo Studio シリーズ間でモデル定義・共有探索・Hugging Face ダウンローダーの重複実装を排除するため、共通パッケージ `StereoStudioCore` にコア機能を配置する。

### 2.1 モジュール構成

| コンポーネント | 所属モジュール | 役割 |
| :--- | :--- | :--- |
| **`StudioModelLocator`** | `StereoStudioCore` | `defaultSeriesAppFolders` に `"ViewStereo"` を追加し、`PanorStereo` / `DepthStereo` / `SplatStereo` / `ViewStereo` / `StereoStudio` 間で `Application Support/<App>/Models/` を相互共有（ゼロ重複） |
| **`StudioDepthEngine`** | `StereoStudioCore` | 全 9 種の深度推定 Core ML エンジンのカタログ定義（ラベル・容量/メモリ概要・Hugging Face リポジトリ・`ComputeUnits` 要件・ローカル候補名・横断検索ヘルパー） |
| **`StudioDepthModelDownloader`** | `StereoStudioCore` | Hugging Face API を用いた `.mlpackage` バッチ取得および `.mlpackage.zip` 解凍（`ditto`）対応ダウンローダー（進捗・ステータス・エラー・キャンセル対応） |
| **`ViewStereoDepthSynthesizer`** | `ViewStereo` | `StudioDepthEngine` に基づくモデル解決、9 エンジン対応マルチ推論、ViewStereo 統一視差規約（`0.0 = 奥 〜 1.0 = 手前`）正規化、キャッシュ解放 |
| **`ViewStereoSettings` / `AppSettingsView`** | `ViewStereo` | 優先エンジン選択・自動メモリ解放設定の永続化、設定ウィンドウの「全般 / AI モデル」タブ UI |
| **`ContentView`（救済バナー連動）** | `ViewStereo` | 現在選択中の優先エンジン名の表示と、設定ウィンドウを開く `SettingsLink` 導線 |

### 2.2 シリーズ間ゼロ重複共有の仕組み

- ユーザーがすでに **DepthStereo** 等で `Depth Pro 2 Large` や `Depth Pro` をダウンロード済みの場合、ViewStereo は `StudioModelLocator` によって `~/Library/Application Support/DepthStereo/Models/` 等からモデルを自動検出し、**追加ダウンロード・追加ディスク容量ゼロで即座に「利用可能（DepthStereo から共有）」** として利用できる。
- 逆に ViewStereo 上からオンデマンドダウンロードしたモデルは `~/Library/Application Support/ViewStereo/Models/` に保存され、他シリーズアプリからもそのまま共有・利用可能となる。

---

## 3. 対応深度推定 AI エンジン（全 9 モデル）

| `rawValue` | 識別子 (`StudioDepthEngine`) | 表示名 / 特徴 | 容量 / ピークメモリ | ライセンス | `ComputeUnits` | 19世紀ステレオビューでの適性 |
| :---: | :--- | :--- | :--- | :--- | :--- | :--- |
| `0` | `.depthAnythingV2Small` | Depth Anything V2 Small (518px・超高速) | 約50MB / 180MB | Apache 2.0 | `.all` | プレビュー試行・低メモリ環境の高速変換向け |
| `1` | `.depthPro` | Apple Depth Pro (1536px・極細毛髪境界) | 約1.9GB / 2.2GB | Apple AMLR | `.all` | 人物ポートレート・衣装レース・樹木の細密輪郭向け |
| `2` | `.depthAnythingV3Mono` | Depth Anything 3 Mono-Large (504px・次世代高安定) | 約670MB / 1.1GB | Apache 2.0 | `.all` | 滑らかな奥行き階調＋空 (`sky`) 分離に優れる汎用モデル |
| `3` | `.depthAnythingV2Large` | Depth Anything V2 Large (518px・高精細相対) | 約670MB / 1.1GB | CC-BY-NC 4.0 | `.all` | 安定した相対視差と高いディテール再現 |
| `4` | `.moge2ViTB` | MoGe-2 ViT-B Normal (504px・メトリック幾何+法線) | 約190MB / 500MB | MIT (商用可) | `.all` | 空マスク＋法線レリーフにより退色写真でも空の飛び出しを抑制 |
| `5` | `.moge2ViTL` | MoGe-2 ViT-L Normal (1104px・最高精度3D幾何+法線) | 約690MB / 1.3GB | MIT (商用可) | `.cpuAndGPU` | 建築・街並み・遠景風景で高精度な空間幾何＋空マスク固定 |
| `7` | `.depthPro2Small` | Apple Depth Pro 2 Small (854x480・超高速) | 約51MB / 1.5GB | Apple AMLR | `.cpuAndGPU` | 軽量・高速で安定境界を持つ次世代実寸視差 |
| `8` | `.depthPro2Base` | Apple Depth Pro 2 Base (854x480・バランス) | 約188MB / 2.5GB | Apple AMLR | `.cpuAndGPU` | 速度と境界精度の高バランス |
| `9` | `.depthPro2Large` | Apple Depth Pro 2 Large (854x480・超高精細) | 約891MB / 4.0GB | Apple AMLR | `.cpuAndGPU` | 人物・群衆・立体構造物の最高峰境界分離 |

※ Core ML モデルが 1 つも未導入の場合は、自動的に **Apple Vision Neural Depth**（人物セグメンテーション + アテンション顕著性 + 遠近プライア）へフォールバックする。

---

## 4. モデル出力と視差正規化仕様（ViewStereo 統一規約）

> [!IMPORTANT]
> **視差方向の厳密な統一**:
> `ViewStereoDepthSynthesizer` の DIBR ワーパーは **`0.0 = 奥（無限遠 / 最遠背景）〜 1.0 = 手前（最近接前景）`** の正規化視差（Disparity）を入力として期待する。
> （※ DepthStereo の保存規約 `0.0 = 手前 / 1.0 = 奥` とは逆向きであるため、変換時に反転ミスが起きないよう各ファミリー別に明示的に正規化する）

### 4.1 モデルファミリー別推論＆正規化ルール

1. **Apple Depth Pro 2 (`depthPro2Small / Base / Large`)**
   - 入力: `"frame"` `MLMultiArray [1, 3, H, W]`（通常 `H=480, W=854`、`[0, 1]` RGB）。macOS 15+ では推論ごとに `model.makeState()` でクリーンな `MLState` を生成して呼び出す（静止画の1枚ずつを独立推論するため前画像の状態引きずりを防止）。
   - 出力: `"inverse_depth"`（値が高いほど手前 = 視差に比例）。
   - 正規化: 正の値に対して 2%〜98% パーセンタイルのロバストクリッピングを行い、`0.0 = 奥 〜 1.0 = 手前` へマップ。
2. **Apple Depth Pro (`depthPro`)**
   - 入力: `"image"` (`1536×1536` `kCVPixelFormatType_32BGRA` `CVPixelBuffer`) および `"originalWidth"` (`[1, 1, 1, 1]`)。
   - 出力: `"depthMeters"`（メートル距離: 値が小さいほど手前、大きいほど奥）。
   - 正規化: `disparity = 1.0 / max(meters, 0.01)` へ逆数変換したうえで 2%〜98% ロバストクリッピング（`0.0 = 奥 〜 1.0 = 手前`）。
3. **MoGe-2 (`moge2ViTB / ViTL`)**
   - 入力: モデルの `inputDescriptionsByName` に応じて Image (`CVPixelBuffer`) または RGB `MLMultiArray` を自動構築。
   - 出力: `"depth"` または `"points"`（Z チャネル `ch=2`）、および有効マスク `"mask"`（`< 0.5` が空/無限遠）、法線 `"normal"`（Nz `ch=2`）。
   - 正規化: 有効領域のみ `1.0 / depth` で視差化し、2%〜98% 正規化（`0.0 = 奥 〜 1.0 = 手前`）。オプションで法線 `|Nz|` による微細な表面丸み補正を加え、**`mask < 0.5` の空領域は強制的に `0.0`（無限遠）にピン留め**する。
4. **Depth Anything 3 Mono (`depthAnythingV3Mono`)**
   - 入力: 汎用入力ビルダー（Image または `MLMultiArray`、デフォルトサイズ `504`）。
   - 出力: 直接深度 `depth`（小さいほど手前、大きいほど奥）＋ 任意で `"sky"` マスク。
   - 正規化: 対数・反転正規化で `0.0 = 奥 〜 1.0 = 手前` へ変換し、`sky > 0.5` 領域は強制的に `0.0`（無限遠）へ固定。
5. **Depth Anything V2 (`depthAnythingV2Small / Large`)**
   - 入力: Vision `VNCoreMLRequest` または汎用入力ビルダー。
   - 出力: 相対視差（値が大きいほど手前）。
   - 正規化: 2%〜98% ロバストクリッピングにより `0.0 = 奥 〜 1.0 = 手前` へマップ。

### 4.2 推論エンジン解決フォールバック順

ユーザーが優先エンジン $E_{\text{pref}}$ を選択して「3D 変換」を実行した際：
1. $E_{\text{pref}}$ のモデルがローカル／シリーズ共有パス（またはアプリバンドル）に存在すればそれを使用。
2. 未導入の場合は、導入済みの他エンジンからフォールバック検索して使用（選択した優先エンジンと実際に使われたエンジンが異なることもステータスに明記）。
3. いずれの Core ML モデルも未導入の場合は Apple Vision ネイティブ深度（`Apple Vision Neural Depth`）を使用。

---

## 5. UI / UX 仕様

### 5.1 設定ウィンドウ (`ViewStereo` > 設定… / `⌘,`)

ウィンドウサイズを `580 × 680 pt` とし、以下の 2 タブ構成（`TabView`）とする：

1. **「全般 (`gearshape`)」タブ**
   - 従来の設定項目（自動スワップ `Auto-Swap Reversed Stereo`、大きい文字モード `Large Text Mode (1.2x UI Scale)`）をそのまま維持。
2. **「AI モデル (`cpu`)」タブ**
   - **ヘッダー領域**:
     - アイコン ＋ タイトル「深度推定 AI エンジン」
     - ステータスバッジ：Core ML モデルが 1 つ以上あれば緑文字で「モデル準備完了」、未導入時はオレンジ文字で「Apple Vision フォールバック待機（Core ML 未導入）」
     - 右側に **`優先エンジン` ドロップダウン Picker**（`StudioDepthEngine.allCases`）
   - **モデル一覧カード（スクロールリスト）**:
     - 全 9 モデルを縦並びのカードで表示：
       - 左：ファミリー別アイコン（Apple ロゴ / MoGe ジャイロ / Depth Anything 立方体）
       - 中央：モデル名 (`displayName`) ＋ 現在選択中なら青い `選択中` カプセル、下段に容量・ピークメモリ・ライセンス・特徴 (`badgeSummary`)、共有利用中の場合は所有アプリ名（例：`DepthStereo から共有`）を補足表示
       - 右：
         - **利用可能時**: 緑の `利用可能` カプセル（未選択カードをクリックすると優先エンジンに切替可能）
         - **ダウンロード中**: プログレスバー ＋ `キャンセル` ボタン
         - **未導入時**: 青い `ダウンロード` ボタン（他のダウンロード実行中は無効化）
     - ダウンロード中はリスト下部に詳細ステータステキスト・線形プログレスバー、失敗時は赤文字でエラー内容を表示。
   - **メモリ管理セクション**:
     - `推論完了後に深度 AI モデルをメモリから解放する` トグル（デフォルト `ON`）
     - `[今すぐメモリを解放]` ボタン（キャッシュ中の Core ML モデル・`VNCoreMLModel` を即座に破棄し、完了メッセージを一時表示）
   - **内蔵修復・解析 AI モデルセクション（情報表示）**:
     - ViewStereo アプリに最初から同梱されている以下の 4 モデルについて「同梱済み・利用可能」のステータス一覧を表示：
       - `StereoCardSeg`（ステレオカード台紙・写真自動切り出し）
       - `SAM 2.1 Tiny`（対象被写体高精度セグメンテーション）
       - `NAFNet Deblur`（ピントボケ・手ブレ光学復元）
       - `StereoColorizer`（歴史的モノクロ写真の AI カラー化）

### 5.2 メイン画面（救済バナー）との連動

- [`ContentView.swift`](file:///Users/okano/マイドライブ/DEV/ViewStereo/Sources/ViewStereo/Views/ContentView.swift) の救済バナー内（「変換に使用する元画像を選択」および「変換完了中」の両状態）に：
  - 現在選択中の優先エンジン名（例：`💎 Depth Pro 2 L`）のステータス表示
  - macOS 標準の `SettingsLink` ボタン（`モデル設定…`）を配置し、作業中にその場で設定ウィンドウのモデル選択／導入画面へアクセスできる動線を提供する。

---

## 6. 永続化・ローカライズ・検証計画

- **設定永続化 (`UserDefaults`)**:
  - `VS.depthModelEngine`: `Int`（`StudioDepthEngine.rawValue`）
  - `VS.releaseAIModelsAfterGeneration`: `Bool`（デフォルト `true`）
- **ローカライズ**:
  - `ja.lproj/Localizable.strings` および `en.lproj/Localizable.strings` の両方に設定UI・ボタン・ステータス・エラーメッセージを追加。
- **ビルド・動作検証**:
  - `ViewStereo.xcodeproj` でのフルビルド（`StereoStudioCore` への新規 Swift ファイル追加を含むリンク検証）でエラー・主要警告がないこと。
  - 既にシステム内に DepthStereo 用の Core ML モデルが存在する場合、`StudioModelLocator` 経由で自動認識される構造であることをコード上で検証。
