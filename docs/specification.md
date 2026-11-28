# ViewStereo Technical Specification (v0.2.8)

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

### Stage 2: Core ML Stereoview Card Segmentation (`StereoCardSegmenter` + `StereoCardMountAnalyzer`)
When `StereoCardMode` is `.cropInner` or `.keepArchBlack`:
1. **3-Stage Cascade Mount Analysis (`StereoCardMountAnalyzer`)**:
   - **Stage 0 (Scan Margin Removal & Deskewing)**: Uses 4-corner CIE Lab median/MAD outer-connected flood-fill to strip white/black scanner margins, RANSAC line fitting for card deskewing, and drop-shadow crossing (`refineShadowEdge`), guarded by 3-fold white-mount false-removal checks (separator penetration, mid-column split, aspect ratio).
   - **Stage 1 (Card-Specific CIE Lab Mount Color Barrier)**: Adaptive `step=1` outer rim sampling (`collectAdaptiveEdgeRim`) builds a covariance/Euclidean color gate supporting ultra-thin (5–10px) mount borders; generates an outer/center-connected `connectedBarrierMask` to protect dark photographic interiors (e.g., lunar/night skies) while guarding U-Net/SAM boundaries.
   - **Stage 2 (Coupled Parametric Twin-Window Fitting)**: SAT + Sobel gradient coordinate-descent optimization (`TwinWindowParams`) fits unified Left/Right print geometry (`.square` / `.rounded` / `.arch`).
2. **Primary Localization (`StereoCardSeg.mlmodelc`)**:
   - U-Net architecture operating at `512 × 256` input resolution via direct `CVPixelBufferCreate` rendering, masked by `connectedBarrierMask`.
   - Outputs left/right print probability masks, bounding boxes, arch-top curvature parameters (`ArchShapeParams`: `topRxRatio`, `topRyRatio`, `botRxRatio`, `botRyRatio`), card skew angle, and sampled mount RGB luminance.
3. **Mask Refinement (Selectable) & Guarded Trimming**:
   - **SAM 2.1 Tiny** (`SAM2_1TinyImageEncoderFLOAT16.mlmodelc` + `PromptEncoder` + `MaskDecoder`) with dark-background mask tolerance/candidate safeguards, or **U-Net Only** for maximum throughput.
   - Top-edge mount barrier hard-stops, bottom caption trimmer dark-rule streak guards, and arch apex synchronization.
4. **Original Card Mount Context (`OriginalCardMountContext`)**:
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

### Stage 7: Video 2D-to-3D Conversion & Spatial Video Pipeline
- **Inputs**: `.mp4`, `.mov`, `.m4v` 2D video files with AVFoundation `preferredTransform` auto-upright and SDR Rec.709 tone mapping.
- **Stateful Video Depth Inference (`ViewStereoVideoDepthSession`)**:
  - Leverages Apple Depth Pro 2 Core ML `MLState` (macOS 15+) for temporal consistency and flicker elimination.
  - Scene cut detection via 64×36 luminance MAD, 16-bin histogram, blackout recovery, and cooldown.
  - Temporal EMA smoothing for depth range percentiles and zero-parallax window focal plane.
- **Metal GPU DIBR Synthesis (`ViewStereoMetalDIBR`)**:
  - High-performance Metal compute shader zero-copy warping with unified boundary interpolation.
- **Video Formats**:
  - Apple Vision Pro Spatial Video (`MV-HEVC .mov` with stereoscopic metadata).
  - Side-by-Side 3D Video (Full SBS / Half SBS `.mp4`).
  - Dubois Anaglyph 3D Video (`.mp4`).
  - Container-safe audio pass-through and AAC 256kbps 48kHz re-encoding.
  - Pre-export destination disk free space validation.

### Stage 8: Memory Lifecycle & Hardened Symmetrical Localization
- **Buffer Lifecycle Management**:
  - Proactive cache clearance routines (`clearDepthSynthesisCache`, `clearStaticImageBuffers`) invoked across document transitions and reset actions to prevent memory leaks during long-running sessions.
- **Segmentation Bounds Safety**:
  - Strict lower-upper bound verification (`guard minX < maxX, minY < maxY`) on corner and border sampling scans preventing fatal runtime exceptions.
- **Symmetrical Localization**:
  - 100% parity across English and Japanese resource strings (493 keys) with unified programmatic keys (`String(localized: ...)`).

---

## 3. UI & Design System Compliance
- **Framework**: SwiftUI + AppKit (`NSApp.appearance = NSAppearance(named: .darkAqua)`).
- **Layout**: Anti-Jitter fixed-width inspector (`400pt` standard / `450pt` in Large Text Mode 1.2x), 3-piece studio controls (Slider + ResetButton + NumericInput).
- **Theme Color**: Amber Gold (`Color.brightAmber` / `#F5A623`) alongside StereoStudioCore semantic colors.
