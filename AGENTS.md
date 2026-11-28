# ViewStereo Agent Guidelines

**ViewStereo（ビューステレオ）** は、19世紀の歴史的ステレオカード（Stereograph / Stereoview / Stereo Card）および現代のステレオ写真を、最先端のCore MLと数理幾何最適化によって自動検出・位置調整・ステレオウィンドウ調整し、高品位なデジタル写真（空間写真 / SBS / アナグリフ / Wiggle等）に変換・復元するプロフェッショナル macOS アプリケーションです。

## 1. 名称と背景
- **名称**: ViewStereo（ビューステレオ）
- **由来**: 19世紀当時の一般的な呼称である「Stereoview」に由来。鑑賞（View）と歴史的ステレオカードの双方を想起させ、コレクターや研究者、立体視愛好家に馴染み深い落ち着いた響きを持ちます。
- **シリーズ位置づけ**: Stereo Creative Studio Trilogy（SplatStereo / DepthStereo / PanorStereo）のデザインDNAおよび `StereoStudioCore` を継承するファミリーアプリ。

## 2. コア機能
1. **ステレオカード自動検出・分割（Card Segmentation）**:
   - スキャン画像（台紙付きステレオカード）から、左右の写真領域およびアーチ型（Arch-top）枠を Core ML（StereoCardSeg + MobileSAM / SAM 2.1 Tiny）で高精度に自動検出・トリミング。
2. **7自由度対称ホモグラフィ整準（Symmetric Homography）**:
   - `../stalign_src/Packages/StereoCore` による垂直視差の完全ゼロ化、回転・スケール・台形歪み補正（`dposv_` / LAPACK）。
3. **インテリジェント・ステレオウィンドウ調整**:
   - 最前景（最近接被写体）を基準としたステレオウィンドウ面の設定、ウィンドウバイオレーション（枠抜け・網膜闘争）の防止。
   - MAAIR（Maximum Area Axis-aligned Inscribed Rectangle）による無駄のない最適クロップ。
4. **ヴィンテージ復元 ＆ カラーマッチング**:
   - 左右露光差・経年褪色の自動整合、セピア階調の最適化、ノイズ・ダスト低減。
5. **マルチフォーマット出力**:
   - Spatial Photo（Apple Vision Pro / MV-HEVC）、VR向けSide-by-Side（SBS）、アナグリフ、Web向けWiggle 3D（GIF/MP4）、MPO。
   - オプションとして、現代の2眼カメラやデジタルステレオ写真の調整・校正にも完全対応。

## 3. 基本方針 & UI/UX ガイドライン
- **Dark-First Studio UI**: `../StereoStudioCore` および `../macOS_App_Development_Style_Guide.md` に完全準拠（強制 Dark Aqua、Anti-Jitter 固定幅インスペクター、3点セット入力、AboutView / HelpView）。
- **テーマカラー**: 19世紀のセピア・真鍮を想起させる「アンバーゴールド」をキーカラーとし、Trilogyのセマンティックカラー（パープル、ブルー、アンバー、ピンク、グリーン）を踏襲。
- **Metal 1パス Lanczos-3 ワープ**: 高精細なアーカイブ解像度（4K〜8Kスキャン）でも破綻なく高速・シャープに再サンプリング。

## 4. ビルド＆成果物保存規則（Build & Application Packaging）
- **アプリ保存の義務化**: `swift build` や `xcodebuild` によるビルド後、必ずビルド済み実行ファイル（Releaseまたは最新バイナリ）およびリソースバンドルをアプリケーションバンドル（`.app`）へ同期し、以下のプロジェクトフォルダ内に保存・更新すること。
  - `ViewStereo/ViewStereo.app`（プロジェクト直下）
  - `ViewStereo/build/ViewStereo.app`
- **コード署名の整合性**: バイナリ配置後、ローカルで即座にダブルクリック起動できるよう、必ず `codesign --force --deep --sign -` によるアドホック署名を適用すること。
- **アーチ幾何学仕様の遵守**:
  - ステレオカード写真の上部アーチ（Arch-top）は、中央を半円に切り落とさず、上辺中央の水平フラット天井を保護し、左右2隅のみに角丸（$r_x \approx 0.26, r_y \approx 0.14$）を適用すること。
  - 下部2隅は100%完全な水平直角（Square Corner、90度）を堅持すること。
