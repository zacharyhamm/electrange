//
//  SpriteRenderer.swift
//  electragne
//
//  Created by zacharyhamm on 2/4/26.
//

import Foundation
import AppKit
import os

/// Pure tile-grid math for a sprite sheet laid out as `tilesX` × `tilesY` cells.
/// Extracted from SpriteRenderer so the frame→(col,row) mapping can be tested
/// without a real bitmap, and so a degenerate grid can't trap on `% 0` / `/ 0`.
struct SpriteGrid: Equatable {
    let tilesX: Int
    let tilesY: Int

    /// Highest valid frame number, or -1 for a degenerate (zero-tile) grid.
    var maxFrameNumber: Int { tilesX * tilesY - 1 }

    /// (col, row) for a frame number, or nil if the grid is degenerate or the
    /// frame is out of range.
    func cell(for frame: Int) -> (col: Int, row: Int)? {
        guard tilesX > 0, tilesY > 0, frame >= 0, frame <= maxFrameNumber else { return nil }
        return (frame % tilesX, frame / tilesX)
    }
}

/// Shared sprite rendering utility to extract frames from sprite sheets
class SpriteRenderer {
    let spriteSheet: NSImage
    let grid: SpriteGrid

    private let tileWidth: CGFloat
    private let tileHeight: CGFloat
    private var frames: [NSImage?]

    init?(spriteSheet: NSImage?, tilesX: Int, tilesY: Int) {
        guard tilesX > 0, tilesY > 0,
              let spriteSheet = spriteSheet,
              let cgImage = spriteSheet.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        self.spriteSheet = spriteSheet
        self.grid = SpriteGrid(tilesX: tilesX, tilesY: tilesY)
        self.tileWidth = CGFloat(cgImage.width) / CGFloat(tilesX)
        self.tileHeight = CGFloat(cgImage.height) / CGFloat(tilesY)
        
        let maxFrames = tilesX * tilesY
        self.frames = Array(repeating: nil, count: maxFrames)
        
        for frameNumber in 0..<maxFrames {
            if let (col, row) = self.grid.cell(for: frameNumber) {
                let rect = CGRect(
                    x: CGFloat(col) * self.tileWidth,
                    y: CGFloat(row) * self.tileHeight,
                    width: self.tileWidth,
                    height: self.tileHeight
                )
                if let croppedImage = cgImage.cropping(to: rect) {
                    self.frames[frameNumber] = NSImage(cgImage: croppedImage, size: NSSize(width: self.tileWidth, height: self.tileHeight))
                }
            }
        }
    }

    /// Extract a single frame from the sprite sheet
    /// - Parameter frameNumber: The frame index (0 to tilesX*tilesY-1)
    /// - Returns: The extracted frame image, or nil if frameNumber is out of bounds
    func extractFrame(frameNumber: Int) -> NSImage? {
        guard let _ = grid.cell(for: frameNumber) else {
            Log.rendering.debug("Invalid frame number \(frameNumber), valid range is 0-\(self.grid.maxFrameNumber)")
            return nil
        }

        return frames[frameNumber]
    }
}
