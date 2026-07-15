//
//  SpriteGridTests.swift
//  electragneTests
//

import Testing
@testable import electragne

struct SpriteGridTests {
    @Test func mapsFrameToCellInDefaultGrid() {
        let grid = SpriteGrid(tilesX: 16, tilesY: 11)
        #expect(grid.maxFrameNumber == 175)
        #expect(grid.cell(for: 0).map { [$0.col, $0.row] } == [0, 0])
        #expect(grid.cell(for: 15).map { [$0.col, $0.row] } == [15, 0])
        #expect(grid.cell(for: 16).map { [$0.col, $0.row] } == [0, 1])
        #expect(grid.cell(for: 175).map { [$0.col, $0.row] } == [15, 10])
    }

    @Test func outOfRangeFrameIsNil() {
        let grid = SpriteGrid(tilesX: 16, tilesY: 11)
        #expect(grid.cell(for: 176) == nil)
        #expect(grid.cell(for: -1) == nil)
    }

    @Test func smallGridLastCell() {
        let grid = SpriteGrid(tilesX: 4, tilesY: 2)
        #expect(grid.maxFrameNumber == 7)
        #expect(grid.cell(for: 7).map { [$0.col, $0.row] } == [3, 1])
        #expect(grid.cell(for: 8) == nil)
    }

    @Test func degenerateGridDoesNotTrap() {
        // tilesX == 0 would trap on `% 0` / `/ 0` without the guard.
        #expect(SpriteGrid(tilesX: 0, tilesY: 11).cell(for: 0) == nil)
        #expect(SpriteGrid(tilesX: 16, tilesY: 0).cell(for: 0) == nil)
    }
}
