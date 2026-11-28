import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Metal
import MetalPerformanceShaders

/// ワープ前の元ステレオカード画像エッジに追従させて低解像度セグメンテーションマスクを高解像度仕上げする GPU パイプライン
/// 1. バイリニア拡大
/// 2. MPSImageGuidedFilter（元画像エッジへの輪郭吸着 + 境界バンド急峻化）
/// 3. CIMorphologyMinimum（1〜2px 均一収縮で裁断縁の暗線・糊フチ除去）
/// 4. CIGaussianBlur（0.5〜0.8px の薄いアンチエイリアス）
final class StereoCardMaskRefiner: @unchecked Sendable {
    static let shared = StereoCardMaskRefiner()

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let ciContext: CIContext
    private let grayColorSpace = CGColorSpaceCreateDeviceGray()
    private let ciRenderLock = NSLock()

    private init() {
        if let dev = MTLCreateSystemDefaultDevice(),
           let queue = dev.makeCommandQueue() {
            self.device = dev
            self.commandQueue = queue
            self.ciContext = CIContext(mtlDevice: dev, options: [.cacheIntermediates: false])
        } else {
            self.device = nil
            self.commandQueue = nil
            self.ciContext = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true])
        }
    }

    /// 低解像度確率マップ (0...1) を元画像 RGB (width × height × 3) のエッジへ追従させ、
    /// 均一収縮 + 薄いアンチエイリアスを施した 8bit グレースケールマスク (0...255) を返す。
    func refineMask(
        probMask: [Float],
        maskWidth mw: Int,
        maskHeight mh: Int,
        guideRGB: [UInt8],
        width w: Int,
        height h: Int,
        erosionRadiusPx: Float? = nil,
        aaBlurRadiusPx: Float = 0.65
    ) -> [UInt8] {
        let pixelCount = w * h
        guard w >= 16, h >= 16, mw >= 8, mh >= 8,
              probMask.count >= mw * mh,
              guideRGB.count >= pixelCount * 3 else {
            return [UInt8](repeating: 255, count: max(0, pixelCount))
        }

        // Step 1: 低解像度確率マップを元解像度 (w × h) へバイリニア拡大
        let upsampled = upsampleBilinearFloat(probMask, sw: mw, sh: mh, dw: w, dh: h)

        // Step 2: MPSImageGuidedFilter による穏やかなエッジ追従 + 境界バンド安全クランプ・急峻化
        // 紙目・岩肌ノイズで輪郭がノコギリ状に波打つ現象を防ぐため kernelDiameter=9, epsilon=2.0e-2 とする
        let kernelDiameter = 9
        var guidedU8: [UInt8]? = nil
        if let dev = device, let queue = commandQueue {
            guidedU8 = runMPSGuidedFilter(
                device: dev,
                queue: queue,
                upsampledProb: upsampled,
                guideRGB: guideRGB,
                width: w,
                height: h,
                kernelDiameter: kernelDiameter,
                epsilon: 2.0e-2
            )
        }
        let sharpU8: [UInt8]
        if let guided = guidedU8 {
            sharpU8 = guided
        } else {
            NSLog("[MaskRefiner] MPSImageGuidedFilter unavailable/failed; falling back to CPU sharpening (w=%d h=%d)", w, h)
            sharpU8 = sharpenCPUFallback(upsampled: upsampled)
        }

        // Step 3 & 4: CIMorphologyMinimum (1〜2px 均一収縮) + CIGaussianBlur (0.5〜0.8px AA)
        let autoErode = min(2.2, max(1.0, Float(w) * 0.0008))
        let erodePx = erosionRadiusPx ?? autoErode
        let blurPx = min(0.85, max(0.45, aaBlurRadiusPx))

        if let postCI = applyMorphologyAndAAWithCoreImage(
            maskU8: sharpU8,
            width: w,
            height: h,
            erodeRadius: erodePx,
            aaBlurRadius: blurPx
        ) {
            return postCI
        }

        NSLog("[MaskRefiner] CoreImage post-processing failed; using CPU morphology + AA fallback")
        return applyMorphologyAndAACPUFallback(maskU8: sharpU8, width: w, height: h, erodeRadius: erodePx)
    }

    // MARK: - Step 1: バイリニア拡大

    private func upsampleBilinearFloat(_ src: [Float], sw: Int, sh: Int, dw: Int, dh: Int) -> [Float] {
        if sw == dw && sh == dh { return Array(src.prefix(dw * dh)) }
        var dst = [Float](repeating: 0, count: dw * dh)
        let scaleX = Float(sw) / Float(dw)
        let scaleY = Float(sh) / Float(dh)
        let maxSX = sw - 1
        let maxSY = sh - 1

        src.withUnsafeBufferPointer { sPtr in
            dst.withUnsafeMutableBufferPointer { dPtr in
                guard let s = sPtr.baseAddress, let d = dPtr.baseAddress else { return }
                DispatchQueue.concurrentPerform(iterations: dh) { y in
                    let sy = max(0, min(Float(maxSY), (Float(y) + 0.5) * scaleY - 0.5))
                    let y0 = Int(sy)
                    let y1 = min(maxSY, y0 + 1)
                    let fy = sy - Float(y0)
                    let r0 = y0 * sw
                    let r1 = y1 * sw
                    let dRow = y * dw

                    for x in 0..<dw {
                        let sx = max(0, min(Float(maxSX), (Float(x) + 0.5) * scaleX - 0.5))
                        let x0 = Int(sx)
                        let x1 = min(maxSX, x0 + 1)
                        let fx = sx - Float(x0)

                        let v00 = s[r0 + x0]
                        let v10 = s[r0 + x1]
                        let v01 = s[r1 + x0]
                        let v11 = s[r1 + x1]
                        let top = v00 + (v10 - v00) * fx
                        let bot = v01 + (v11 - v01) * fx
                        d[dRow + x] = top + (bot - top) * fy
                    }
                }
            }
        }
        return dst
    }

    // MARK: - Step 2: MPSImageGuidedFilter

    private func runMPSGuidedFilter(
        device: MTLDevice,
        queue: MTLCommandQueue,
        upsampledProb: [Float],
        guideRGB: [UInt8],
        width w: Int,
        height h: Int,
        kernelDiameter: Int,
        epsilon: Float
    ) -> [UInt8]? {
        let pixelCount = w * h

        // Guidance: rgba8Unorm
        let guideDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: w,
            height: h,
            mipmapped: false
        )
        guideDesc.usage = [.shaderRead]
        guideDesc.storageMode = .shared

        // Source & Destination & Weights: r16Float (1ch)
        let f16Desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float,
            width: w,
            height: h,
            mipmapped: false
        )
        f16Desc.usage = [.shaderRead, .shaderWrite]
        f16Desc.storageMode = .shared

        // Coefficients: rgba16Float (4ch for 3ch guidance + 1 offset)
        let coeffDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: w,
            height: h,
            mipmapped: false
        )
        coeffDesc.usage = [.shaderRead, .shaderWrite]
        coeffDesc.storageMode = .private

        guard let guideTex = device.makeTexture(descriptor: guideDesc),
              let srcTex = device.makeTexture(descriptor: f16Desc),
              let weightsTex = device.makeTexture(descriptor: f16Desc),
              let coeffTex = device.makeTexture(descriptor: coeffDesc),
              let dstTex = device.makeTexture(descriptor: f16Desc) else {
            return nil
        }

        // Pack guideRGB -> RGBA8
        var rgbaGuide = [UInt8](repeating: 255, count: pixelCount * 4)
        guideRGB.withUnsafeBufferPointer { sPtr in
            rgbaGuide.withUnsafeMutableBufferPointer { dPtr in
                guard let s = sPtr.baseAddress, let d = dPtr.baseAddress else { return }
                for i in 0..<pixelCount {
                    let si = i * 3
                    let di = i * 4
                    d[di] = s[si]
                    d[di + 1] = s[si + 1]
                    d[di + 2] = s[si + 2]
                }
            }
        }
        rgbaGuide.withUnsafeBytes { buf in
            guideTex.replace(
                region: MTLRegionMake2D(0, 0, w, h),
                mipmapLevel: 0,
                withBytes: buf.baseAddress!,
                bytesPerRow: w * 4
            )
        }

        // Pack upsampledProb -> Float16, weights -> 1.0 (Float16)
        var srcF16 = [Float16](repeating: 0, count: pixelCount)
        upsampledProb.withUnsafeBufferPointer { sPtr in
            srcF16.withUnsafeMutableBufferPointer { dPtr in
                guard let s = sPtr.baseAddress, let d = dPtr.baseAddress else { return }
                for i in 0..<pixelCount {
                    d[i] = Float16(s[i])
                }
            }
        }
        srcF16.withUnsafeBytes { buf in
            srcTex.replace(
                region: MTLRegionMake2D(0, 0, w, h),
                mipmapLevel: 0,
                withBytes: buf.baseAddress!,
                bytesPerRow: w * MemoryLayout<Float16>.stride
            )
        }

        let oneF16 = [Float16](repeating: Float16(1.0), count: pixelCount)
        oneF16.withUnsafeBytes { buf in
            weightsTex.replace(
                region: MTLRegionMake2D(0, 0, w, h),
                mipmapLevel: 0,
                withBytes: buf.baseAddress!,
                bytesPerRow: w * MemoryLayout<Float16>.stride
            )
        }

        let guidedFilter = MPSImageGuidedFilter(device: device, kernelDiameter: kernelDiameter)
        guidedFilter.epsilon = epsilon
        guidedFilter.reconstructScale = 1.0
        guidedFilter.reconstructOffset = 0.0

        guard let cmdBuf = queue.makeCommandBuffer() else { return nil }
        guidedFilter.encodeRegression(
            to: cmdBuf,
            sourceTexture: srcTex,
            guidanceTexture: guideTex,
            weightsTexture: weightsTex,
            destinationCoefficientsTexture: coeffTex
        )
        guidedFilter.encodeReconstruction(
            to: cmdBuf,
            guidanceTexture: guideTex,
            coefficientsTexture: coeffTex,
            destinationTexture: dstTex
        )
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        if let err = cmdBuf.error {
            NSLog("[MaskRefiner] MPSImageGuidedFilter Metal error: %@", err.localizedDescription)
            return nil
        }

        var dstF16 = [Float16](repeating: 0, count: pixelCount)
        dstF16.withUnsafeMutableBytes { buf in
            dstTex.getBytes(
                buf.baseAddress!,
                bytesPerRow: w * MemoryLayout<Float16>.stride,
                from: MTLRegionMake2D(0, 0, w, h),
                mipmapLevel: 0
            )
        }

        // 境界バンド安全クランプ（輪郭 ±3px の微調整に限定して直線辺・滑らかなアーチ曲線の波打ちを防止）
        var outU8 = [UInt8](repeating: 0, count: pixelCount)
        let band = 3
        upsampledProb.withUnsafeBufferPointer { uPtr in
            dstF16.withUnsafeBufferPointer { gPtr in
                outU8.withUnsafeMutableBufferPointer { oPtr in
                    guard let uBase = uPtr.baseAddress, let gBase = gPtr.baseAddress, let oBase = oPtr.baseAddress else { return }
                    DispatchQueue.concurrentPerform(iterations: h) { y in
                        let yTop = max(0, y - band)
                        let yBot = min(h - 1, y + band)
                        let row = y * w
                        for x in 0..<w {
                            let idx = row + x
                            let rawP = uBase[idx]
                            var v = Float(gBase[idx])
                            if !v.isFinite { v = rawP }

                            // 境界近傍以外では安全クランプを優先して内部穴あき・外周誤点灯を防止
                            if rawP >= 0.985 || rawP <= 0.015 {
                                let xL = max(0, x - band)
                                let xR = min(w - 1, x + band)
                                let pT = uBase[yTop * w + x]
                                let pB = uBase[yBot * w + x]
                                let pL = uBase[row + xL]
                                let pR = uBase[row + xR]
                                let nearEdge: Bool
                                if rawP >= 0.985 {
                                    nearEdge = (pT < 0.95 || pB < 0.95 || pL < 0.95 || pR < 0.95)
                                } else {
                                    nearEdge = (pT > 0.05 || pB > 0.05 || pL > 0.05 || pR > 0.05)
                                }
                                if !nearEdge {
                                    v = rawP
                                }
                            }

                            // しきい値 0.5 付近でソフト急峻化 ([0.38, 0.62] -> smoothstep)
                            let t = max(0.0, min(1.0, (v - 0.38) / 0.24))
                            let sharp = t * t * (3.0 - 2.0 * t)
                            oBase[idx] = UInt8(max(0, min(255, Int((sharp * 255.0).rounded()))))
                        }
                    }
                }
            }
        }
        return outU8
    }

    private func sharpenCPUFallback(upsampled: [Float]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: upsampled.count)
        for i in 0..<upsampled.count {
            let v = upsampled[i].isFinite ? upsampled[i] : 0.0
            let t = max(0.0, min(1.0, (v - 0.38) / 0.24))
            let sharp = t * t * (3.0 - 2.0 * t)
            out[i] = UInt8(max(0, min(255, Int((sharp * 255.0).rounded()))))
        }
        return out
    }

    // MARK: - Step 3 & 4: Core Image (CIMorphologyMinimum + CIGaussianBlur)

    private func applyMorphologyAndAAWithCoreImage(
        maskU8: [UInt8],
        width w: Int,
        height h: Int,
        erodeRadius: Float,
        aaBlurRadius: Float
    ) -> [UInt8]? {
        guard maskU8.count >= w * h else { return nil }
        let extent = CGRect(x: 0, y: 0, width: w, height: h)
        let data = Data(maskU8.prefix(w * h))

        // bitmapData 入力 & toBitmap 出力はともに先頭バイトが最上行 (top-down) のため上下反転が一切起きない
        var ciImg = CIImage(
            bitmapData: data,
            bytesPerRow: w,
            size: CGSize(width: w, height: h),
            format: .L8,
            colorSpace: grayColorSpace
        )

        if erodeRadius >= 0.5 {
            let clamped = ciImg.clampedToExtent()
            let morph = CIFilter.morphologyMinimum()
            morph.inputImage = clamped
            morph.radius = erodeRadius
            if let eroded = morph.outputImage?.cropped(to: extent) {
                ciImg = eroded
            }
        }

        if aaBlurRadius >= 0.2 {
            let clamped = ciImg.clampedToExtent()
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = clamped
            blur.radius = aaBlurRadius
            if let blurred = blur.outputImage?.cropped(to: extent) {
                ciImg = blurred
            }
        }

        var outU8 = [UInt8](repeating: 0, count: w * h)
        ciRenderLock.lock()
        outU8.withUnsafeMutableBytes { rawBuf in
            guard let ptr = rawBuf.baseAddress else { return }
            ciContext.render(
                ciImg,
                toBitmap: ptr,
                rowBytes: w,
                bounds: extent,
                format: .L8,
                colorSpace: grayColorSpace
            )
        }
        ciRenderLock.unlock()

        if maskU8.prefix(w * h).contains(where: { $0 >= 128 }),
           outU8.allSatisfy({ $0 == 0 }) {
            NSLog("[MaskRefiner] CoreImage rendered all-zero mask despite active input; falling back to CPU")
            return nil
        }
        return outU8
    }

    private func applyMorphologyAndAACPUFallback(
        maskU8: [UInt8],
        width w: Int,
        height h: Int,
        erodeRadius: Float
    ) -> [UInt8] {
        let r = max(1, Int(erodeRadius.rounded()))
        var eroded = [UInt8](repeating: 0, count: w * h)
        DispatchQueue.concurrentPerform(iterations: h) { y in
            let y0 = max(0, y - r), y1 = min(h - 1, y + r)
            let row = y * w
            for x in 0..<w {
                let x0 = max(0, x - r), x1 = min(w - 1, x + r)
                var minVal: UInt8 = 255
                for yy in y0...y1 {
                    let off = yy * w
                    for xx in x0...x1 {
                        let v = maskU8[off + xx]
                        if v < minVal { minVal = v }
                    }
                }
                eroded[row + x] = minVal
            }
        }

        var blurred = [UInt8](repeating: 0, count: w * h)
        DispatchQueue.concurrentPerform(iterations: h) { y in
            let ym = max(0, y - 1), yp = min(h - 1, y + 1)
            let row = y * w
            for x in 0..<w {
                let xm = max(0, x - 1), xp = min(w - 1, x + 1)
                let sum = Int(eroded[ym * w + xm]) + Int(eroded[ym * w + x]) * 2 + Int(eroded[ym * w + xp])
                    + Int(eroded[row + xm]) * 2 + Int(eroded[row + x]) * 4 + Int(eroded[row + xp]) * 2
                    + Int(eroded[yp * w + xm]) + Int(eroded[yp * w + x]) * 2 + Int(eroded[yp * w + xp])
                blurred[row + x] = UInt8((sum + 8) >> 4)
            }
        }
        return blurred
    }
}
