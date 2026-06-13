//
//  AnimationParserTests.swift
//  electragneTests
//

import Testing
import Foundation
@testable import electragne

struct AnimationParserTests {

    /// Minimal desktopPet-style document: one full animation plus one with no
    /// frames (which must be dropped).
    private static let fixture = """
    <?xml version="1.0"?>
    <animations>
      <image>
        <tilesx>4</tilesx>
        <tilesy>2</tilesy>
      </image>
      <animation id="1">
        <name>walk</name>
        <start>
          <x>5</x>
          <y>-3</y>
          <interval>100</interval>
          <offsety>0</offsety>
        </start>
        <end>
          <x>7</x>
          <y>3</y>
          <interval>300</interval>
        </end>
        <sequence repeat="2" repeatfrom="1">
          <frame>0</frame>
          <frame>1</frame>
          <frame>2</frame>
          <next probability="50" only="none">2</next>
          <next probability="50" only="none">3</next>
        </sequence>
        <gravity>
          <next probability="100" only="none">5</next>
        </gravity>
        <border>
          <next probability="100" only="none">3</next>
        </border>
      </animation>
      <animation id="99">
        <name>empty</name>
        <sequence>
        </sequence>
      </animation>
    </animations>
    """

    /// Writes the fixture to a temp file and parses it (the parser only takes a URL).
    private func parseFixture() throws -> (parser: AnimationParser, animations: [PetAnimation]) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("anim-\(UUID().uuidString).xml")
        try Self.fixture.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let parser = AnimationParser()
        let animations = try #require(parser.parseAnimations(from: url))
        return (parser, animations)
    }

    @Test func parsesTileGrid() throws {
        let (parser, _) = try parseFixture()
        #expect(parser.tilesX == 4)
        #expect(parser.tilesY == 2)
    }

    @Test func dropsAnimationWithNoFrames() throws {
        let (_, animations) = try parseFixture()
        // id="99" has no <frame> elements and must be dropped.
        #expect(animations.count == 1)
        #expect(animations.first?.id == "1")
    }

    @Test func parsesFramesIntervalsAndMovement() throws {
        let (_, animations) = try parseFixture()
        let anim = try #require(animations.first)
        #expect(anim.frames == [0, 1, 2])
        #expect(abs(anim.startInterval - 0.1) < 1e-9)   // 100 / 1000
        #expect(abs(anim.endInterval - 0.3) < 1e-9)     // 300 / 1000
        #expect(anim.startMoveX == 5)
        #expect(anim.startMoveY == -3)
        #expect(anim.endMoveX == 7)
        #expect(anim.endMoveY == 3)
        #expect(anim.repeatFrom == 1)
        #expect(anim.repeatCount.evaluate() == 2)
    }

    @Test func routesTransitionsToTheRightBuckets() throws {
        let (_, animations) = try parseFixture()
        let anim = try #require(animations.first)
        #expect(anim.nextAnimations.map(\.animationID) == ["2", "3"])
        #expect(anim.nextAnimations.map(\.probability) == [50, 50])
        #expect(anim.gravityTransitions.map(\.animationID) == ["5"])
        #expect(anim.borderTransitions.map(\.animationID) == ["3"])
    }
}
