#!/usr/bin/env swift

import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct ScreenshotSpec {
    let input: String
    let output: String
    let eyebrow: String
    let title: String
}

private struct DeviceSpec {
    let rawDirectory: String
    let outputDirectory: String
    let eyebrowDeviceName: String
    let width: Int
    let height: Int
    let screenshotWidth: CGFloat
    let screenshotTop: CGFloat
    let eyebrowTop: CGFloat
    let eyebrowSize: CGFloat
    let titleTop: CGFloat
    let titleSize: CGFloat
    let titleLineHeight: CGFloat
}

private let screenshots = [
    ScreenshotSpec(
        input: "01-prompt.png",
        output: "01-word-tracking.png",
        eyebrow: "WORD TRACKING",
        title: "Stay on script.\nKeep eye contact."
    ),
    ScreenshotSpec(
        input: "03-guidance.png",
        output: "02-guidance-modes.png",
        eyebrow: "YOUR WORDS, YOUR PACE",
        title: "Choose how Textream\nfollows you."
    ),
    ScreenshotSpec(
        input: "05-settings.png",
        output: "03-accessibility.png",
        eyebrow: "MADE FOR READING",
        title: "Make every word\neasy to read."
    )
]

private let devices = [
    DeviceSpec(
        rawDirectory: "raw/iphone-6.9",
        outputDirectory: "upload/iphone-6.5",
        eyebrowDeviceName: "TEXTREAM FOR IPHONE",
        width: 1284,
        height: 2778,
        screenshotWidth: 980,
        screenshotTop: 640,
        eyebrowTop: 128,
        eyebrowSize: 37,
        titleTop: 228,
        titleSize: 92,
        titleLineHeight: 108
    ),
    DeviceSpec(
        rawDirectory: "raw/ipad-13",
        outputDirectory: "upload/ipad-13",
        eyebrowDeviceName: "TEXTREAM FOR IPAD",
        width: 2064,
        height: 2752,
        screenshotWidth: 1600,
        screenshotTop: 610,
        eyebrowTop: 110,
        eyebrowSize: 43,
        titleTop: 208,
        titleSize: 106,
        titleLineHeight: 124
    )
]

private final class Canvas {
    let width: Int
    let height: Int
    let context: CGContext

