document.addEventListener('DOMContentLoaded', () => {
    // Translation Data
    const translations = {
        'ja': {
            'meta-desc': 'ViewStereo - 19世紀ステレオカードのAI自動検出・7自由度ホモグラフィ整準・デジタルリマウント & 空間写真復元スタジオ',
            'title': 'ViewStereo | 歴史的ステレオカード復元 & インテリジェント・ステレオウィンドウスタジオ',
            'mac-exclusive': ' ViewStereo は macOS 専用アプリケーションです。',
            'nav-features': '機能',
            'nav-stereoview': '歴史と魅力',
            'nav-tech': 'テクノロジー',
            'nav-download': 'ダウンロード',
            'btn-get-beta': '無料ダウンロード',
            'hero-title': '<span>時を超えた立体視、</span><br><span>精密に蘇る。</span>',
            'hero-version': 'v0.1.4 (2026.11.20)',
            'dev-status-badge': '開発初期・現在開発中',
            'hero-subtitle': 'ViewStereo は、19世紀の歴史的ステレオカード（Stereoview / Stereograph）や現代のステレオ写真を、Core ML自動検出・7自由度対称ホモグラフィ整準・ステレオウィンドウ最適化によって高品位な空間写真やデジタル・リマウントカードへ復元する macOS 専用アプリケーションです。',
            'about-desc': 'ViewStereo は、StereoCardSeg (U-Net) と MobileSAM / SAM 2.1 Tiny による精密なカード領域抽出と、Accelerate LAPACK (dposv_ + IRLS) を用いた7自由度対称ホモグラフィ整準を統合。19世紀ステレオカードの傾き・歪み・垂直視差・経年退色を自動で補正し、Apple Vision Pro 空間写真（MV-HEVC）や時代別デジタル・リマウントカードとして現代に蘇らせます。',
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
            'btn-view-features': '機能を見る',
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
            'about-sharp-content': `<p>ViewStereo は、独自の Core ML モデル「StereoCardSeg」に加え、<a href="https://github.com/ChaoningZhang/MobileSAM" target="_blank" rel="noopener noreferrer" class="tech-link">MobileSAM</a> や Meta AI の <a href="https://github.com/facebookresearch/sam2" target="_blank" rel="noopener noreferrer" class="tech-link">SAM 2.1 Tiny</a> をオンデバイスで実行し、劣化した歴史的ステレオカードの印画境界を正確に抽出します。続く幾何補正では Accelerate LAPACK (<code>dposv_</code>) による7自由度対称ホモグラフィ最適化と MAAIR 内接矩形クロップを行い、視覚的疲労の原因となる垂直視差を完全に排除します。<br><span style="font-size: 0.9rem; color: #FDE68A; display: block; margin-top: 10px;">※すべての AI モデルはアプリに同梱され、100% オンデバイス（オフライン）で高速に動作します。</span></p>`,
            'upd-header-title': '更新履歴',
            'upd-header-subtitle': '精度と再現性の向上のため、進化し続けます。',
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
            'dl-subtitle': 'ViewStereo v0.1.4 がリリースされました。',
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
            'nav-features': 'Features',
            'nav-stereoview': 'Stereoview Heritage',
            'nav-tech': 'Technology',
            'nav-download': 'Download',
            'btn-get-beta': 'Free Download',
            'hero-title': '<span>Timeless Stereoscopy,</span><br><span>Precision Restored.</span>',
            'hero-version': 'v0.1.4 (2026.11.20)',
            'dev-status-badge': 'Early Development',
            'hero-subtitle': 'ViewStereo is a native macOS studio app that transforms 19th-century historical stereoview cards and modern stereo photos into pristine Apple Vision Pro Spatial Photos, SBS, and digitally remounted cards using Core ML segmentation and 7-DoF homography alignment.',
            'about-desc': 'ViewStereo combines StereoCardSeg (U-Net) and MobileSAM / SAM 2.1 Tiny mask refinement with Accelerate LAPACK (dposv_ + IRLS) 7-DoF symmetric homography alignment. It automatically eliminates vertical disparity, keystone distortion, and color aging—preserving heritage stereoviews for modern spatial displays.',
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
            'about-sharp-content': `<p>ViewStereo runs custom Core ML localization (StereoCardSeg) alongside <a href="https://github.com/ChaoningZhang/MobileSAM" target="_blank" rel="noopener noreferrer" class="tech-link">MobileSAM</a> and Meta AI’s <a href="https://github.com/facebookresearch/sam2" target="_blank" rel="noopener noreferrer" class="tech-link">SAM 2.1 Tiny</a> directly on-device to trace degraded historical print edges. Its 7-DoF symmetric homography solver powered by Accelerate LAPACK (<code>dposv_</code>) and MAAIR cropping completely removes eye-straining vertical disparity.<br><span style="font-size: 0.9rem; color: #FDE68A; display: block; margin-top: 10px;">* All AI models are bundled locally and run 100% offline on your Mac.</span></p>`,
            'upd-header-title': 'Release History',
            'upd-header-subtitle': 'Continuously evolving for archival precision and spatial fidelity.',
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
            'dl-subtitle': 'ViewStereo v0.1.4 is now available.',
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

            // Perspective grid lines
            ctx.save();
            ctx.strokeStyle = 'rgba(245, 166, 35, 0.09)';
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

            drawArchFrame(cx - twinW / 2 - gap + currentTiltY * 0.7 - parallax, cy + currentTiltX * 0.7, twinW, twinH, 0.35, '#F5A623');
            drawArchFrame(cx + twinW / 2 + gap + currentTiltY * 0.7 + parallax, cy + currentTiltX * 0.7, twinW, twinH, 0.35, '#FFB84D');

            // Epiline horizontal alignment guide
            ctx.save();
            ctx.setLineDash([4, 6]);
            ctx.strokeStyle = 'rgba(255, 184, 77, 0.22)';
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
