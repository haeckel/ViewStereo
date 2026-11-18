/**
 * Spatial Creative Studio Trilogy — Shared UI & i18n Module
 * Mounts #trilogy, #heritage, and .footer-trilogy-nav across:
 *   - SplatStereo (splat)
 *   - DepthStereo (depth)
 *   - PanorStereo (panor)
 */
(() => {
    const STUDIO_HUB = {
        id: 'studio',
        name: 'StereoStudio Labs',
        url: 'https://stereostudio.p-media.jp/'
    };

    const SERIES = [
        {
            id: 'splat',
            name: 'SplatStereo',
            shortTag: '3DGS',
            colorClass: 'red',
            labelJa: 'Red — 3DGS',
            labelEn: 'Red — 3DGS',
            statusClass: 'status-dev',
            statusKey: 'trilogy-status-dev',
            url: 'https://splatstereo.p-media.jp/',
            descKey: 'trilogy-splat-desc'
        },
        {
            id: 'depth',
            name: 'DepthStereo',
            shortTag: '2.5D',
            colorClass: 'green',
            labelJa: 'Green — 2.5D',
            labelEn: 'Green — 2.5D',
            statusClass: 'status-early',
            statusKey: 'trilogy-status-early',
            url: 'https://depthstereo.p-media.jp/',
            descKey: 'trilogy-depth-desc'
        },
        {
            id: 'panor',
            name: 'PanorStereo',
            shortTag: '360°',
            colorClass: 'white',
            labelJa: 'White — 360°',
            labelEn: 'White — 360°',
            statusClass: 'status-early',
            statusKey: 'trilogy-status-early',
            url: 'https://panorstereo.p-media.jp/',
            descKey: 'trilogy-panor-desc'
        }
    ];

    const SHARED_TRANSLATIONS = {
        ja: {
            'trilogy-title': '空間の可能性を切り拓く、3つのアプローチ',
            'trilogy-subtitle': '対象フォーマットと数理的アプローチに特化した、Apple Silicon ネイティブの立体視スタジオ群。',
            'trilogy-heritage-link': '☞ 3色のカラーに込められた歴史的インスピレーション（Stereo Realist）を見る',
            'trilogy-splat-desc': '3D Gaussian Splatting による高忠実度なシーン再構築と自由視点レンダリング。',
            'trilogy-depth-desc': '単眼写真からAIメトリック深度を推定し、精密な2.5D視差と空間ビデオを生成。',
            'trilogy-panor-desc': '360°全天球パノラマ写真から全方位深度を解析し、無劣化なODS立体空間を構築。',
            'trilogy-btn-open': '公式サイトを開く →',
            'trilogy-btn-current': '閲覧中（本サイト）',
            'trilogy-current-tag': 'Current',
            'trilogy-status-dev': '現在開発中',
            'trilogy-status-early': '開発初期・開発中',
            'trilogy-dev-notice-title': '開発状況とダウンロード利用に関するご注意',
            'trilogy-dev-notice-body': '<strong>SplatStereo</strong>・<strong>DepthStereo</strong>・<strong>PanorStereo</strong> はいずれも<strong>現在開発中</strong>のソフトウェアです。特に <strong>DepthStereo</strong> および <strong>PanorStereo</strong> は<strong>開発初期段階</strong>にあります。ダウンロードしてご利用いただくユーザーには、アプリの仕様向上およびデバッグ作業にお付き合いいただく形となります。不具合や仕様変更が生じる可能性がありますので、あらかじめご了承のうえお試しください。',
            'trilogy-studio-pill': 'Created by StereoStudio Labs ↗',
            'studio-portal-kicker': '制作チーム公式ポータル',
            'studio-portal-title': 'StereoStudio Labs — 三部作総合ポータルサイト',
            'studio-portal-desc': 'SplatStereo・DepthStereo・PanorStereo を開発する制作チーム「StereoStudio Labs」の公式サイト。用途別の選び方ガイド、共通技術基盤「StereoStudioCore」の解説、制作思想や開発ストーリーをご覧いただけます。',
            'studio-portal-btn': 'StereoStudio Labs ポータルを開く →',

            'heritage-badge': 'Design Heritage & Inspiration',
            'heritage-title': '3色のカラーに宿る、立体視の歴史へのオマージュ',
            'heritage-subtitle': 'Stereo Creative Studio Trilogy（SplatStereo / DepthStereo / PanorStereo）のシグネチャーカラーは、1950年代のステレオ写真黄金期を築いた「Stereo Realist」スライドビューワーの3大銘機への敬意から生まれました。',
            'heritage-image-caption': 'David White社（Realist社）ステレオ・リアリスト用スライドビューワーの系譜',
            'heritage-lead': 'David White社（後のRealist社）が世に送り出したステレオ・リアリスト用スライドビューワーは、押しボタンの色によってレンズの光学構成やフォーカス機構、電源仕様が明確に区別されていました。本スタジオ三部作のカラーリングは、この歴史的な3つの銘機への深いオマージュです。',
            'heritage-red-name': 'Red Button',
            'heritage-red-pair': '➔ <strong>SplatStereo</strong> のシグネチャー',
            'heritage-red-spec-1': '<strong>光学系:</strong> 2枚構成のガラス製アクロマート（色消し）レンズを搭載し、色収差を極限まで抑えた圧倒的な描写力を実現。',
            'heritage-red-spec-2': '<strong>機構と操作性:</strong> 金属製ラック・アンド・ピニオンによる精密フォーカスと眼幅調整機構を完備。',
            'heritage-red-spec-3': '<strong>位置づけ:</strong> 1950年代の標準機にして、最も高い評価と流通量を誇る不朽のフラッグシップ。妥協なき3DGS空間再構築の象徴。',
            'heritage-green-name': 'Green Button',
            'heritage-green-pair': '➔ <strong>DepthStereo</strong> のシグネチャー',
            'heritage-green-spec-1': '<strong>光学系:</strong> レッドボタンと同等の高性能ガラス製アクロマートレンズを継承。',
            'heritage-green-spec-2': '<strong>機構と操作性:</strong> スライドキャリア側を前後させるインナーフォーカス方式を採用。AC/DC両用設計。',
            'heritage-green-spec-3': '<strong>位置づけ:</strong> 卓上での連続鑑賞に適した先進のエレクトリック・ステレオ・ビューワー。高精度AIメトリック深度を自在に操るDepthStereoの工学的探求の象徴。',
            'heritage-white-name': 'White Button',
            'heritage-white-pair': '➔ <strong>PanorStereo</strong> のシグネチャー',
            'heritage-white-spec-1': '<strong>光学系:</strong> 軽快でシンプルな単玉（シングルエレメント）ガラスレンズを採用。',
            'heritage-white-spec-2': '<strong>機構と操作性:</strong> スライドを押し込むだけで点灯する直感的なスイッチ構造と、フリクション式ピント調整。',
            'heritage-white-spec-3': '<strong>位置づけ:</strong> 小型・軽量でどこへでも持ち出せる携帯性重視の普及版「Handi-Viewer」。誰もが360°全天球パノラマの世界へ自由に飛び込めるPanorStereoの普遍性の象徴。'
        },
        en: {
            'trilogy-title': 'Three Approaches to Unlocking Spatial Possibilities',
            'trilogy-subtitle': 'Apple Silicon-native stereoscopic creative studios, each purpose-built for a distinct format and mathematical model.',
            'trilogy-heritage-link': '☞ Explore the historical inspiration behind the three colors (Stereo Realist)',
            'trilogy-splat-desc': 'High-fidelity scene reconstruction and free-viewpoint rendering powered by 3D Gaussian Splatting.',
            'trilogy-depth-desc': 'Monocular AI metric depth estimation crafting lossless 2.5D parallax and Spatial Video.',
            'trilogy-panor-desc': 'Omnidirectional depth analysis for 360° equirectangular panoramas, synthesizing lossless ODS stereo.',
            'trilogy-btn-open': 'Visit Official Site →',
            'trilogy-btn-current': 'Viewing (Current Site)',
            'trilogy-current-tag': 'Current',
            'trilogy-status-dev': 'In Development',
            'trilogy-status-early': 'Early Development',
            'trilogy-dev-notice-title': 'Development Status & Notice for Download Users',
            'trilogy-dev-notice-body': '<strong>SplatStereo</strong>, <strong>DepthStereo</strong>, and <strong>PanorStereo</strong> are all <strong>currently under active development</strong>. In particular, <strong>DepthStereo</strong> and <strong>PanorStereo</strong> are in an <strong>early stage of development</strong>. Users who download and run these apps will be participating in improving their specifications and debugging. Please expect potential bugs, rough edges, and ongoing changes.',
            'trilogy-studio-pill': 'Created by StereoStudio Labs ↗',
            'studio-portal-kicker': 'Official Studio Portal',
            'studio-portal-title': 'StereoStudio Labs — Portal of the Trilogy',
            'studio-portal-desc': 'Visit the official hub of StereoStudio Labs, the creative team behind SplatStereo, DepthStereo, and PanorStereo. Explore our interactive workflow finder, the shared StereoStudioCore architecture, design philosophy, and behind-the-scenes stories.',
            'studio-portal-btn': 'Visit StereoStudio Labs Portal →',

            'heritage-badge': 'Design Heritage & Inspiration',
            'heritage-title': 'A Tribute to Stereoscopic History in Three Colors',
            'heritage-subtitle': 'The signature colors of the Stereo Creative Studio Trilogy (SplatStereo / DepthStereo / PanorStereo) draw deep inspiration from the three legendary Stereo Realist slide viewer models of the 1950s.',
            'heritage-image-caption': 'Lineage of David White (Realist, Inc.) Stereo Realist Slide Viewers',
            'heritage-lead': 'David White Company (later Realist, Inc.) engineered stereo viewers whose button colors distinctly identified their optical configuration, focusing mechanism, and power supply. The Trilogy color system is an authentic tribute to these three landmark instruments.',
            'heritage-red-name': 'Red Button',
            'heritage-red-pair': '➔ Signature for <strong>SplatStereo</strong>',
            'heritage-red-spec-1': '<strong>Optics:</strong> 2-element glass achromatic doublet with minimal chromatic aberration and razor-sharp fidelity.',
            'heritage-red-spec-2': '<strong>Mechanics:</strong> Precision metal rack-and-pinion focusing with adjustable interpupillary distance.',
            'heritage-red-spec-3': '<strong>Positioning:</strong> The definitive flagship standard of the 1950s stereo era. Embodying SplatStereo’s uncompromising 3DGS scene reconstruction.',
            'heritage-green-name': 'Green Button',
            'heritage-green-pair': '➔ Signature for <strong>DepthStereo</strong>',
            'heritage-green-spec-1': '<strong>Optics:</strong> Inherits the same top-tier achromatic glass lenses as the Red Button.',
            'heritage-green-spec-2': '<strong>Mechanics:</strong> Internal slide-carrier focusing and versatile AC/DC power options.',
            'heritage-green-spec-3': '<strong>Positioning:</strong> Advanced electric stereo viewer built for extended tabletop viewing. Embodying DepthStereo’s exploration of continuous metric depth synthesis.',
            'heritage-white-name': 'White Button',
            'heritage-white-pair': '➔ Signature for <strong>PanorStereo</strong>',
            'heritage-white-spec-1': '<strong>Optics:</strong> Lightweight single-element glass lenses for portable immediacy.',
            'heritage-white-spec-2': '<strong>Mechanics:</strong> Push-to-light slide insertion switch and friction focusing.',
            'heritage-white-spec-3': '<strong>Positioning:</strong> Portable and ubiquitous Handi-Viewer format. Embodying PanorStereo’s universality—inviting everyone to step freely into 360° panoramas.'
        }
    };

    const resolveInitialLang = () => {
        const urlLang = new URLSearchParams(window.location.search).get('lang');
        if (urlLang === 'ja' || urlLang === 'en') {
            localStorage.setItem('preferred-lang', urlLang);
            return urlLang;
        }
        const stored = localStorage.getItem('preferred-lang');
        if (stored === 'ja' || stored === 'en') {
            return stored;
        }
        const docLang = document.documentElement.lang;
        return (docLang === 'en') ? 'en' : 'ja';
    };

    const buildSeriesUrl = (baseUrl, lang) => (lang === 'en' ? `${baseUrl}?lang=en` : baseUrl);

    const buildTrilogyHTML = (currentId, version) => {
        const cardsHTML = SERIES.map(item => {
            const isCurrent = item.id === currentId;
            const activeClasses = isCurrent ? ` active-current active-${item.id}` : '';
            const label = isCurrent ? `${item.labelEn} — Current` : item.labelEn;
            const actionHTML = isCurrent
                ? `<span class="btn-trilogy-current" data-shared-i18n="trilogy-btn-current">閲覧中（本サイト）</span>`
                : `<a href="${item.url}" class="btn-trilogy-link link-${item.id}" data-series-href="${item.url}" data-shared-i18n="trilogy-btn-open">公式サイトを開く →</a>`;

            return `
                <div class="trilogy-card card-${item.id}${activeClasses}">
                    <div class="card-header-badge">
                        <div class="card-color-dot dot-${item.colorClass}"></div>
                        <span class="card-label">${label}</span>
                        <span class="trilogy-status-pill ${item.statusClass}" data-shared-i18n="${item.statusKey}"></span>
                    </div>
                    <h3>${item.name}</h3>
                    <p data-shared-i18n="${item.descKey}"></p>
                    <div class="trilogy-card-action">${actionHTML}</div>
                </div>
            `;
        }).join('');

        const isStudio = currentId === STUDIO_HUB.id;
        const badgeHTML = isStudio
            ? `<div class="badge-zen">Spatial Creative Studio Trilogy</div>`
            : `
                <div class="trilogy-badge-row">
                    <div class="badge-zen">Spatial Creative Studio Trilogy</div>
                    <a href="${STUDIO_HUB.url}" class="badge-zen badge-studio-pill" data-series-href="${STUDIO_HUB.url}">
                        <span class="studio-tricolor-dots" aria-hidden="true"><span class="d-red"></span><span class="d-green"></span><span class="d-white"></span></span>
                        <span data-shared-i18n="trilogy-studio-pill">Created by StereoStudio Labs ↗</span>
                    </a>
                </div>
            `;

        const portalCardHTML = isStudio ? '' : `
            <div class="studio-portal-card">
                <div class="studio-portal-brand">
                    <div class="studio-portal-icon">
                        <picture>
                            <source type="image/webp" srcset="assets/studio_icon.webp?v=${version}">
                            <img src="assets/studio_icon.png?v=${version}" alt="StereoStudio Labs Unified Icon" width="512" height="512" loading="lazy">
                        </picture>
                    </div>
                    <div class="studio-portal-info">
                        <div class="studio-portal-kicker">
                            <span class="studio-tricolor-dots" aria-hidden="true"><span class="d-red"></span><span class="d-green"></span><span class="d-white"></span></span>
                            <span data-shared-i18n="studio-portal-kicker">制作チーム公式ポータル</span>
                        </div>
                        <h3 data-shared-i18n="studio-portal-title">StereoStudio Labs — 三部作総合ポータルサイト</h3>
                        <p data-shared-i18n="studio-portal-desc">SplatStereo・DepthStereo・PanorStereo を開発する制作チーム「StereoStudio Labs」の公式サイト。用途別の選び方ガイド、共通技術基盤「StereoStudioCore」の解説、制作思想や開発ストーリーをご覧いただけます。</p>
                    </div>
                </div>
                <div class="studio-portal-action">
                    <a href="${STUDIO_HUB.url}" class="btn-studio-portal" data-series-href="${STUDIO_HUB.url}" data-shared-i18n="studio-portal-btn">StereoStudio Labs ポータルを開く →</a>
                </div>
            </div>
        `;

        return `
            <section class="stereo-trilogy" id="trilogy">
                <div class="container reveal">
                    <div class="trilogy-header">
                        <a href="${STUDIO_HUB.url}" class="trilogy-unified-emblem" data-series-href="${STUDIO_HUB.url}" aria-label="StereoStudio Labs Trilogy Unified Emblem">
                            <picture>
                                <source type="image/webp" srcset="assets/studio_icon.webp?v=${version}">
                                <img src="assets/studio_icon.png?v=${version}" alt="StereoStudio Labs Trilogy Icon" width="512" height="512" loading="lazy">
                            </picture>
                        </a>
                        ${badgeHTML}
                        <h2 data-shared-i18n="trilogy-title">空間の可能性を切り拓く、3つのアプローチ</h2>
                        <p>
                            <span data-shared-i18n="trilogy-subtitle">対象フォーマットと数理的アプローチに特化した、Apple Silicon ネイティブの立体視スタジオ群。</span>
                            <br>
                            <a href="#heritage" class="trilogy-heritage-anchor" data-shared-i18n="trilogy-heritage-link">☞ 3色のカラーに込められた歴史的インスピレーション（Stereo Realist）を見る</a>
                        </p>
                    </div>
                    <div class="trilogy-banner">
                        <picture>
                            <source type="image/webp" srcset="assets/series_trilogy.webp?v=${version}">
                            <img src="assets/series_trilogy.jpg?v=${version}" alt="SplatStereo, DepthStereo, PanorStereo" class="trilogy-image" width="1024" height="377" loading="lazy">
                        </picture>
                    </div>
                    <div class="trilogy-grid">
                        ${cardsHTML}
                    </div>
                    <div class="trilogy-dev-notice">
                        <div class="trilogy-dev-notice-title" data-shared-i18n="trilogy-dev-notice-title">開発状況とダウンロード利用に関するご注意</div>
                        <p data-shared-i18n="trilogy-dev-notice-body"></p>
                    </div>
                    ${portalCardHTML}
                </div>
            </section>
        `;
    };

    const buildHeritageHTML = (currentId, version) => {
        const redCurrent = currentId === 'splat' ? ' is-current-heritage' : '';
        const greenCurrent = currentId === 'depth' ? ' is-current-heritage' : '';
        const whiteCurrent = currentId === 'panor' ? ' is-current-heritage' : '';

        return `
            <section class="heritage" id="heritage">
                <div class="container reveal">
                    <div class="section-header">
                        <div class="badge-zen" data-shared-i18n="heritage-badge">Design Heritage &amp; Inspiration</div>
                        <h2 data-shared-i18n="heritage-title">3色のカラーに宿る、立体視の歴史へのオマージュ</h2>
                        <p data-shared-i18n="heritage-subtitle"></p>
                    </div>

                    <div class="heritage-banner">
                        <picture>
                            <source type="image/webp" srcset="assets/stereo_realist_viewers.webp?v=${version}">
                            <img src="assets/stereo_realist_viewers.jpg?v=${version}" alt="David White Stereo Realist Slide Viewers: Red Button (ST-61), Green Button (ST-62), White Button (ST-63)" class="heritage-image" width="1024" height="571" loading="lazy">
                        </picture>
                        <div class="heritage-image-caption" data-shared-i18n="heritage-image-caption"></div>
                    </div>

                    <div class="heritage-story">
                        <p class="heritage-lead" data-shared-i18n="heritage-lead"></p>
                        <div class="heritage-grid">
                            <div class="heritage-card card-red${redCurrent}">
                                <div class="heritage-card-header">
                                    <span class="heritage-btn-dot dot-red"></span>
                                    <div class="heritage-card-title">
                                        <h3 data-shared-i18n="heritage-red-name">Red Button</h3>
                                        <span class="model-code">ST-61 / Model 2061</span>
                                    </div>
                                </div>
                                <div class="heritage-trilogy-pairing" data-shared-i18n="heritage-red-pair"></div>
                                <ul class="heritage-specs">
                                    <li data-shared-i18n="heritage-red-spec-1"></li>
                                    <li data-shared-i18n="heritage-red-spec-2"></li>
                                    <li data-shared-i18n="heritage-red-spec-3"></li>
                                </ul>
                            </div>

                            <div class="heritage-card card-green${greenCurrent}">
                                <div class="heritage-card-header">
                                    <span class="heritage-btn-dot dot-green"></span>
                                    <div class="heritage-card-title">
                                        <h3 data-shared-i18n="heritage-green-name">Green Button</h3>
                                        <span class="model-code">ST-62 / Model 2062</span>
                                    </div>
                                </div>
                                <div class="heritage-trilogy-pairing" data-shared-i18n="heritage-green-pair"></div>
                                <ul class="heritage-specs">
                                    <li data-shared-i18n="heritage-green-spec-1"></li>
                                    <li data-shared-i18n="heritage-green-spec-2"></li>
                                    <li data-shared-i18n="heritage-green-spec-3"></li>
                                </ul>
                            </div>

                            <div class="heritage-card card-white${whiteCurrent}">
                                <div class="heritage-card-header">
                                    <span class="heritage-btn-dot dot-white"></span>
                                    <div class="heritage-card-title">
                                        <h3 data-shared-i18n="heritage-white-name">White Button</h3>
                                        <span class="model-code">ST-63 / Model 2063 (Handi-Viewer)</span>
                                    </div>
                                </div>
                                <div class="heritage-trilogy-pairing" data-shared-i18n="heritage-white-pair"></div>
                                <ul class="heritage-specs">
                                    <li data-shared-i18n="heritage-white-spec-1"></li>
                                    <li data-shared-i18n="heritage-white-spec-2"></li>
                                    <li data-shared-i18n="heritage-white-spec-3"></li>
                                </ul>
                            </div>
                        </div>
                    </div>
                </div>
            </section>
        `;
    };

    const buildFooterNavHTML = (currentId) => {
        const studioActive = currentId === STUDIO_HUB.id ? ' class="active"' : '';
        const studioLink = `<a href="${STUDIO_HUB.url}"${studioActive} data-series-href="${STUDIO_HUB.url}"><span class="nav-dot dot-studio"></span>${STUDIO_HUB.name}</a>`;
        const seriesLinks = SERIES.map((item, idx) => {
            const activeClass = item.id === currentId ? ' class="active"' : '';
            const sep = idx < SERIES.length - 1 ? '<span class="sep">|</span>' : '';
            return `<a href="${item.url}"${activeClass} data-series-href="${item.url}"><span class="nav-dot dot-${item.colorClass}"></span>${item.name} (${item.shortTag})</a>${sep}`;
        }).join('');

        return `
            <div class="footer-trilogy-nav" aria-label="StereoStudio Labs & Spatial Creative Studio Trilogy">
                <span class="trilogy-nav-label">StereoStudio Labs:</span>
                ${studioLink}
                <span class="sep">—</span>
                ${seriesLinks}
            </div>
        `;
    };

    const applySharedLanguage = (lang) => {
        const dict = SHARED_TRANSLATIONS[lang] || SHARED_TRANSLATIONS.ja;
        document.querySelectorAll('[data-shared-i18n]').forEach(el => {
            const key = el.getAttribute('data-shared-i18n');
            if (dict[key]) {
                el.innerHTML = dict[key];
            }
        });
        document.querySelectorAll('[data-series-href]').forEach(link => {
            const baseUrl = link.getAttribute('data-series-href');
            link.href = buildSeriesUrl(baseUrl, lang);
        });
    };

    let mounted = false;

    const mountAll = () => {
        if (mounted) return;
        const trilogyMount = document.getElementById('trilogy-mount');
        const heritageMount = document.getElementById('heritage-mount');
        const footerMount = document.getElementById('footer-trilogy-mount');

        if (!trilogyMount && !heritageMount && !footerMount) return;

        if (trilogyMount) {
            const current = trilogyMount.getAttribute('data-current') || 'panor';
            const version = trilogyMount.getAttribute('data-asset-version') || '1.0.0';
            trilogyMount.outerHTML = buildTrilogyHTML(current, version);
        }

        if (heritageMount) {
            const current = heritageMount.getAttribute('data-current') || 'panor';
            const version = heritageMount.getAttribute('data-asset-version') || '1.0.0';
            heritageMount.outerHTML = buildHeritageHTML(current, version);
        }

        if (footerMount) {
            const current = footerMount.getAttribute('data-current') || 'panor';
            footerMount.outerHTML = buildFooterNavHTML(current);
        }

        mounted = true;

        const initialLang = resolveInitialLang();
        applySharedLanguage(initialLang);

        // Watch <html lang="..."> updates from site-specific script.js
        const observer = new MutationObserver((mutations) => {
            for (const m of mutations) {
                if (m.type === 'attributes' && m.attributeName === 'lang') {
                    const nextLang = document.documentElement.lang === 'en' ? 'en' : 'ja';
                    applySharedLanguage(nextLang);
                }
            }
        });
        observer.observe(document.documentElement, { attributes: true, attributeFilter: ['lang'] });
    };

    mountAll();
    if (!mounted) {
        document.addEventListener('DOMContentLoaded', mountAll);
    }
})();
