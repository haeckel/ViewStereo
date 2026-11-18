# ViewStereo 🎞️✨

[![Version](https://img.shields.io/badge/version-0.1.0-brightgreen.svg)](https://viewstereo.p-media.jp/)
[![Status](https://img.shields.io/badge/status-Early%20Development-amber.svg)](#development-status)
[![Platform](https://img.shields.io/badge/platform-macOS%2014.0+-lightgrey.svg)](https://apple.co/macos)
[![Technology](https://img.shields.io/badge/tech-Card%20Segmentation%20%7C%207--DoF%20Homography%20%7C%20Stereo%20Window%20%7C%20Digital%20Remount-orange.svg)](https://viewstereo.p-media.jp/)

**ViewStereo** is a professional macOS studio application for automatically detecting, geometrically rectifying, and restoring 19th-century historical stereoview cards (stereographs / stereo cards) and modern stereo photographs into pristine digital 3D media—including Apple Vision Pro Spatial Photos (MV-HEVC), Side-by-Side (SBS), Anaglyph, MPO, and digitally remounted archival stereoview cards.

> [!WARNING]
> **Early Development Status & User Participation / 開発初期段階のお知らせ**
> **ViewStereo** is currently under **active development** and in an **early stage of development** (現在開発中・特に開発初期段階). Users who download and use this application are participating in **improving the app's specifications and debugging** (アプリの仕様向上およびデバッグ作業へのご協力). Please expect potential instability, unexpected bugs, and breaking changes to features or UI as development evolves.

Designed as the archival restoration and geometric alignment companion to **SplatStereo**, **DepthStereo**, and **PanorStereo** in the **Stereo Creative Studio** family, **ViewStereo** combines Core ML segmentation (`StereoCardSeg` + `MobileSAM` / `SAM 2.1 Tiny`), 7-DoF symmetric homography optimization, intelligent stereo window placement, and historical digital remounting in a native Dark-First macOS workflow.

---

## 🚀 Key Features

### 🧩 Core ML Stereoview Card Segmentation
- **Automatic Card & Arch-Top Detection**: Drop scanned 19th-century stereoview cards directly onto the canvas. `StereoCardSeg` (U-Net) paired with selectable **MobileSAM** or **SAM 2.1 Tiny** refinement accurately isolates left/right photographic prints and authentic arch-top frames.
- **Flexible Extraction Modes**: Choose between **Crop Inner** (clean rectangular extraction), **Keep Arch (Black)** (preserving original arched borders), or **Off** (for modern L/R pairs and SBS images).

### 📐 7-DoF Symmetric Homography & MAAIR Crop
- **Zero Vertical Disparity**: Powered by `StereoCore` and Apple Accelerate LAPACK (`dposv_` + IRLS robust optimization), ViewStereo resolves hand-mounted print rotation, scale differences, horizontal/vertical keystoning, and vertical disparity down to sub-pixel precision.
- **Vision Person Motion Mask**: Optional Cha-Cha stereo support that masks moving human subjects during alignment.
- **MAAIR (Maximum Area Axis-aligned Inscribed Rectangle)**: Automatically computes and crops to the largest valid common rectangle with zero black borders, with an optional aspect-ratio lock.

### 🪟 Intelligent Stereo Window & Saliency Alignment
- **Window Violation Prevention**: Automatically calculates optimal horizontal stereo window shift based on the nearest foreground subject—with optional **Vision Attention Saliency** prioritization—to eliminate retinal rivalry and uncomfortable frame-edge violations.
- **Real-Time Fine-Tuning**: Precision 3-piece studio controls (slider, reset, numeric input) for manual stereo window calibration.

### 🏛️ Digital Remount & Letterpress OCR Typography
- **8 Era-Authentic Mount Presets**: Reconstruct damaged or cropped stereoviews onto historically accurate mounts: *Original Mount (Remount)*, *Auto Sample Source Color*, *1900s Keystone Dark*, *1880s Classic Buff*, *1870s Cabinet Terracotta*, *1870s Victorian Green*, *1860s Chrome Yellow*, and *1850s Early Ivory*.
- **Authentic Physical Details**: Supports 7-inch standard card specs (*Standard 7×3.5 in*, *Cabinet 7×4.0 in*, *Imperial 7×4.5 in*), curved mount shading, 1870s bicolor edges, print cut styles (*Arched Top*, *Rounded Corners*, *Square*), and center division styles.
- **Vision OCR Letterpress**: Automatically reads titles, catalog numbers, and vertical side-margin publisher imprints from original cards and re-typesets them onto the remounted card.

### 🎨 Vintage Restoration & Multi-Format Export
- **Color Harmonization & Dust Removal**: Automatic Left/Right exposure and color matching (`Match to Left` / `Match to Right`) plus unilateral dust and scratch suppression.
- **8 Real-Time Display Modes**: `2D`, `SBS`, `LR/RL`, `Dubois`, `Color Anaglyph`, `Gray Anaglyph`, `Polarized`, and `Stereoview Card`.
- **11 Export Layouts**: Export to `Spatial Photo (HEIC / MV-HEVC)`, `MPO (3D Camera)`, `Separate L/R`, `Stereoview Card`, `SBS`, `LR/RL (4-Way)`, `Dubois`, `Color Anaglyph`, `Gray Anaglyph`, `Polarized`, and `2D` (JPEG/PNG).
- **Batch Folder Processing**: Process entire archives of stereoview cards or L/R pairs automatically (`Auto`, `SBS Only`, `Consecutive L/R Pairs`) with optional adjustment reports (`.txt`).

---

## 🛠️ Architecture

```mermaid
flowchart LR
    A["Stereoview Card / L+R / SBS"] --> B["Stage 1: Core ML Segmentation<br/>StereoCardSeg + MobileSAM / SAM 2.1 Tiny"]
    B --> C["Stage 2: 7-DoF Homography<br/>StereoCore + LAPACK dposv_ + IRLS"]
    C --> D["Stage 3: Window & Restoration<br/>Foreground / Saliency + MAAIR + Color Match"]
    D --> E1["Interactive Preview<br/>8 Stereo Modes & Live Shift"]
    D --> E2["Digital Remount Engine<br/>Era Presets + Vision OCR Letterpress"]
    D --> E3["Multi-Format & Batch Export<br/>MV-HEVC Spatial Photo / SBS / MPO / Card"]
```

---

## 📦 System Requirements

- **Operating System**: macOS 14.0 (Sonoma) or macOS 15.0+ (Sequoia)
- **Hardware**: Apple Silicon Mac (M1 / M2 / M3 / M4, Pro / Max / Ultra) recommended
- **Memory**: 8 GB RAM minimum (16 GB+ recommended for high-resolution 4K–8K archival scans and batch processing)

---

## 🚀 Getting Started

1. **Launch ViewStereo**: Open `ViewStereo.app`.
2. **Import**: Drag and drop a scanned stereoview card, a pair of Left/Right images, a Side-by-Side (SBS) image, or an entire folder for batch processing.
3. **Auto Align & Window**: ViewStereo automatically segments the card, rectifies 7-DoF geometry, matches colors, and sets an optimal stereo window.
4. **Fine-Tune or Remount**: Adjust the Stereo Window shift if desired, or switch to **Card** view (`⌘8`) to customize Digital Remount presets and OCR typography.
5. **Export**: Export directly to Apple Vision Pro **Spatial Photo (HEIC)**, **SBS**, **Anaglyph**, **MPO**, or a restored **Stereoview Card** (`⌘E`).

---

## 📖 Documentation & Support

- [**Official Website**](https://viewstereo.p-media.jp/)
- [**Online Documentation (日本語)**](https://viewstereo.p-media.jp/docs.html)
- [**Online Documentation (English)**](https://viewstereo.p-media.jp/docs_en.html)
- [**User Manual (Markdown - 日本語)**](docs/manual_ja.md)
- [**Technical Specification**](docs/specification.md)
- [**Third-Party Notices**](THIRD_PARTY_NOTICES.md)

---

## 🎨 Stereo Creative Studio Series

ViewStereo shares the Dark-First studio design DNA and `StereoStudioCore` architecture with the Stereo Creative Studio Trilogy:

| Studio | Theme Color | Focus & Pipeline | Official Website |
| :--- | :--- | :--- | :--- |
| **SplatStereo** | 🔴 Red | 3D Gaussian Splatting & Free-viewpoint Synthesis | [https://splatstereo.p-media.jp/](https://splatstereo.p-media.jp/) |
| **DepthStereo** | 🟢 Green | 2.5D Monocular AI Metric Depth & Spatial Video | [https://depthstereo.p-media.jp/](https://depthstereo.p-media.jp/) |
| **PanorStereo** | ⚪️ White | 360° Equirectangular Panoramic AI Depth & ODS Stereo | [https://panorstereo.p-media.jp/](https://panorstereo.p-media.jp/) |
| **ViewStereo** | 🟠 Amber Gold | 19th-Century Stereoview Restoration, 7-DoF Alignment & Remount | [https://viewstereo.p-media.jp/](https://viewstereo.p-media.jp/) |

---

## 🤝 License

© 2026 ViewStereo Project. All rights reserved.
Inspired by 19th-century stereoview craftsmanship and modern computational stereoscopy.
