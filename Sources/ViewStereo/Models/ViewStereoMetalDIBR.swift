import Foundation
import Metal

/// Metal GPU を用いた高速 1パス DIBR（Depth-Image-Based Rendering）エンジン。
/// エッジ保護・背景優先のオクルージョン補間を行い、4K/HD 動画でも高速かつ時間的チラつきの少ない左右ステレオペアを生成する。
public final class ViewStereoMetalDIBR: @unchecked Sendable {
    public static let shared = ViewStereoMetalDIBR()

    private struct DIBRUniforms {
        var width: Int32
        var height: Int32
        var depthW: Int32
        var depthH: Int32
        var halfBaseline: Float
        var focusVal: Float
        var depthGamma: Float
        var depthContrast: Float
    }

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let pipelineState: MTLComputePipelineState?

    public var isAvailable: Bool {
        pipelineState != nil && commandQueue != nil
    }

    private init() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue() else {
            self.device = nil
            self.commandQueue = nil
            self.pipelineState = nil
            return
        }

        self.device = dev
        self.commandQueue = queue

        do {
            let library = try dev.makeLibrary(source: Self.metalSource, options: nil)
            if let fn = library.makeFunction(name: "dibr_warp_lr") {
                self.pipelineState = try dev.makeComputePipelineState(function: fn)
            } else {
                self.pipelineState = nil
            }
        } catch {
            self.pipelineState = nil
        }
    }

    /// 単眼 RGB バッファと正規化視差マップから、Metal GPU で左右ステレオペアを合成する。
    /// Metal が利用できない場合やバッファ生成に失敗した場合は nil を返す（呼び出し元で CPU フォールバック）。
    public func synthesizeStereoPair(
        baseRGB: [UInt8],
        width: Int,
        height: Int,
        disparityMap: [Float],
        depthW: Int,
        depthH: Int,
        targetDisparityPercent: Double,
        depthGamma: Double,
        depthContrast: Double,
        focusRatio: Double
    ) -> (leftRGB: [UInt8], rightRGB: [UInt8])? {
        guard let device, let commandQueue, let pipelineState else { return nil }
        let pixelCount = width * height
        let rgbByteCount = pixelCount * 3
        let depthCount = depthW * depthH
        guard pixelCount > 0,
              baseRGB.count >= rgbByteCount,
              depthW > 0, depthH > 0,
              disparityMap.count >= depthCount else {
            return nil
        }

        let maxBaselinePx = Float(width) * Float(max(0.2, min(8.0, targetDisparityPercent)) / 100.0)
        var uniforms = DIBRUniforms(
            width: Int32(width),
            height: Int32(height),
            depthW: Int32(depthW),
            depthH: Int32(depthH),
            halfBaseline: maxBaselinePx * 0.5,
            focusVal: Float(max(0.0, min(1.0, focusRatio))),
            depthGamma: Float(depthGamma),
            depthContrast: Float(depthContrast)
        )

        guard let inRGBBuf = baseRGB.withUnsafeBytes({ ptr in
            device.makeBuffer(bytes: ptr.baseAddress!, length: rgbByteCount, options: .storageModeShared)
        }),
        let dispBuf = disparityMap.withUnsafeBytes({ ptr in
            device.makeBuffer(bytes: ptr.baseAddress!, length: depthCount * MemoryLayout<Float>.size, options: .storageModeShared)
        }),
        let outLeftBuf = device.makeBuffer(length: rgbByteCount, options: .storageModeShared),
        let outRightBuf = device.makeBuffer(length: rgbByteCount, options: .storageModeShared),
        let commandBuffer = commandQueue.makeCommandBuffer(),
        let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        encoder.setComputePipelineState(pipelineState)
        encoder.setBuffer(inRGBBuf, offset: 0, index: 0)
        encoder.setBuffer(dispBuf, offset: 0, index: 1)
        encoder.setBuffer(outLeftBuf, offset: 0, index: 2)
        encoder.setBuffer(outRightBuf, offset: 0, index: 3)
        encoder.setBytes(&uniforms, length: MemoryLayout<DIBRUniforms>.size, index: 4)

        let w = min(16, pipelineState.threadExecutionWidth)
        let h = max(1, min(16, pipelineState.maxTotalThreadsPerThreadgroup / max(1, w)))
        let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
        let threadsPerGrid = MTLSize(width: width, height: height, depth: 1)
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if commandBuffer.status != .completed {
            return nil
        }

        var leftRGB = [UInt8](repeating: 0, count: rgbByteCount)
        var rightRGB = [UInt8](repeating: 0, count: rgbByteCount)
        leftRGB.withUnsafeMutableBytes { dst in
            memcpy(dst.baseAddress!, outLeftBuf.contents(), rgbByteCount)
        }
        rightRGB.withUnsafeMutableBytes { dst in
            memcpy(dst.baseAddress!, outRightBuf.contents(), rgbByteCount)
        }
        return (leftRGB, rightRGB)
    }

    private static let metalSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct DIBRUniforms {
        int width;
        int height;
        int depthW;
        int depthH;
        float halfBaseline;
        float focusVal;
        float depthGamma;
        float depthContrast;
    };

    inline float sampleDisparity(
        device const float* disparityMap,
        int depthW,
        int depthH,
        float u,
        float v,
        float depthGamma,
        float depthContrast
    ) {
        float gx = clamp(u, 0.0f, 1.0f) * float(max(0, depthW - 1));
        float gy = clamp(v, 0.0f, 1.0f) * float(max(0, depthH - 1));
        int x0 = int(gx);
        int y0 = int(gy);
        int x1 = min(depthW - 1, x0 + 1);
        int y1 = min(depthH - 1, y0 + 1);
        float fx = gx - float(x0);
        float fy = gy - float(y0);

        float d00 = disparityMap[y0 * depthW + x0];
        float d10 = disparityMap[y0 * depthW + x1];
        float d01 = disparityMap[y1 * depthW + x0];
        float d11 = disparityMap[y1 * depthW + x1];

        float d = (d00 * (1.0f - fx) + d10 * fx) * (1.0f - fy)
                + (d01 * (1.0f - fx) + d11 * fx) * fy;

        if (abs(depthGamma - 1.0f) > 0.01f) {
            d = pow(clamp(d, 0.0f, 1.0f), max(0.25f, min(3.0f, depthGamma)));
        }
        if (abs(depthContrast) > 0.01f) {
            float factor = 1.0f + depthContrast * 1.5f;
            d = 0.5f + (d - 0.5f) * factor;
        }
        return clamp(d, 0.0f, 1.0f);
    }

    inline float3 sampleRGBLinear(
        device const uchar* baseRGB,
        int width,
        int y,
        float srcX
    ) {
        float clX = clamp(srcX, 0.0f, float(width - 1));
        int ix0 = int(clX);
        int ix1 = min(width - 1, ix0 + 1);
        float fx = clX - float(ix0);
        int idx0 = (y * width + ix0) * 3;
        int idx1 = (y * width + ix1) * 3;

        float3 c0 = float3(float(baseRGB[idx0]), float(baseRGB[idx0 + 1]), float(baseRGB[idx0 + 2]));
        float3 c1 = float3(float(baseRGB[idx1]), float(baseRGB[idx1 + 1]), float(baseRGB[idx1 + 2]));
        return mix(c0, c1, fx);
    }

    // 背景優先・エッジ保護付きサンプリング
    inline float3 sampleEyeProtected(
        device const uchar* baseRGB,
        device const float* disparityMap,
        constant DIBRUniforms& u,
        int x,
        int y,
        float v,
        float dCenter,
        float signDir
    ) {
        float dispOffset = (dCenter - u.focusVal) * u.halfBaseline;
        float srcX = float(x) + signDir * dispOffset;

        // シフト先の元深度を確認し、手前の前景(dSrc > dCenter + 0.08)を誤って引き伸ばすオクルージョンを抑制
        float srcU = clamp(srcX / float(u.width), 0.0f, 1.0f);
        float dSrc = sampleDisparity(disparityMap, u.depthW, u.depthH, srcU, v, u.depthGamma, u.depthContrast);
        if (dSrc > dCenter + 0.08f) {
            // 背景側の画素へ逃がす（前景の反対方向へ探索）
            float stepPx = max(1.0f, u.halfBaseline * 0.25f);
            float searchDir = -signDir;
            float bestX = srcX;
            float bestDiff = dSrc - dCenter;
            for (int k = 1; k <= 6; k++) {
                float candX = clamp(srcX + searchDir * stepPx * float(k), 0.0f, float(u.width - 1));
                float candU = candX / float(u.width);
                float dCand = sampleDisparity(disparityMap, u.depthW, u.depthH, candU, v, u.depthGamma, u.depthContrast);
                float diff = dCand - dCenter;
                if (diff < bestDiff) {
                    bestDiff = diff;
                    bestX = candX;
                }
                if (diff <= 0.03f) {
                    break;
                }
            }
            float3 bgColor = sampleRGBLinear(baseRGB, u.width, y, bestX);
            float3 rawColor = sampleRGBLinear(baseRGB, u.width, y, srcX);
            float blend = clamp((dSrc - dCenter - 0.08f) * 4.0f, 0.0f, 1.0f);
            return mix(rawColor, bgColor, blend);
        }

        return sampleRGBLinear(baseRGB, u.width, y, srcX);
    }

    kernel void dibr_warp_lr(
        device const uchar* baseRGB [[buffer(0)]],
        device const float* disparityMap [[buffer(1)]],
        device uchar* outLeftRGB [[buffer(2)]],
        device uchar* outRightRGB [[buffer(3)]],
        constant DIBRUniforms& u [[buffer(4)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        int x = int(gid.x);
        int y = int(gid.y);
        if (x >= u.width || y >= u.height) {
            return;
        }

        float uu = float(x) / float(u.width);
        float vv = float(y) / float(u.height);
        float d = sampleDisparity(disparityMap, u.depthW, u.depthH, uu, vv, u.depthGamma, u.depthContrast);

        float3 leftColor = sampleEyeProtected(baseRGB, disparityMap, u, x, y, vv, d, -1.0f);
        float3 rightColor = sampleEyeProtected(baseRGB, disparityMap, u, x, y, vv, d, +1.0f);

        int dst = (y * u.width + x) * 3;
        outLeftRGB[dst] = uchar(clamp(int(round(leftColor.r)), 0, 255));
        outLeftRGB[dst + 1] = uchar(clamp(int(round(leftColor.g)), 0, 255));
        outLeftRGB[dst + 2] = uchar(clamp(int(round(leftColor.b)), 0, 255));

        outRightRGB[dst] = uchar(clamp(int(round(rightColor.r)), 0, 255));
        outRightRGB[dst + 1] = uchar(clamp(int(round(rightColor.g)), 0, 255));
        outRightRGB[dst + 2] = uchar(clamp(int(round(rightColor.b)), 0, 255));
    }
    """
}
