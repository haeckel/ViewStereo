# ViewStereo Technical Specification (v0.1.8)

## 1. System Overview
**ViewStereo** is a native macOS 14.0+ (SwiftUI / AppKit) application designed for automated archival stereoview restoration, geometric rectification, stereo window optimization, and modern spatial media export. It builds upon `StereoStudioCore` and `StereoCore` (`stalign_src`) and leverages Apple Silicon Neural Engine (Core ML), Vision, and Accelerate (LAPACK).

---

## 2. Core Pipeline Architecture

### Stage 1: Input Ingestion & Pairing
- **Supported Inputs**:
  - Scanned stereoview cards (single image containing mount + L/R prints)
  - Side-by-Side (SBS) stereo images
  - Dual-file Left/Right image pairs (auto-paired in batch mode via filename suffix or consecutive ordering)
- **Supported Formats**: JPEG, PNG, HEIC, TIFF, WebP, MPO, etc. (via `ImageIO` / `NSImage`).

### Stage 2: Core ML Stereoview Card Segmentation (`StereoCardSegmenter`)
When `StereoCardMode` is `.cropInner` or `.keepArchBlack`:
1. **Primary Localization (`StereoCardSeg.mlmodelc`)**:
   - U-Net architecture operating at `512 × 256` input resolution.
   - Outputs left/right print probability masks, bounding boxes, arch-top curvature parameters (`ArchShapeParams`: `topRxRatio`, `topRyRatio`, `botRxRatio`, `botRyRatio`), card skew angle, and sampled mount RGB luminance.
2. **Mask Refinement (Selectable)**:
   - **SAM 2.1 Tiny** (`SAM2_1TinyImageEncoderFLOAT16.mlmodelc` + `PromptEncoder` + `MaskDecoder`)
   - **U-Net Only**: Skips transformer refinement for maximum throughput.
3. **Original Card Mount Context (`OriginalCardMountContext`)**:
   - Captures source mount color, skew angle, print masks, and arch geometry for downstream Digital Remounting and OCR text extraction.

### Stage 3: 7-DoF Symmetric Homography Alignment (`StereoCore`)
- **Feature Matching & Motion Masking**:
  - Extracts robust correspondences across left and right views.
  - Optional **Vision Person Motion Mask** suppresses dynamic human subjects during Cha-Cha handheld stereo alignment.
- **Symmetric 7-DoF Solver**:
  - Solves symmetric scale, roll, horizontal/vertical keystoning, and vertical translation using Apple Accelerate **LAPACK `dposv_`** combined with **IRLS (Iteratively Reweighted Least Squares)** to reject outliers.
  - Eliminates vertical disparity to sub-pixel precision.
- **MAAIR (Maximum Area Axis-aligned Inscribed Rectangle)**:
  - Computes the largest valid interior rectangle within the warped L/R intersection, preventing black corner artifacts. Supports `keepOriginalAspectRatio` lock.

### Stage 4: Stereo Window Optimization & Restoration
- **Automatic Window Placement**:
  - Analyzes foreground disparity bounds and optionally weights by **Apple Vision Attention Saliency** (`useAttentionSaliency`) to place the stereo window cleanly in front of or at the primary subject, preventing frame-edge window violations.
- **Real-Time Shift**:
  - Interactive `windowShiftX` (`-300.0 ... +300.0 px`) with live drag preview.
- **Color, Dust & Vintage Photo Restoration**:
  - `StereoAutoColorMode`: `.off`, `.left` (Match to Left), `.right` (Match to Right) histogram/exposure harmonization.
  - `removeUnilateralNoise`: Detects and attenuates single-view dust, scratches, and emulsion defects with instant non-destructive preview updates.
  - **Vintage Photo Restoration (`VintageRestorationOptions` / `StereoDetailRestorationOptions`)**: Non-destructive print tone presets (`Original`, `Albumen Sepia (1860s)`, `Warm Silver (1890s)`, `Pure Monochrome`), Auto-Level (B/W Point %), Local Contrast (CLAHE %), and a real-time **Compare Before** toggle.
  - **Core ML Optical Deblur (`NAFNetDeblur.mlmodelc`)**: Bundled on-device NAFNet-GoPro model for optical deblurring and edge sharpness recovery, paired with `Foliage / Texture Protection (%)` to prevent stereoscopic retinal rivalry.
  - **Core ML AI Colorization & Hand-Tint (`StereoColorizer.mlmodelc`)**: Bundled on-device colorization model supporting `1890s Hand-Tinted (Watercolor)`, `Natural Full Color (AI)`, and `Harmonize Existing Hand-Tint` with `Color Intensity (%)` and `Tint Warmth (%)` controls.

### Stage 5: Digital Remount & Letterpress OCR Engine
- **Era-Authentic Mount Presets (`StereoCardMountPreset`)**:
  - `originalRemount`, `autoSampleColor`, `keystoneDark` (1900s), `classicBuff` (1880s), `vividTerracotta` (1870s bicolor), `victorianGreen` (1870s bicolor), `chromeYellow` (1860s), `earlyIvory` (1850s).
- **Physical Geometry**:
  - 7-inch standard card dimensions: `Standard (7 × 3.5 in)`, `Cabinet (7 × 4.0 in)`, `Imperial (7 × 4.5 in)`.
  - Curved mount shading (post-1879 convex card simulation), rounded vs. square mount corners, print cut styles (`archTop`, `roundedCorners`, `square`), and center gap (`joined` vs. `separated` 3mm).
- **Vision OCR Typography**:
  - Asynchronous OCR extracts top-center catalog numbers, bottom captions, and rotated left/right margin publisher credits, re-typesetting them with `CoreText` letterpress styling.

### Stage 6: Display & Export
- **8 Real-Time Display Modes**: `StereoView`, `SBS`, `LR/RL`, `Dubois`, `Color Anaglyph`, `Gray Anaglyph`, `Polarized`, `2D`.
- **11 Export Layouts**: All 8 display layouts (JPEG/PNG) plus `Separate L/R`, `Spatial Photo (HEIC / MV-HEVC)` via `StereoStudioCore.SpatialPhotoExporter`, and `MPO (3D Camera)`.
- **Batch Engine**: Asynchronous folder processing with `Auto (L/R Pairs + SBS)`, `SBS Images Only`, and `Consecutive L/R Pairs` modes, plus per-item `.txt` adjustment reports.

---

## 3. UI & Design System Compliance
- **Framework**: SwiftUI + AppKit (`NSApp.appearance = NSAppearance(named: .darkAqua)`).
- **Layout**: Anti-Jitter fixed-width inspector (`400pt` standard / `450pt` in Large Text Mode 1.2x), 3-piece studio controls (Slider + ResetButton + NumericInput).
- **Theme Color**: Amber Gold (`Color.brightAmber` / `#F5A623`) alongside StereoStudioCore semantic colors.
