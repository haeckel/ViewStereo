# Third-Party Notices & Acknowledgments

ViewStereo incorporates and builds upon the following open-source libraries, AI models, and Apple system frameworks. We express our sincere gratitude to their authors and contributors.

---

## 1. StereoCore (`stalign_src`)
- **Role**: Core stereoscopic alignment, 7-DoF symmetric homography solver, MAAIR (Maximum Area Axis-aligned Inscribed Rectangle) cropping, and color harmonization.
- **Technology**: Utilizes Apple Accelerate / LAPACK (`dposv_`) with Iteratively Reweighted Least Squares (IRLS) for sub-pixel vertical disparity elimination and keystone rectification.

## 2. StereoStudioCore
- **Role**: Shared foundational Swift package for the Stereo Creative Studio series (`SplatStereo`, `DepthStereo`, `PanorStereo`, `ViewStereo`), providing Dark-First studio UI components, Spatial Photo (MV-HEVC) export, ergonomic calculations, and About/Help views.

## 3. MobileSAM (Faster Segment Anything)
- **Authors**: Chaoning Zhang, Dongshen Han, Yu Qiao, Jung Uk Kim, Sung-Ho Bae, Seungkyu Lee, Choong Seon Hong
- **Role**: Lightweight ViT-based mask refiner (`MobileSAMEncoder` / `MobileSAMDecoder` Core ML models) used for precise segmentation of stereoview card print boundaries and arch-top frames.
- **License**: Apache License 2.0
- **Repository**: [https://github.com/ChaoningZhang/MobileSAM](https://github.com/ChaoningZhang/MobileSAM)

## 4. SAM 2.1 (Segment Anything Model 2.1 Tiny)
- **Authors**: Meta AI (FAIR)
- **Role**: High-precision mask refiner (`SAM2_1TinyImageEncoderFLOAT16`, `SAM2_1TinyPromptEncoderFLOAT16`, `SAM2_1TinyMaskDecoderFLOAT16` Core ML models) for complex or deteriorated historical stereoview borders.
- **License**: Apache License 2.0
- **Repository**: [https://github.com/facebookresearch/sam2](https://github.com/facebookresearch/sam2)

## 5. StereoCardSeg (U-Net Card Segmentation Model)
- **Role**: Custom-trained Core ML U-Net segmentation model (`StereoCardSeg.mlmodelc`) for rapid initial localization of left/right stereo print regions, card mount luminance, and arch-top geometry.

## 6. Apple Frameworks
- **Core ML & Apple Neural Engine**: Hardware-accelerated on-device inference for card segmentation and mask refinement.
- **Vision Framework**: Optical Character Recognition (OCR) for historical mount typography extraction, attention-based saliency detection for stereo window placement, and person segmentation for Cha-Cha motion masking.
- **Accelerate (LAPACK / vImage)**: High-precision linear algebra (`dposv_`) and image processing.
- **ImageIO & AVFoundation**: Native MV-HEVC Spatial Photo encoding and MPO multi-picture stereo container generation.
- **SwiftUI & AppKit**: Native macOS Dark-First studio interface.
