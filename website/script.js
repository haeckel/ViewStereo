document.addEventListener('DOMContentLoaded', () => {
    // Translation Data
    const translations = {
        'ja': {
            'meta-desc': 'ViewStereo - 19世紀ステレオカードのAI自動検出・7自由度ホモグラフィ整準・デジタルリマウント & 空間写真復元スタジオ',
            'title': 'ViewStereo | 歴史的ステレオカード復元 & インテリジェント・ステレオウィンドウスタジオ',
            'mac-exclusive': ' ViewStereo は macOS 専用アプリケーションです。',
            'nav-features': '復元図録',
            'nav-stereoview': '歴史と魅力',
            'nav-specimens': '標本展示',
            'nav-tech': '工学仕様',
            'nav-download': '収蔵・DL',
            'btn-get-beta': '無料ダウンロード',
            'hero-title': '<span>時を超えた立体視、</span><br><span>精密に蘇る。</span>',
            'hero-version': 'v0.2.2 (2026.11.24)',
            'dev-status-badge': '開発初期・現在開発中',
            'hero-subtitle': 'ViewStereo は、19世紀の歴史的ステレオカード（Stereoview / Stereograph）や現代のステレオ写真を、Core ML自動検出・7自由度対称ホモグラフィ整準・ステレオウィンドウ最適化によって高品位な空間写真やデジタル・リマウントカードへ復元する macOS 専用アプリケーションです。',
            'hero-plate-caption': 'Fig. I. — The Holmes Hand Stereoscope &amp; Binocular Optical Path',
            'hero-arch-tag': 'TWIN ARCH-TOP STEREOGRAPH · c. 1890s',
            'hero-arch-desc': '7自由度ホモグラフィ整準 ＆ AI セグメンテーションにより、19世紀の肉筆台紙カードを現代の空間写真へ無劣化復元します。',
            'about-desc': 'ViewStereo は、StereoCardSeg (U-Net) と MobileSAM / SAM 2.1 Tiny による精密なカード領域抽出と、Accelerate LAPACK (dposv_ + IRLS) を用いた7自由度対称ホモグラフィ整準を統合。19世紀ステレオカードの傾き・歪み・垂直視差・経年退色を自動で補正し、Apple Vision Pro 空間写真（MV-HEVC）や時代別デジタル・リマウントカードとして現代に蘇らせます。',
            'story-plate-caption': 'Plate II. — Victorian Parlor Stereoscope &amp; Authentic Archival Stereocards (Underwood &amp; Underwood / T. Enami)',
            'spec-header-title': '実物ステレオカード標本展示',
            'spec-header-subtitle': '学習用アーカイブおよび復元検証に使用される、19世紀〜20世紀初頭のパブリックドメイン・ステレオカード実物コレクション。',
            'spec-1-title': '明治・横浜手彩色「芸者図」',
            'spec-1-desc': 'T. Enami（江南信國）による輸出用手彩色ステレオカード。セージ／イエロー台紙と優雅なアーチ枠。',
            'spec-2-title': '幕末・明治初期「侍（Japanese Officers）」',
            'spec-2-desc': '鶏卵紙プリントによる初期アイボリー台紙カード。経年退色と手貼り傾きを ViewStereo で精密整準。',
            'spec-3-title': 'Underwood &amp; Underwood 社版',
            'spec-3-desc': '世界最大手パブリッシャーによるアーチ型曲面台紙。両端マージンの活版クレジットも OCR 復元対象。',
            'spec-4-title': '自由の女神像（Liberty Enlightening）',
            'spec-4-desc': 'サーモンピンク台紙の建築・記念碑ビュー。遠景の空領域を保護しつつアーチ境界を高精度に抽出。',
            'spec-5-title': 'Keystone 社「オリオン座星雲」',
            'spec-5-desc': 'ヤーキス天文台撮影の天体ステレオカード。1900年代のダークグレー曲面台紙の代表例。',
            'spec-6-title': '「ステレオ写真専門店」風俗図',
            'spec-6-desc': 'ステレオカードを買い求めるヴィクトリア朝の貴婦人たちを立体撮影したメタ的風俗カード。',
            'tech-diagram-caption': 'Fig. II. — Symmetric 7-DoF Homography Epipolar Alignment &amp; MAAIR Crop Geometry',
            'heritage-badge': 'Historical Heritage · 19th Century Media Revolution',
            'heritage-title': '<span>Stereoview &amp; Stereograph</span><br><span>19世紀の「没入体験」と空間メディアの原点</span>',
            'heritage-subtitle': '100年以上前、ヴィクトリア朝の人々は「ステレオスコープ」という魔法の双眼鏡を覗き込み、世界を立体で体験していました。それは現代のVRゴーグルやApple Vision Proを先取りした、人類最初の空間メディア革命でした。',
            'story-essay-title': '19世紀の「没入体験」！？ステレオ写真が映し出した「世界」と私たちの欲望',
            'story-essay-desc': '雨降るロンドンやパリの夕暮れ、ガス灯が灯る暖かいリビングで家族が覗き込んだ魔法の双眼鏡。中産階級のステータス、両眼視差が生んだ圧倒的なリアリティ、そして安全な居間からエジプトや日本を立体で旅する欲望——。現代のGoogleストリートビューやAIワールドモデルの物理的プロトタイプとなった19世紀ステレオ写真の大隆盛と、視覚メディアの本質を解き明かす開発者エッセイ。',
            'story-btn-text': 'note でエッセイを読む',
            'pillar-1-tag': 'Status &amp; Science',
            'pillar-1-title': '魔法の双眼鏡と「科学的真実」',
            'pillar-1-desc': '産業革命で台頭したブルジョワジーにとって、ステレオスコープは知的な家庭の必須教養でした。「写真こそが真実を写す」と信じられた19世紀、両眼視差を利用した立体写真は絵画より科学的に正しい視覚メディアとされ、まるで「そこに実体がある」と錯覚するほどの熱狂を生みました。',
            'pillar-2-tag': 'Virtual Travel',
            'pillar-2-title': '最初の「ワールドモデル」構築',
            'pillar-2-desc': 'ピラミッドや開国直後の日本など、危険な異国を居間から訪れる「安全な旅行」。Underwood &amp; Underwoodなどの巨大企業が体系的なカードセットと販売網を築き、世界を立体でアーカイブした試みは、現代のGoogleストリートビューやAIワールドモデルの直接の原型でした。',
            'pillar-3-tag': 'Modern Revival',
            'pillar-3-title': '100年の封印を解き、空間写真へ',
            'pillar-3-desc': '手貼りによる傾きや経年退色を抱えたヴィンテージ・ステレオカード。ViewStereo は Core ML セグメンテーションと7自由度対称ホモグラフィ整準により、幾何歪みと垂直視差を完全除去。Apple Vision Pro の Spatial Photo や高精細SBSとして現代に解放します。',
            'btn-try-free': '今すぐ無料ダウンロード',
            'btn-view-features': '復元図録を見る',
            'feat-header-title': '研ぎ澄まされた機能',
            'feat-header-subtitle': 'AI セグメンテーションと数理幾何最適化の結晶が、歴史的立体写真を現代に蘇らせます。',
            'feat-1-title': 'ステレオカード自動検出 ＆ 7自由度ホモグラフィ整準',
            'feat-1-desc': 'StereoCardSeg (U-Net) と MobileSAM / SAM 2.1 Tiny により、台紙から左右の写真領域とアーチ型枠を自動抽出。LAPACK dposv_ + IRLS の7自由度対称ホモグラフィ整準により、手貼りによる傾き・歪み・垂直視差をサブピクセル精度で解消します。',
            'feat-2-title': 'インテリジェント・ステレオウィンドウ ＆ MAAIR',
            'feat-2-desc': '最前景と Apple Vision 顕著性解析から最適なステレオウィンドウ位置を自動算出し、枠抜け（ウィンドウバイオレーション）を防止。さらに MAAIR（最大面積軸平行内接矩形）で黒枠のない最大有効領域を自動トリミングします。',
            'feat-3-title': '時代別デジタル・リマウント ＆ 活版OCRタイポグラフィ',
            'feat-3-desc': '1850年代の初期アイボリーから1900年代 Keystone ダーク曲面台紙まで8種類の時代別プリセットを搭載。Vision OCR が元台紙のタイトルや出版社クレジットを読み取り、活版印刷風タイポグラフィで美しく再構成します。',
            'feat-4-title': 'Spatial Photo 書き出し ＆ フォルダ一括バッチ処理',
            'feat-4-desc': 'Apple Vision Pro 用の MV-HEVC 空間写真（HEIC）、SBS、アナグリフ（Dubois/Color/Gray）、偏光、MPO、個別L/Rなど11形式の出力に対応。大量のアーカイブをフォルダごと自動処理し、調整レポート（.txt）も保存できます。',
            'tech-header-title': 'Powered by State-of-the-Art Tech',
            'tech-header-subtitle': 'Core ML、Vision、Accelerate LAPACK を核とし、Apple Silicon に最適化された精密処理。',
            'about-sharp-content': `<p>ViewStereo は、独自の Core ML モデル「StereoCardSeg」に加え、<a href="https://github.com/ChaoningZhang/MobileSAM" target="_blank" rel="noopener noreferrer" class="tech-link">MobileSAM</a> や Meta AI の <a href="https://github.com/facebookresearch/sam2" target="_blank" rel="noopener noreferrer" class="tech-link">SAM 2.1 Tiny</a> をオンデバイスで実行し、劣化した歴史的ステレオカードの印画境界を正確に抽出します。続く幾何補正では Accelerate LAPACK (<code>dposv_</code>) による7自由度対称ホモグラフィ最適化と MAAIR 内接矩形クロップを行い、視覚的疲労の原因となる垂直視差を完全に排除します。<br><span style="font-size: 0.9rem; color: var(--accent-vermilion); display: block; margin-top: 10px; font-weight: 600;">※すべての AI モデルはアプリに同梱され、100% オンデバイス（オフライン）で高速に動作します。</span></p>`,
            'upd-header-title': '更新履歴',
            'upd-header-subtitle': '精度と再現性の向上のため、進化し続けます。',
            'upd-022-1': '【ViewStereo 0.2.2 アップデート】深いドーム型アーチ（Deep Dome Arch）の数理フィッティング強化：19世紀特有の急峻なドーム型アーチカード（降下率 ry 最大 0.45）に対応。超楕円指数（p=1.6〜2.6）の探索と Sobel 勾配エッジ吸着スコアリングを導入し、上部被写体の欠けを防止。外周連結台紙バリアによる両肩三角領域の一致率検証（shoulderBarrierRatio）を新設し、直角写真カードでのアーチ誤判定を防止',
            'upd-022-2': 'Keep Arch（アーチ保持）のサブピクセル内側オフセット＆アンチエイリアス境界処理：Keep Arch マスク適用時および台紙再構成レンダラーにおいて、黒枠フリンジや元台紙の境界残りをゼロにする内側オフセット・インセット処理を実装。符号付き距離関数に基づくスムーズなアルファブレンディングを導入し、滑らかで自然なアーチ縁を実現',
            'upd-021-1': '【ViewStereo 0.2.1 アップデート】3段階カスケード台紙解析エンジン（StereoCardMountAnalyzer）導入によるクロップ刷新：Stage 0（4隅CIE Labフラッドフィルによるスキャン余白分離＆RANSAC水平化、白台紙誤除去を防ぐ3重安全策付き）、Stage 1（step=1適応的リム走査による極細台紙対応CIE Lab色バリア＆外周連結保護）、Stage 2（SAT＋Sobel座標降下法による双子窓パラメトリックフィッティング）を搭載',
            'upd-021-2': '暗背景写真・キャプション・アーチ頂点の過剰クロップ防止：SAM 2.1 Tinyのマスク許容度・候補選定を改善し、月写真など暗黒背景の過剰クロップを解消。下端キャプション除去時の細い罫線誤検出の修正およびアーチ頂点（apexY）同期・誤判定リセットを導入',
            'upd-021-3': 'Core ML入力処理の堅牢化：StereoCardSegおよびSAM2_1TinyImageEncoderへの入力をCVPixelBufferCreate直接描画に変更し、環境依存のCVPixelBuffer生成エラーを解消',
            'upd-020-1': '【ViewStereo 0.2.0 アップデート】日英ローカライズの100%対称化と多言語完全対応：警告バナー（特徴点不足、ステレオ不成立、偽視検出等）、全ツールチップ、初期ガイドカードのハードコードを排除し、日英全493キーが完全一致',
            'upd-020-2': '状態遷移・キャッシュ整合性・メモリ管理の徹底強化：画像切替時の左右スワップや片目Depthサルベージモードの引き継ぎバグを修正。深度合成バッファおよび静止画・動画メモリの即時解放機構（clearDepthSynthesisCache / clearStaticImageBuffers）を導入し、長時間の連続処理や高解像度バッチ時のメモリリークを根絶',
            'upd-020-3': '台紙抽出エンジンの堅牢化・クラッシュ防止：コーナー境界判定および台紙エッジサンプリング時のレンジ境界ガードを強化し、特殊形状や極端解像度のカードにおける強制終了（Fatal error）を完全に防止',
            'upd-020-4': 'ショートカット統一：メニューバー「Panels」に「バッチ・書き出し詳細設定（⌥⌘6）」を追加し、インスペクターの開閉状態と完全同期',
            'upd-019-1': '【ViewStereo 0.1.9 アップデート】動画 2D→3D 変換＆空間ビデオ（MV-HEVC）生成機能を新搭載：2D 動画（.mp4 / .mov / .m4v）から Apple Vision Pro 互換の空間ビデオ、Full SBS / Half SBS、アナグリフ 3D 動画への高品質変換に対応',
            'upd-019-2': 'Apple Depth Pro 2 連携 Stateful 深度推論：Core ML MLState（macOS 15+）による前フレーム隠れ状態の保持、暗転・クールダウン付きシーンカット自動検出、時間的平滑化（EMA）と奥行きレンジ固定（Lock Depth Range）により、動画深度のフリッカー（チラつき）を構造的に抑止',
            'upd-019-3': 'Metal GPU 高速化 DIBR ＆ AVFoundation 最適化：Metal コンピュートシェーダーによる GPU ゼロコピー 3D 合成、正立化・トーンマッピング・CVPixelBufferPool 再利用、AAC 音声再エンコード、および書き出し前ディスク空き容量チェックを統合',
            'upd-019-4': 'SBS 3D 動画の片眼抽出＆再構築：既存の SBS 3D 動画から左眼・右眼を抽出し、快適域 3D 動画へ再合成・リマスター可能',
            'upd-018-1': '【ViewStereo 0.1.8 アップデート】DIBR 2D-3D 合成のステレオウィンドウ自動最適化（エッジ飛び出し防止）：深度マップと Vision 顕著性解析を統合した「ゼロ視差面（focusRatio）自動算出アルゴリズム」を新搭載。画面端での枠抜けバイオレーションを構造的に抑止し、パーシバル快適域に収まる自然な立体奥行きを実現',
            'upd-018-2': '単眼 2D 画像および片側救済の高品位バッチ・高解像度書き出し強化：フル解像度合成バッファのキャッシュ管理を最適化し、Spatial Photo・SBS・アナグリフ書き出し時やフォルダ一括バッチ処理時にも最適なステレオウィンドウを自動適用',
            'upd-018-3': '視差サンプリングエンジンの共通化と安定化：バイリニア補間とガンマ/コントラスト補正を統合した最適化サンプラーにより、スライダー操作時のリアルタイムプレビュー応答性を向上',
            'upd-017-1': '【ViewStereo 0.1.7 アップデート】3ペイン・スタジオ型ファイルブラウザワークフローの導入：左ペインにツリー型ファイルブラウザ（⌥⌘L）を新設。起動時フォルダ指定、L/Rペア自動統合（_L/_R等）、処理ステータスバッジ（✓/⚠️/✕）、出力先フォルダ自動除外に対応',
            'upd-017-2': 'AI 深度モデルマネージャー ＆ 全9種マルチエンジン対応：Apple Depth Pro、Depth Pro 2（Small/Base/Large）、Depth Anything V2/V3、MoGe-2（ViT-B/L）に対応。環境設定からオンデマンド導入・優先切替が可能になり、シリーズ間モデルゼロ重複共有を実現',
            'upd-017-3': 'ステレオ異常救済（Single-Eye Depth 3D）パイプラインの本格強化：選択した優先 Core ML 深度エンジンによる高品質な2D-3D立体視生成と自動メモリ解放に対応',
            'upd-016-1': '【ViewStereo 0.1.6 アップデート】ステレオ異常自動診断 ＆ 片側救済（Single-Eye Depth 3D Salvage）：貼り間違い・別テイク・片側損傷・過大視差などの異常を自動検出し、ステータス画面から状態の良い片側（左または右）を選択して AI Depth 3D（2D-3D立体視）にワンクリック変換・救済可能に',
            'upd-016-2': 'ステレオウィンドウ（⌥⌘2）への立体ソース切替搭載：常設の「オリジナル L+R / 左眼 Depth 3D / 右眼 Depth 3D」切替、仮想ステレオベース（0.5%〜6.0%）、深度カーブ調整に対応',
            'upd-016-3': '台紙セグメンテーション（StereoCardSegmenter）の更なる高精度化：空や富士山頂などのグラデーション領域が誤って削られるのを防止するセーフティガードおよび上端復元処理を強化',
            'upd-015-1': '【ViewStereo 0.1.5 アップデート】左右逆（偽視 / Pseudoscopic Stereo）の自動検出 ＆ 自動スワップ：交差法や反転スキャン素材の左右逆を読み込み時に自動補正し、ステータス警告と連動',
            'upd-015-2': '手動反転（Xキー）時のステレオウィンドウ最適シフト即時再計算による枠抜けバイオレーション防止',
            'upd-015-3': 'SAM 2.1 Tiny セグメンテーションの上端プロンプトおよび U-Net 高度調停による輪郭欠け防止',
            'upd-014-1': '【ViewStereo 0.1.4 アップデート】右インスペクターパレットの再設計 & 初期表示最適化：「基本設定（自動処理レシピ）」を最上段に配置し、新規画面時は基本設定のみ展開、他は閉じるスマートな初期レイアウトを採用',
            'upd-014-2': 'キーボードショートカット & ツールバーの完全同期：パレット並び順に合わせて ⌥⌘1 (Recipe) 〜 ⌥⌘6 (Batch) およびツールバーのボタン順を一新',
            'upd-014-3': '4隅丸角・アーチ・直角の高精度独立判定 & 台紙ヒーリング保護：上下コーナーの背景色から角丸／直角／アーチを独立判定し、中央谷間の印字保護を強化',
            'upd-013-1': '【ViewStereo 0.1.3 アップデート】手彩色風・AI カラー化（StereoColorizer）を搭載：100% オンデバイスで 1890s 明治手彩色風（透明水彩）・AI ナチュラルカラー化・既存手彩色の左右色ムラ同期に対応',
            'upd-013-2': 'ツールバー全面刷新 ＆ パネル開閉トグル（サイドバー・退色復元・彩色・ウィンドウ・台紙・基本設定・バッチ等）を追加',
            'upd-013-3': 'セグメンテーションを StereoCardSeg + SAM 2.1 Tiny パイプラインへ一本化（MobileSAM 廃止）し、古写真復元トグル・実行ボタンを強化',
            'upd-012-1': '【ViewStereo 0.1.2 アップデート】古写真・退色階調復元（Vintage Photo Restoration）を搭載：1860年代 鶏卵紙セピア・1890年代 ゼラチンシルバー調等のプリントトーン、Auto-Level、CLAHE 局所コントラスト、および「復元前と比較」トグルを新設',
            'upd-012-2': 'Core ML AI 光学デブラー（NAFNet-GoPro）をアプリ内蔵：100% オンデバイスでぼけ・鮮鋭度を復元し、高周波・葉/粒子保護スライダーで視野闘争を防止',
            'upd-012-3': '片側ノイズ・ダスト自動除去の即時非破壊プレビュー更新、およびアップデート確認ダイアログの初期化・日英ローカライズを改善',
            'upd-011-1': '【ViewStereo 0.1.1 アップデート】ステレオカード台紙再構成（Digital Remount）のアスペクト比100%維持：クロップ・ズーム拡大を廃止し、SBS表示と同一の全構図を維持する Aspect Fit + バイリニア変倍および密着カード自動判定を強化',
            'upd-011-2': 'アーチ型フレーム保持時の水平シフト上限（自動 2.0% / 手動・描画 3.5%）を最適化し、UI表示値とレンダリング結果を一致',
            'upd-011-3': '表示モードメニュー・ショートカット順序を整理（⌘1: StereoView / ⌘8: 2D）',
            'upd-010-1': 'Core ML（StereoCardSeg U-Net + MobileSAM / SAM 2.1 Tiny）による19世紀ステレオカード左右領域・アーチ枠の自動セグメンテーションを搭載',
            'upd-010-2': 'StereoCore 7自由度対称ホモグラフィ整準（LAPACK dposv_ + IRLS）および MAAIR 最大共通内接矩形クロップを実装',
            'upd-010-3': '最前景＆Vision顕著性に基づくインテリジェント・ステレオウィンドウ決定と、リアルタイム微調整UI・カラーマッチング・片側ダスト除去を搭載',
            'upd-010-4': '8種類の歴史的台紙プリセット（1850s〜1900s）＆ Vision OCR 活版タイポグラフィによるデジタル・リマウントエンジンを実装',
            'upd-010-5': 'Apple Vision Pro 空間写真（MV-HEVC HEIC）、SBS、アナグリフ、偏光、MPO、フォルダ一括バッチ処理に対応',
            'dl-title': '体験を、今すぐ。',
            'dl-subtitle': 'ViewStereo v0.2.2 がリリースされました。',
            'btn-download': 'ViewStereo をダウンロード',
            'dl-support': 'Supported on macOS 14.0+ (Apple Silicon Recommended)',
            'dev-notice-box': '<strong>【開発初期・開発中のソフトウェアに関するご注意】</strong><p>ViewStereo は現在開発中であり、特に開発初期段階（v0.1系）にあります。ダウンロードしてご利用いただくユーザーには、アプリの仕様向上およびデバッグ作業にお付き合いいただく形となります。動作の不安定さや予期せぬ不具合、今後の仕様変更の可能性がありますので、あらかじめご了承のうえお試しください。</p>',
            'foot-doc': 'オンラインマニュアル',
            'foot-privacy': 'プライバシーポリシー',
            'foot-credits': '謝辞',
            'disclaimer-title': '免責事項 / 開発状況・ライセンスに関するご注意',
            'disclaimer-content': '本アプリケーション（ViewStereo）は、現在開発中（開発初期段階）の実験的な個人開発プロジェクトであり、いかなる商業的活動も行っておらず、将来的な商用化も意図していません。ダウンロードしてご利用いただくユーザーには、アプリの仕様向上およびデバッグ作業にお付き合いいただく形となりますため、動作の不安定さや不具合、今後の仕様変更の可能性をあらかじめご了承ください。本アプリに同梱・使用されているオープンソース AI モデル（MobileSAM / SAM 2.1 Tiny 等）は、各提供元のライセンス（Apache License 2.0 等）に準拠しています。',
            'lang-toggle': 'English'
        },
        'en': {
            'meta-desc': 'ViewStereo - 19th Century Stereoview Restoration, 7-DoF Homography Alignment & Spatial Photo Studio',
            'title': 'ViewStereo | Historical Stereoview Restoration & Intelligent Stereo Window Studio',
            'mac-exclusive': ' ViewStereo is exclusively designed for macOS.',
            'nav-features': 'Archival Plates',
            'nav-stereoview': 'Heritage',
            'nav-specimens': 'Specimens',
            'nav-tech': 'Schematics',
            'nav-download': 'Download',
            'btn-get-beta': 'Free Download',
            'hero-title': '<span>Timeless Stereoscopy,</span><br><span>Precision Restored.</span>',
            'hero-version': 'v0.2.2 (2026.11.24)',
            'dev-status-badge': 'Early Development',
            'hero-subtitle': 'ViewStereo is a native macOS studio app that transforms 19th-century historical stereoview cards and modern stereo photos into pristine Apple Vision Pro Spatial Photos, SBS, and digitally remounted cards using Core ML segmentation and 7-DoF homography alignment.',
            'hero-plate-caption': 'Fig. I. — The Holmes Hand Stereoscope &amp; Binocular Optical Path',
            'hero-arch-tag': 'TWIN ARCH-TOP STEREOGRAPH · c. 1890s',
            'hero-arch-desc': 'Restoring 19th-century hand-mounted stereocards into pristine Spatial Photos via 7-DoF homography alignment and AI segmentation.',
            'about-desc': 'ViewStereo combines StereoCardSeg (U-Net) and MobileSAM / SAM 2.1 Tiny mask refinement with Accelerate LAPACK (dposv_ + IRLS) 7-DoF symmetric homography alignment. It automatically eliminates vertical disparity, keystone distortion, and color aging—preserving heritage stereoviews for modern spatial displays.',
            'story-plate-caption': 'Plate II. — Victorian Parlor Stereoscope &amp; Authentic Archival Stereocards (Underwood &amp; Underwood / T. Enami)',
            'spec-header-title': 'Archival Stereocard Specimens',
            'spec-header-subtitle': 'Authentic 19th- to early 20th-century public-domain stereoviews from our training and restoration reference archive.',
            'spec-1-title': 'T. Enami Hand-Tinted "Geisha Girls"',
            'spec-1-desc': 'Export hand-colored stereoview by T. Enami (Yokohama, Japan), featuring arched-top frames on a vintage mount.',
            'spec-2-title': 'Bakumatsu / Meiji "Japanese Officers"',
            'spec-2-desc': 'Early albumen print on an ivory mount. Hand-mounting tilt and fading are rectified down to sub-pixel precision.',
            'spec-3-title': 'Underwood &amp; Underwood Publishers',
            'spec-3-desc': 'Classic arched curved mount from the world’s largest stereoview publisher, complete with letterpress side margins.',
            'spec-4-title': 'Statue of Liberty (New York)',
            'spec-4-desc': 'Monumental view on a salmon-pink mount. Sky gradients are safely preserved during arch boundary extraction.',
            'spec-5-title': 'Keystone "Constellation of Orion"',
            'spec-5-desc': 'Yerkes Observatory astronomical stereoview mounted on a classic 1900s Keystone Dark curved card.',
            'spec-6-title': '"Stereoscopic Views Emporium"',
            'spec-6-desc': 'Hand-tinted Victorian genre card depicting patrons browsing stereographs inside a 19th-century optical shop.',
            'tech-diagram-caption': 'Fig. II. — Symmetric 7-DoF Homography Epipolar Alignment &amp; MAAIR Crop Geometry',
            'heritage-badge': 'Historical Heritage · 19th Century Media Revolution',
            'heritage-title': '<span>Stereoview &amp; Stereograph</span><br><span>The 19th-Century Virtual Reality &amp; The Dawn of Spatial Media</span>',
            'heritage-subtitle': 'Over a century ago, Victorian parlors gathered around a magical binocular device known as the stereoscope. Far from a mere novelty, it was mankind’s first spatial media revolution—foreshadowing today’s VR headsets and Apple Vision Pro.',
            'story-essay-title': '19th-Century "Immersive Experience"!? The World and Desires Mirrored in Stereoscopic Photography',
            'story-essay-desc': 'On a rainy London evening by warm gaslight, families gathered around the stereoscope. From bourgeois status and the visceral truth of binocular disparity, to the desire to travel to Egypt and feudal Japan from the safety of home—this essay explores how 19th-century stereographs served as the world’s first physical world model, and what it reveals about our modern spatial desires.',
            'story-btn-text': 'Read Essay on note',
            'pillar-1-tag': 'Status &amp; Science',
            'pillar-1-title': 'The Magic Viewer &amp; Scientific Truth',
            'pillar-1-desc': 'For the rising Victorian bourgeoisie, owning a stereoscope was an indispensable mark of culture. In an era captivated by scientific positivism, stereoscopic depth—derived from human binocular disparity—was revered as more objectively true than flat art, delivering unprecedented visceral presence.',
            'pillar-2-tag': 'Virtual Travel',
            'pillar-2-title': 'The First Physical World Model',
            'pillar-2-desc': 'Armchair travelers journeyed to Egyptian pyramids and newly-opened Meiji Japan in 3D. Publishing titans like Underwood &amp; Underwood built global sales networks of boxed sets, creating a massive physical prototype of today’s Google Street View and AI world models.',
            'pillar-3-tag': 'Modern Revival',
            'pillar-3-title': 'From Antique Mounts to Spatial Photos',
            'pillar-3-desc': 'Vintage cards suffered from manual mounting tilts, structural aging, and keystone disparities. ViewStereo leverages Core ML card segmentation and 7-DoF homography rectification to eliminate disparities—reviving historical memories as pristine Apple Vision Pro Spatial Photos.',
            'btn-try-free': 'Download for Free',
            'btn-view-features': 'Explore Features',
            'feat-header-title': 'Refined Features',
            'feat-header-subtitle': 'Where AI card segmentation meets mathematical geometric optimization.',
            'feat-1-title': 'Core ML Card Segmentation & 7-DoF Homography',
            'feat-1-desc': 'StereoCardSeg (U-Net) with MobileSAM or SAM 2.1 Tiny isolates left/right prints and arch-top frames automatically. LAPACK dposv_ + IRLS 7-DoF symmetric homography eliminates hand-mounted tilt, keystone distortion, and vertical disparity down to sub-pixel precision.',
            'feat-2-title': 'Intelligent Stereo Window & MAAIR Crop',
            'feat-2-desc': 'Automatically places the stereo window using foreground disparity and Apple Vision Attention Saliency to prevent window violations, while MAAIR computes the largest valid rectangular crop with zero black borders.',
            'feat-3-title': 'Era-Authentic Digital Remount & Letterpress OCR',
            'feat-3-desc': 'Reconstruct damaged cards onto 8 historical mount presets from 1850s Early Ivory to 1900s Keystone Dark. Vision OCR extracts original titles and publisher margins and re-typesets them in authentic letterpress typography.',
            'feat-4-title': 'Spatial Photo Export & Folder Batch Processing',
            'feat-4-desc': 'Export across 11 layouts including Apple Vision Pro MV-HEVC Spatial Photos (HEIC), SBS, Dubois/Color/Gray Anaglyph, Polarized, MPO, and Separate L/R. Process entire archival folders automatically with optional .txt adjustment reports.',
            'tech-header-title': 'Powered by State-of-the-Art Tech',
            'tech-header-subtitle': 'Built on Core ML, Apple Vision, and Accelerate LAPACK optimized for Apple Silicon.',
            'about-sharp-content': `<p>ViewStereo runs custom Core ML localization (StereoCardSeg) alongside <a href="https://github.com/ChaoningZhang/MobileSAM" target="_blank" rel="noopener noreferrer" class="tech-link">MobileSAM</a> and Meta AI’s <a href="https://github.com/facebookresearch/sam2" target="_blank" rel="noopener noreferrer" class="tech-link">SAM 2.1 Tiny</a> directly on-device to trace degraded historical print edges. Its 7-DoF symmetric homography solver powered by Accelerate LAPACK (<code>dposv_</code>) and MAAIR cropping completely removes eye-straining vertical disparity.<br><span style="font-size: 0.9rem; color: var(--accent-vermilion); display: block; margin-top: 10px; font-weight: 600;">* All AI models are bundled locally and run 100% offline on your Mac.</span></p>`,
            'upd-header-title': 'Release History',
            'upd-header-subtitle': 'Continuously evolving for archival precision and spatial fidelity.',
            'upd-022-1': '[ViewStereo 0.2.2 Update] Deep Dome Arch Parametric Fitting & Anti-False-Positive Guards: Overhauled Stage 2 twin-window upper arch fitting to support deep dome curves (drop ratio up to ry <= 0.45) with adaptive superellipse exponents (p = 1.6 - 2.6) and Sobel gradient attraction. Added shoulder barrier verification (shoulderBarrierRatio over 14% x 14% corner regions) to safeguard square/rectangular prints from false arch misclassifications.',
            'upd-022-2': 'Keep Arch Inner Mask Offset & Anti-Aliased Blending: Sub-pixel margin insetting and signed-distance field anti-aliased normal blending (printAlphaAt) across StereoCardSegmenter and StereoCardMountRenderer eliminate black fringes and mount border bleed.',
            'upd-021-1': '[ViewStereo 0.2.1 Update] 3-Stage Cascade Mount Analyzer (StereoCardMountAnalyzer) & Crop Pipeline Renewal: Introduced Stage 0 (outer-connected CIE Lab flood-fill scan margin removal, RANSAC deskewing, and drop-shadow crossing with 3-fold white-mount safety guards), Stage 1 (adaptive step=1 rim sampling CIE Lab mount barrier for ultra-thin 5-10px borders with outer-connected protection), and Stage 2 (SAT + Sobel coordinate-descent twin-window parametric fitting).',
            'upd-021-2': 'Dark-Background, Caption & Arch Apex Overcrop Prevention: Refined SAM 2.1 Tiny mask tolerance and candidate selection to eliminate overcropping on dark-background photos (e.g., lunar scenes), fixed bottom caption trimmer false triggers from dark rule streaks, and synchronized arch apex Y detection.',
            'upd-021-3': 'Hardened Core ML PixelBuffer Input: Switched StereoCardSeg and SAM2_1TinyImageEncoder inputs to direct CVPixelBufferCreate rendering, resolving environment-dependent CVPixelBuffer creation errors.',
            'upd-020-1': '[ViewStereo 0.2.0 Update] 100% Symmetrical English & Japanese Localization: Completely eliminated hardcoded strings across advisory banners, interactive tooltips, and welcome guide cards. All 493 localization keys are now perfectly synchronized across both languages.',
            'upd-020-2': 'Hardened State Transitions, Cache Integrity & Memory Management: Fixed state leak bugs where manual swaps (X) or single-eye depth salvage modes persisted across image switches. Introduced explicit buffer reclamation (clearDepthSynthesisCache / clearStaticImageBuffers) to eliminate memory leaks during extended workflows.',
            'upd-020-3': 'Segmentation Engine Robustness & Crash Prevention: Added strict range bounds checking in corner detection and border sampling, permanently resolving edge-case fatal errors on unusual card aspect ratios.',
            'upd-020-4': 'Unified Shortcut Navigation: Added "Toggle Batch Processing Panel" (⌥⌘6) under the Panels menu, fully synchronizing the inspector\'s batch section expansion state.',
            'upd-019-1': '[ViewStereo 0.1.9 Update] Video 2D-to-3D Conversion & Spatial Video Generation: Support high-quality stereoscopic video conversion from 2D videos (.mp4 / .mov / .m4v) to Apple Vision Pro-ready Spatial Video (MV-HEVC), Full/Half SBS 3D, and Anaglyph 3D video formats.',
            'upd-019-2': 'Stateful Video Depth Inference with Apple Depth Pro 2: Leverages Core ML MLState (macOS 15+) for cross-frame hidden state persistence, automatic scene cut detection with blackout recovery, temporal smoothing (EMA), and depth range locking to eliminate depth flickering.',
            'upd-019-3': 'Metal GPU-Accelerated DIBR & Optimized AVFoundation Pipeline: Metal compute shader zero-copy warping, auto-rotation handling, tone-mapping, CVPixelBufferPool caching, AAC audio re-encoding, and pre-export disk space validation.',
            'upd-019-4': 'SBS 3D Video Extraction & Re-synthesis: Extract left or right eye channels from existing SBS 3D videos to reconstruct violation-free, comfortable 3D stereoscopic videos.',
            'upd-018-1': '[ViewStereo 0.1.8 Update] Intelligent Zero-Parallax Stereo Window Optimization for DIBR 2D-to-3D: Integrated depth map and Vision saliency analysis to dynamically calculate the optimal zero-parallax plane (focusRatio), preventing frame-edge stereoscopic window violations.',
            'upd-018-2': 'Enhanced High-Resolution Export & Batch 2D-to-3D Processing: Introduced full-resolution synthesis caching for pristine Spatial Photo, SBS, and Anaglyph exports with automatic window alignment applied during batch runs.',
            'upd-018-3': 'Unified Normalized Disparity Sampler: Standardized bilinear disparity interpolation with gamma/contrast curve controls for smoother real-time interactive parameter adjustments.',
            'upd-017-1': '[ViewStereo 0.1.7 Update] 3-Pane Studio Workflow with Tree-Style File Browser: Introduced persistent left sidebar file browser (⌥⌘L) with launch folder prompt, automatic L/R pair grouping (_L/_R), real-time status badges (✓/⚠️/✕), and output folder protection.',
            'upd-017-2': 'AI Depth Model Manager & 9 Multi-Engine Architecture: Full support for Apple Depth Pro, Depth Pro 2 (Small/Base/Large), Depth Anything V2/V3, and MoGe-2 (ViT-B/L) with on-demand downloading in Preferences and zero-duplicate shared storage across Stereo Studio apps.',
            'upd-017-3': 'Production-Grade Single-Eye Depth 3D Salvage Pipeline: High-fidelity 2D-to-3D stereoscopic synthesis powered by your preferred Core ML depth engine with automatic peak memory reclamation.',
            'upd-016-1': '[ViewStereo 0.1.6 Update] Single-Eye Depth 3D Salvage & Anomaly Diagnostics: Automatically diagnoses mismatched pairs, unilateral damage, and excessive disparity, offering 1-click AI Depth 3D conversion using either the pristine left or right image.',
            'upd-016-2': 'Stereo Source Controls in Stereo Window (⌥⌘2): Added persistent Stereo Source switcher (Original L+R / Left Depth 3D / Right Depth 3D), virtual stereo base slider (0.5% - 6.0%), and depth curve gamma controls.',
            'upd-016-3': 'Enhanced Stereo Card Segmentation: Introduced top-edge gradient protection safety guards and overcrop recovery to preserve sky and mountain peak contours without card border clipping.',
            'upd-015-1': '[ViewStereo 0.1.5 Update] Pseudoscopic Stereo Auto-Swap: Automatically detects reversed L/R stereocards upon import and auto-swaps channels, with immediate telemetry indicators.',
            'upd-015-2': 'Instant stereo window recalculation upon manual swapping (X key) to eliminate boundary violations caused by disparity reversal.',
            'upd-015-3': 'SAM 2.1 Tiny Segmentation Enhancement: Raised upper prompt point and introduced U-Net height arbitration to prevent top-border clipping.',
            'upd-014-1': '[ViewStereo 0.1.4 Update] Redesigned Right Inspector & Initial Collapse: Placed "Basic Settings (Auto Recipe)" at the top with smart initial expansion, while downstream adjustment panels remain collapsed.',
            'upd-014-2': 'Synchronized Shortcuts & Toolbar: Realigned keyboard shortcuts (⌥⌘1 Recipe through ⌥⌘6 Batch) and toolbar actions to match the vertical palette structure.',
            'upd-014-3': 'Independent Corner Detection & Mount Protection: Enhanced StereoCardSegmenter to independently measure rounded, square, and arched corners from background samples, improving center imprint healing protection.',
            'upd-013-1': '[ViewStereo 0.1.3 Update] Hand-Tinted & AI Colorization (StereoColorizer): 100% on-device 1890s Hand-Tinted (Watercolor), Natural Full Color (AI), and Harmonize Existing Hand-Tint modes.',
            'upd-013-2': 'Redesigned toolbar and added dedicated panel toggles for Sidebar, Restore, Colorize, Window, Mount, Recipe, Batch, and Export.',
            'upd-013-3': 'Consolidated segmentation onto StereoCardSeg + SAM 2.1 Tiny (removing redundant MobileSAM models) and added explicit restoration toggle/apply controls.',
            'upd-012-1': '[ViewStereo 0.1.2 Update] Vintage Photo Restoration & Tone Recovery: Added 1860s Albumen Sepia, 1890s Warm Silver, and Pure Monochrome print tones, Auto-Level, Local Contrast (CLAHE), and a real-time Compare Before toggle.',
            'upd-012-2': 'Bundled On-Device Core ML AI Optical Deblur (NAFNet-GoPro): Restores lens softness 100% offline with Foliage / Texture Protection to prevent stereoscopic retinal rivalry.',
            'upd-012-3': 'Enabled instant non-destructive dust removal preview updates and improved Update Manager initialization & localization.',
            'upd-011-1': '[ViewStereo 0.1.1 Update] Full Aspect Ratio & Composition Preservation in Digital Remount: Replaced Aspect Fill cropping with Aspect Fit + bilinear resampling and enhanced seamless gap detection (<1.5%) for gapless cards.',
            'upd-011-2': 'Optimized horizontal shift limits when preserving arch-top frames (2.0% auto / 3.5% manual) and synchronized clamped decision values with UI metrics.',
            'upd-011-3': 'Promoted "StereoView" (stereoview card display) to ⌘1 and moved "2D" to ⌘8.',
            'upd-010-1': 'Core ML Stereoview Card Auto-Segmentation (StereoCardSeg U-Net + MobileSAM / SAM 2.1 Tiny) with arch-top detection.',
            'upd-010-2': 'StereoCore 7-DoF Symmetric Homography alignment (LAPACK dposv_ + IRLS) and MAAIR optimal rectangular cropping.',
            'upd-010-3': 'Intelligent Stereo Window placement with Vision Attention Saliency, real-time shift controls, color harmonization, and unilateral dust removal.',
            'upd-010-4': 'Digital Remount engine featuring 8 historical mount presets (1850s–1900s) and Vision OCR letterpress typography.',
            'upd-010-5': 'Support for Apple Vision Pro Spatial Photo (MV-HEVC HEIC), SBS, Anaglyph, Polarized, MPO, and folder batch processing.',
            'dl-title': 'Experience It Now.',
            'dl-subtitle': 'ViewStereo v0.2.2 is now available.',
            'btn-download': 'Download ViewStereo',
            'dl-support': 'Supported on macOS 14.0+ (Apple Silicon Recommended)',
            'dev-notice-box': '<strong>[Early Development Software Notice]</strong><p>ViewStereo is currently under active early development (v0.1.x). Users who download and test this software are helping refine its specifications and stability. Please expect potential rough edges and ongoing changes.</p>',
            'foot-doc': 'Online Manual',
            'foot-privacy': 'Privacy Policy',
            'foot-credits': 'Acknowledgments',
            'disclaimer-title': 'Disclaimer & Licensing Notice',
            'disclaimer-content': 'ViewStereo is an experimental personal development project currently in an early stage of development, with no commercial activity or intent. Users who download and use the application participate in improving specifications and debugging. Bundled open-source AI models (such as MobileSAM and SAM 2.1 Tiny) are governed by their respective licenses (Apache License 2.0, etc.).',
            'lang-toggle': '日本語'
        }
    };

    const urlParams = new URLSearchParams(window.location.search);
    const urlLang = urlParams.get('lang');
    let currentLang = (urlLang === 'ja' || urlLang === 'en')
        ? urlLang
        : (localStorage.getItem('preferred-lang') || 'ja');

    const updateContent = (lang) => {
        document.querySelectorAll('[data-i18n]').forEach(element => {
            const key = element.getAttribute('data-i18n');
            if (translations[lang][key]) {
                if (element.tagName === 'META') {
                    element.setAttribute('content', translations[lang][key]);
                } else {
                    element.innerHTML = translations[lang][key];
                }

                if (key === 'hero-version') {
                    const versionText = translations[lang][key];
                    const dateMatch = versionText.match(/(\d{4})\.(\d{2})\.(\d{2})/);
                    if (dateMatch) {
                        const [, year, month, day] = dateMatch;
                        const today = new Date();
                        const isToday = today.getFullYear() === parseInt(year) &&
                                        (today.getMonth() + 1) === parseInt(month) &&
                                        today.getDate() === parseInt(day);
                        if (isToday) {
                            const badgeText = lang === 'ja' ? '本日更新！' : 'Updated Today!';
                            element.innerHTML = `${versionText} <span class="new-update-badge">${badgeText}</span>`;
                        }
                    }
                }
            }
        });

        document.querySelectorAll('[data-i18n="foot-doc"]').forEach(link => {
            link.href = lang === 'ja' ? 'docs.html' : 'docs_en.html';
        });

        const noteBtn = document.getElementById('btn-note-essay');
        if (noteBtn) {
            noteBtn.href = lang === 'ja'
                ? 'https://note.com/haeckel/n/n31372cc17f94?magazine_key=m24d5931d3b7e'
                : 'https://note.com/haeckel/n/n31372cc17f94?magazine_key=m24d5931d3b7e&hl=en';
        }

        const langToggle = document.getElementById('lang-toggle');
        if (langToggle) {
            langToggle.textContent = translations[lang]['lang-toggle'];
        }

        document.documentElement.lang = lang;
        localStorage.setItem('preferred-lang', lang);
    };

    const langToggleBtn = document.getElementById('lang-toggle');
    if (langToggleBtn) {
        langToggleBtn.addEventListener('click', () => {
            currentLang = currentLang === 'ja' ? 'en' : 'ja';
            updateContent(currentLang);
        });
    }

    updateContent(currentLang);

    // Reveal elements on scroll
    const revealElements = document.querySelectorAll('.reveal');
    const revealOnScroll = () => {
        const windowHeight = window.innerHeight;
        const revealPoint = 150;
        revealElements.forEach(element => {
            const revealTop = element.getBoundingClientRect().top;
            if (revealTop < windowHeight - revealPoint) {
                element.classList.add('active');
            }
        });
    };
    window.addEventListener('scroll', revealOnScroll);
    revealOnScroll();

    // Smooth scrolling
    document.querySelectorAll('a[href^="#"]').forEach(anchor => {
        anchor.addEventListener('click', function (e) {
            e.preventDefault();
            const targetId = this.getAttribute('href');
            if (targetId === '#') return;
            const targetElement = document.querySelector(targetId);
            if (targetElement) {
                window.scrollTo({
                    top: targetElement.offsetTop - 80,
                    behavior: 'smooth'
                });
            }
        });
    });

    // =========================================================================
    // Stereoview Calibration Grid & Optical Parallax Background (Canvas)
    // =========================================================================
    const initSpatialCanvas = () => {
        const canvas = document.getElementById('spatial-canvas');
        if (!canvas) return;
        const ctx = canvas.getContext('2d');
        if (!ctx) return;

        let width = 0;
        let height = 0;
        let dpr = 1;
        let isVisible = true;

        const resize = () => {
            dpr = Math.min(window.devicePixelRatio || 1, 2);
            width = canvas.parentElement.offsetWidth || window.innerWidth;
            height = canvas.parentElement.offsetHeight || window.innerHeight;
            canvas.width = width * dpr;
            canvas.height = height * dpr;
            ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        };

        window.addEventListener('resize', resize);
        resize();

        const heroSection = document.querySelector('.hero');
        if (heroSection && 'IntersectionObserver' in window) {
            const observer = new IntersectionObserver((entries) => {
                isVisible = entries[0].isIntersecting;
            }, { threshold: 0.05 });
            observer.observe(heroSection);
        }

        const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
        let phase = 0;
        let targetTiltX = 0;
        let targetTiltY = 0;
        let currentTiltX = 0;
        let currentTiltY = 0;

        if (!reducedMotion) {
            window.addEventListener('mousemove', (e) => {
                const nx = (e.clientX / window.innerWidth) * 2 - 1;
                const ny = (e.clientY / window.innerHeight) * 2 - 1;
                targetTiltX = ny * 18;
                targetTiltY = nx * 24;
            }, { passive: true });
        }

        const drawArchFrame = (cx, cy, w, h, alpha, color) => {
            const r = w * 0.42;
            const x0 = cx - w / 2;
            const y0 = cy - h / 2;
            ctx.save();
            ctx.beginPath();
            ctx.moveTo(x0, y0 + h);
            ctx.lineTo(x0, y0 + r);
            ctx.quadraticCurveTo(x0, y0, x0 + r, y0);
            ctx.lineTo(x0 + w - r, y0);
            ctx.quadraticCurveTo(x0 + w, y0, x0 + w, y0 + r);
            ctx.lineTo(x0 + w, y0 + h);
            ctx.closePath();
            ctx.strokeStyle = color;
            ctx.globalAlpha = alpha;
            ctx.lineWidth = 1.25;
            ctx.stroke();
            ctx.restore();
        };

        const render = () => {
            if (!isVisible) {
                requestAnimationFrame(render);
                return;
            }

            ctx.clearRect(0, 0, width, height);
            phase += 0.012;
            currentTiltX += (targetTiltX - currentTiltX) * 0.05;
            currentTiltY += (targetTiltY - currentTiltY) * 0.05;

            const cx = width > 1024 ? width * 0.65 : width * 0.5;
            const cy = height * 0.52;
            const cardW = Math.min(width, height) * 0.58;
            const cardH = cardW * 0.5;

            // Perspective grid lines (delicate sepia drafting grid)
            ctx.save();
            ctx.strokeStyle = 'rgba(35, 27, 20, 0.055)';
            ctx.lineWidth = 1;
            const cols = 10;
            const rows = 6;
            const gx0 = cx - cardW * 0.75 + currentTiltY * 0.4;
            const gy0 = cy - cardH * 0.75 + currentTiltX * 0.4;
            const gw = cardW * 1.5;
            const gh = cardH * 1.5;

            for (let i = 0; i <= cols; i++) {
                const x = gx0 + (gw / cols) * i;
                ctx.beginPath();
                ctx.moveTo(x, gy0);
                ctx.lineTo(x, gy0 + gh);
                ctx.stroke();
            }
            for (let j = 0; j <= rows; j++) {
                const y = gy0 + (gh / rows) * j;
                ctx.beginPath();
                ctx.moveTo(gx0, y);
                ctx.lineTo(gx0 + gw, y);
                ctx.stroke();
            }
            ctx.restore();

            // Twin Stereoview Arch Frames with subtle convergence oscillation
            const parallax = Math.sin(phase) * 6;
            const twinW = cardW * 0.38;
            const twinH = cardH * 0.74;
            const gap = cardW * 0.04;

            drawArchFrame(cx - twinW / 2 - gap + currentTiltY * 0.7 - parallax, cy + currentTiltX * 0.7, twinW, twinH, 0.22, '#9A7234');
            drawArchFrame(cx + twinW / 2 + gap + currentTiltY * 0.7 + parallax, cy + currentTiltX * 0.7, twinW, twinH, 0.22, '#9E3A2E');

            // Epiline horizontal alignment guide
            ctx.save();
            ctx.setLineDash([4, 6]);
            ctx.strokeStyle = 'rgba(158, 58, 46, 0.22)';
            ctx.beginPath();
            ctx.moveTo(cx - cardW * 0.65, cy + currentTiltX * 0.7);
            ctx.lineTo(cx + cardW * 0.65, cy + currentTiltX * 0.7);
            ctx.stroke();
            ctx.restore();

            if (!reducedMotion) {
                requestAnimationFrame(render);
            }
        };

        if (reducedMotion) {
            render();
        } else {
            requestAnimationFrame(render);
        }
    };

    // =========================================================================
    // Hero 3D Studio Window Interactive Parallax
    // =========================================================================
    const initHeroParallax = () => {
        const showcase = document.getElementById('hero-showcase');
        const stage = document.getElementById('layer-stage');
        if (!showcase || !stage) return;

        if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
            stage.style.transform = 'rotateY(-14.00deg) rotateX(8.00deg)';
            return;
        }

        let targetRotX = 8;
        let targetRotY = -14;
        let curRotX = 8;
        let curRotY = -14;

        showcase.addEventListener('mousemove', (e) => {
            const rect = showcase.getBoundingClientRect();
            const nx = ((e.clientX - rect.left) / rect.width) * 2 - 1;
            const ny = ((e.clientY - rect.top) / rect.height) * 2 - 1;

            targetRotY = -14 + nx * 10;
            targetRotX = 8 - ny * 8;
        });

        showcase.addEventListener('mouseleave', () => {
            targetRotX = 8;
            targetRotY = -14;
        });

        const updateParallax = () => {
            curRotX += (targetRotX - curRotX) * 0.08;
            curRotY += (targetRotY - curRotY) * 0.08;

            stage.style.transform = `rotateY(${curRotY.toFixed(2)}deg) rotateX(${curRotX.toFixed(2)}deg)`;
            requestAnimationFrame(updateParallax);
        };

        requestAnimationFrame(updateParallax);
    };

    initSpatialCanvas();
    initHeroParallax();

    console.log('ViewStereo Studio visual experience initialized.');
});