    init(width: Int, height: Int) {
        self.width = width
        self.height = height

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            fatalError("Unable to create a \(width)×\(height) sRGB canvas")
        }
        context.interpolationQuality = .high
        self.context = context
    }

    func topRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(
            x: x,
            y: y,
            width: width,
            height: height
        )
    }

    func drawBackground(accentIndex: Int) {
        let canvasWidth = CGFloat(width)
        let canvasHeight = CGFloat(height)
        let bounds = CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
        context.setFillColor(CGColor(srgbRed: 0.018, green: 0.019, blue: 0.030, alpha: 1))
        context.fill(bounds)

        let baseGradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [
                CGColor(srgbRed: 0.080, green: 0.082, blue: 0.145, alpha: 1),
                CGColor(srgbRed: 0.026, green: 0.028, blue: 0.048, alpha: 1),
                CGColor(srgbRed: 0.005, green: 0.006, blue: 0.011, alpha: 1)
            ] as CFArray,
            locations: [0, 0.50, 1]
        )!
        context.drawLinearGradient(
            baseGradient,
            start: CGPoint(x: 0, y: canvasHeight),
            end: CGPoint(x: canvasWidth, y: 0),
            options: []
        )

        let accentColors: [(CGFloat, CGFloat, CGFloat)] = [
            (0.27, 0.34, 1.00),
            (0.35, 0.28, 1.00),
            (1.00, 0.43, 0.14),
            (0.12, 0.48, 1.00)
        ]
        let accent = accentColors[accentIndex % accentColors.count]
        let glow = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [
                CGColor(srgbRed: accent.0, green: accent.1, blue: accent.2, alpha: 0.24),
                CGColor(srgbRed: accent.0, green: accent.1, blue: accent.2, alpha: 0.00)
            ] as CFArray,
            locations: [0, 1]
        )!
        context.drawRadialGradient(
            glow,
            startCenter: CGPoint(x: canvasWidth * 0.18, y: canvasHeight * 0.28),
            startRadius: 0,
            endCenter: CGPoint(x: canvasWidth * 0.18, y: canvasHeight * 0.28),
            endRadius: canvasWidth * 0.86,
            options: [.drawsAfterEndLocation]
        )

        drawOrbit(
            rect: CGRect(
                x: canvasWidth * 0.50,
                y: -canvasHeight * 0.18,
                width: canvasWidth * 0.95,
                height: canvasHeight * 0.58
            ),
            color: CGColor(srgbRed: 1.00, green: 0.56, blue: 0.20, alpha: 0.56),
            lineWidth: max(3, canvasWidth * 0.0035),
            blur: canvasWidth * 0.013
        )
        drawOrbit(
            rect: CGRect(
                x: -canvasWidth * 0.72,
                y: canvasHeight * 0.70,
                width: canvasWidth * 1.28,
                height: canvasHeight * 0.56
            ),
            color: CGColor(srgbRed: 0.17, green: 0.34, blue: 1.00, alpha: 0.42),
            lineWidth: max(3, canvasWidth * 0.0032),
            blur: canvasWidth * 0.014
        )
    }

    private func drawOrbit(rect: CGRect, color: CGColor, lineWidth: CGFloat, blur: CGFloat) {
        context.saveGState()
        context.setStrokeColor(color)
        context.setLineWidth(lineWidth)
        context.setShadow(offset: .zero, blur: blur, color: color)
        context.strokeEllipse(in: rect)
        context.restoreGState()
    }

    func drawText(
        _ string: String,
        top: CGFloat,
        height: CGFloat,
        size: CGFloat,
        weight: NSFont.Weight,
        color: NSColor,
        lineHeight: CGFloat,
        tracking: CGFloat = 0
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.lineBreakMode = .byWordWrapping

        let attributed = NSAttributedString(
            string: string,
            attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: color,
                .paragraphStyle: paragraph,
                .kern: tracking
            ]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let canvasWidth = CGFloat(width)
        let rect = CGRect(
            x: canvasWidth * 0.055,
            y: CGFloat(self.height) - top - height,
            width: canvasWidth * 0.89,
            height: height
        )
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)

        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(self.height))
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    func drawScreenshot(_ image: CGImage, width targetWidth: CGFloat, top: CGFloat) {
        let targetHeight = targetWidth * CGFloat(image.height) / CGFloat(image.width)
        let x = (CGFloat(width) - targetWidth) / 2
        let rect = topRect(x: x, y: top, width: targetWidth, height: targetHeight)
        let radius = targetWidth * 0.072

        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -18),
            blur: targetWidth * 0.055,
            color: CGColor(gray: 0, alpha: 0.82)
        )
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.addPath(CGPath(roundedRect: rect.insetBy(dx: -8, dy: -8), cornerWidth: radius + 8, cornerHeight: radius + 8, transform: nil))
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        context.translateBy(x: rect.minX, y: rect.minY + rect.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        context.restoreGState()

        context.saveGState()
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.18))
        context.setLineWidth(max(2, targetWidth * 0.0024))
        context.addPath(CGPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerWidth: radius - 1, cornerHeight: radius - 1, transform: nil))
        context.strokePath()
        context.restoreGState()
    }

    func writePNG(to url: URL) throws {
        let temporaryURL = url.deletingLastPathComponent().appending(
            path: ".\(url.lastPathComponent).unflipped.png"
        )
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                  temporaryURL as CFURL,
                  UTType.png.identifier as CFString,
                  1,
                  nil
              ) else {
            throw NSError(domain: "TextreamScreenshotComposer", code: 1)
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImagePropertyPNGDictionary: [:]] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "TextreamScreenshotComposer", code: 2)
        }

        // Core Graphics bitmap rows are bottom-up. Materialize the final PNG
        // with top-down rows so App Store Connect and image viewers display it
        // without orientation metadata or an alpha channel.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        process.arguments = ["--flip", "vertical", temporaryURL.path, "--out", url.path]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: temporaryURL)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "TextreamScreenshotComposer", code: 4)
        }
    }
}

private func loadImage(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw NSError(
            domain: "TextreamScreenshotComposer",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Unable to read \(url.path)"]
        )
    }
    return image
}

