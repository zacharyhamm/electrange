//
//  SpriteRenderer.swift
//  electragne
//
//  Created by zacharyhamm on 2/4/26.
//

import Foundation
import AppKit

/// Shared sprite rendering utility to extract frames from sprite sheets
class SpriteRenderer {
    let spriteSheet: NSImage
    let tilesX: Int
    let tilesY: Int

    private let tileWidth: CGFloat
    private let tileHeight: CGFloat
    private let cachedCGImage: CGImage  // Cache CGImage to avoid repeated extraction
    private let maxFrameNumber: Int     // Maximum valid frame number

    init?(spriteSheet: NSImage?, tilesX: Int, tilesY: Int) {
        guard let spriteSheet = spriteSheet,
              let cgImage = spriteSheet.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        self.spriteSheet = spriteSheet
        self.tilesX = tilesX
        self.tilesY = tilesY
        self.tileWidth = CGFloat(cgImage.width) / CGFloat(tilesX)
        self.tileHeight = CGFloat(cgImage.height) / CGFloat(tilesY)
        self.cachedCGImage = cgImage
        self.maxFrameNumber = tilesX * tilesY - 1
    }

    /// Extract a single frame from the sprite sheet
    /// - Parameter frameNumber: The frame index (0 to tilesX*tilesY-1)
    /// - Returns: The extracted frame image, or nil if frameNumber is out of bounds
    func extractFrame(frameNumber: Int) -> NSImage? {
        // Bounds checking
        guard frameNumber >= 0 && frameNumber <= maxFrameNumber else {
            print("Warning: Invalid frame number \(frameNumber), valid range is 0-\(maxFrameNumber)")
            return nil
        }

        let col = frameNumber % tilesX
        let row = frameNumber / tilesX

        let rect = CGRect(
            x: CGFloat(col) * tileWidth,
            y: CGFloat(row) * tileHeight,
            width: tileWidth,
            height: tileHeight
        )

        guard let croppedImage = cachedCGImage.cropping(to: rect) else {
            return nil
        }

        return NSImage(cgImage: croppedImage, size: NSSize(width: tileWidth, height: tileHeight))
    }
}
