import Foundation
import UIKit
import AnimationCache
import Display
import RLottieBinding
import GZip
import WebPBinding

public func cacheLottieAnimation(data: Data, width: Int, height: Int, keyframeOnly: Bool, writer: AnimationCacheItemWriter, firstFrameOnly: Bool, customColor: UIColor?) {
    let work: () -> Void = {
        let decompressedData = TGGUnzipData(data, 2 * 1024 * 1024) ?? data
        guard let animation = LottieInstance(data: decompressedData, fitzModifier: .none, colorReplacements: nil, cacheKey: "") else {
            writer.finish()
            return
        }
        
        let frameSkip: Int = 2
        /*if animation.frameRate >= 60 {
            if ProcessInfo.processInfo.processorCount > 2 {
                frameSkip = 1
            } else {
                frameSkip = 2
            }
        } else {
            frameSkip = 1
        }*/
        
        let frameDuration = Double(frameSkip) / Double(animation.frameRate)
        for i in stride(from: 0, through: animation.frameCount - 1, by: frameSkip) {
            if writer.isCancelled {
                break
            }
            writer.add(with: { surface in
                animation.renderFrame(with: i, into: surface.argb, width: Int32(surface.width), height: Int32(surface.height), bytesPerRow: Int32(surface.bytesPerRow))
                if customColor != nil {
                    for y in 0 ..< surface.height {
                        for x in 0 ..< surface.width {
                            let pixel = surface.argb.advanced(by: y * surface.bytesPerRow + x * 4)
                            let a = pixel.advanced(by: 3).pointee
                            
                            pixel.advanced(by: 0).pointee = a
                            pixel.advanced(by: 1).pointee = a
                            pixel.advanced(by: 2).pointee = a
                            pixel.advanced(by: 3).pointee = a
                        }
                    }
                }
                return frameDuration
            }, proposedWidth: width, proposedHeight: height, insertKeyframe: i == 0 || keyframeOnly)
            
            if firstFrameOnly {
                break
            }
        }
        
        writer.finish()
    }
    
    writer.queue.async(work)
}

public func cacheStillSticker(path: String, width: Int, height: Int, writer: AnimationCacheItemWriter, customColor: UIColor?) {
    let work: () -> Void = {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let image = WebP.convert(fromWebP: data) {
            writer.add(with: { surface in
                guard let context = DrawingContext(size: CGSize(width: CGFloat(surface.width), height: CGFloat(surface.height)), scale: 1.0, opaque: false, clear: true, bytesPerRow: surface.bytesPerRow) else {
                    return 1.0
                }
                context.withFlippedContext { c in
                    UIGraphicsPushContext(c)
                    
                    if let customColor = customColor {
                        c.clip(to: CGRect(origin: CGPoint(), size: context.size), mask: image.cgImage!)
                        c.setFillColor(customColor.cgColor)
                        c.fill(CGRect(origin: CGPoint(), size: context.size))
                    } else {
                        c.draw(image.cgImage!, in: CGRect(origin: CGPoint(), size: context.size))
                    }
                    UIGraphicsPopContext()
                }
                memcpy(surface.argb, context.bytes, surface.height * surface.bytesPerRow)
                return 1.0
            }, proposedWidth: width, proposedHeight: height, insertKeyframe: true)
        }
        
        writer.finish()
    }
    
    writer.queue.async(work)
}