private func compose(device: DeviceSpec, root: URL) throws -> [URL] {
    let outputDirectory = root.appending(path: device.outputDirectory, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    // Keep each upload directory in lockstep with this manifest while leaving
    // the original simulator captures untouched.
    let generatedNames = [
        "01-word-tracking.png",
        "02-guidance-modes.png",
        "03-recordings.png",
        "03-accessibility.png",
        "04-accessibility.png"
    ]
    for name in generatedNames {
        let generatedURL = outputDirectory.appending(path: name)
        if FileManager.default.fileExists(atPath: generatedURL.path) {
            try FileManager.default.removeItem(at: generatedURL)
        }
    }

    return try screenshots.enumerated().map { index, spec in
        let inputURL = root.appending(path: device.rawDirectory).appending(path: spec.input)
        let outputURL = outputDirectory.appending(path: spec.output)
        let rawImage = try loadImage(inputURL)
        let canvas = Canvas(width: device.width, height: device.height)
        canvas.drawBackground(accentIndex: index)
        canvas.drawText(
            "\(device.eyebrowDeviceName)  •  \(spec.eyebrow)",
            top: device.eyebrowTop,
            height: device.eyebrowSize * 1.6,
            size: device.eyebrowSize,
            weight: .bold,
            color: NSColor(srgbRed: 0.70, green: 0.71, blue: 0.76, alpha: 1),
            lineHeight: device.eyebrowSize * 1.25,
            tracking: device.eyebrowSize * 0.045
        )
        canvas.drawText(
            spec.title,
            top: device.titleTop,
            height: device.titleLineHeight * 2.35,
            size: device.titleSize,
            weight: .heavy,
            color: .white,
            lineHeight: device.titleLineHeight
        )
        canvas.drawScreenshot(rawImage, width: device.screenshotWidth, top: device.screenshotTop)
        try canvas.writePNG(to: outputURL)
        print("Wrote \(outputURL.path)")
        return outputURL
    }
}

private func makeContactSheet(groups: [[URL]], root: URL) throws -> URL {
    let width = 1800
    let gutter: CGFloat = 40
    let columnCount = CGFloat(screenshots.count)
    let tileWidth = (CGFloat(width) - gutter * (columnCount + 1)) / columnCount
    let tileHeight: CGFloat = 760
    let labelHeight: CGFloat = 70
    let height = Int(gutter * 3 + (tileHeight + labelHeight) * 2)
    let canvas = Canvas(width: width, height: height)
    canvas.context.setFillColor(CGColor(srgbRed: 0.025, green: 0.026, blue: 0.038, alpha: 1))
    canvas.context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    for (row, urls) in groups.enumerated() {
        for (column, url) in urls.enumerated() {
            let image = try loadImage(url)
            let x = gutter + CGFloat(column) * (tileWidth + gutter)
            let y = gutter + CGFloat(row) * (tileHeight + labelHeight + gutter)
            let fittedHeight = min(tileHeight, tileWidth * CGFloat(image.height) / CGFloat(image.width))
            let drawWidth = fittedHeight * CGFloat(image.width) / CGFloat(image.height)
            let rect = canvas.topRect(
                x: x + (tileWidth - drawWidth) / 2,
                y: y,
                width: drawWidth,
                height: fittedHeight
            )
            canvas.context.saveGState()
            canvas.context.translateBy(x: rect.minX, y: rect.minY + rect.height)
            canvas.context.scaleBy(x: 1, y: -1)
            canvas.context.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
            canvas.context.restoreGState()
        }
        canvas.drawText(
            row == 0 ? "IPHONE 6.5-INCH UPLOAD SET" : "IPAD 13-INCH UPLOAD SET",
            top: gutter + CGFloat(row) * (tileHeight + labelHeight + gutter) + tileHeight,
            height: labelHeight,
            size: 27,
            weight: .bold,
            color: NSColor(srgbRed: 0.70, green: 0.71, blue: 0.76, alpha: 1),
            lineHeight: 34,
            tracking: 1.2
        )
    }

    let output = root.appending(path: "contact-sheet.png")
    try canvas.writePNG(to: output)
    print("Wrote \(output.path)")
    return output
}

let scriptURL = URL(fileURLWithPath: #filePath)
let root = scriptURL.deletingLastPathComponent()

do {
    let groups = try devices.map { try compose(device: $0, root: root) }
    _ = try makeContactSheet(groups: groups, root: root)
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
