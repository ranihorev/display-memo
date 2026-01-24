#!/usr/bin/env swift

// Test script for DisplayMemo display mapping logic
// Run with: swift test_display_mapping.swift

import Foundation

// Simplified test structures matching the app
struct TestDisplay {
    let id: Int
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let isMain: Bool
}

struct SavedPosition {
    let x: Int
    let y: Int
    let isMain: Bool
}

struct MappingResult {
    let displayID: Int
    let targetX: Int
    let targetY: Int
}

// Simulate the mapping logic
func mapDisplays(saved: [SavedPosition], live: [TestDisplay]) -> [MappingResult] {
    var unusedLive = live
    var mappings: [MappingResult] = []

    // Find main display for normalization
    guard let liveMain = live.first(where: { $0.isMain }) else {
        print("❌ No main display")
        return []
    }

    for (idx, savedPos) in saved.enumerated() {
        guard !unusedLive.isEmpty else {
            print("⏭️ Skipping saved position \(idx) - no more displays")
            break
        }

        // Proximity-based matching
        let best = unusedLive.enumerated().min { a, b in
            let aDist = abs(a.element.x - savedPos.x) + abs(a.element.y - savedPos.y)
            let bDist = abs(b.element.x - savedPos.x) + abs(b.element.y - savedPos.y)
            return aDist < bDist
        }!

        // Adjust Y if needed to avoid gaps
        var adjustedY = savedPos.y
        if savedPos.y > 0 && savedPos.isMain == false {
            // Check if we need to adjust based on main display height
            if let mainDisplay = live.first(where: { $0.isMain }) {
                if savedPos.y > mainDisplay.height {
                    adjustedY = mainDisplay.height
                    print("📏 Adjusted Y from \(savedPos.y) to \(adjustedY)")
                }
            }
        }

        mappings.append(MappingResult(
            displayID: best.element.id,
            targetX: savedPos.x,
            targetY: adjustedY
        ))

        unusedLive.remove(at: best.offset)
        print("✅ Mapped display \(best.element.id) to (\(savedPos.x), \(adjustedY))")
    }

    if !unusedLive.isEmpty {
        print("ℹ️ \(unusedLive.count) display(s) not mapped")
    }

    return mappings
}

// Test scenarios
func runTests() {
    print("\n=== Test 1: Same number of displays ===")
    let saved1 = [
        SavedPosition(x: 0, y: 0, isMain: true),
        SavedPosition(x: 173, y: 1080, isMain: false)
    ]
    let live1 = [
        TestDisplay(id: 1, x: 0, y: 0, width: 1512, height: 982, isMain: true),
        TestDisplay(id: 3, x: 1512, y: 0, width: 1920, height: 1080, isMain: false)
    ]
    let result1 = mapDisplays(saved: saved1, live: live1)
    assert(result1.count == 2, "Should map both displays")
    print("✅ Test 1 passed: \(result1.count) displays mapped")

    print("\n=== Test 2: Fewer live displays than saved ===")
    let saved2 = [
        SavedPosition(x: 0, y: 0, isMain: true),
        SavedPosition(x: 173, y: 1080, isMain: false)
    ]
    let live2 = [
        TestDisplay(id: 1, x: 0, y: 0, width: 1512, height: 982, isMain: true)
    ]
    let result2 = mapDisplays(saved: saved2, live: live2)
    assert(result2.count == 1, "Should map only available display")
    assert(result2[0].displayID == 1, "Should map to display 1")
    assert(result2[0].targetX == 0 && result2[0].targetY == 0, "Should position at origin")
    print("✅ Test 2 passed: Partial mapping works")

    print("\n=== Test 3: More live displays than saved ===")
    let saved3 = [
        SavedPosition(x: 0, y: 0, isMain: true)
    ]
    let live3 = [
        TestDisplay(id: 1, x: 0, y: 0, width: 1512, height: 982, isMain: true),
        TestDisplay(id: 3, x: 1512, y: 0, width: 1920, height: 1080, isMain: false)
    ]
    let result3 = mapDisplays(saved: saved3, live: live3)
    assert(result3.count == 1, "Should map only saved positions")
    assert(result3[0].displayID == 1, "Should map main display")
    print("✅ Test 3 passed: Extra displays ignored")

    print("\n=== Test 4: Y adjustment for gap avoidance ===")
    let saved4 = [
        SavedPosition(x: 0, y: 0, isMain: true),
        SavedPosition(x: 173, y: 1080, isMain: false)  // Y > main display height
    ]
    let live4 = [
        TestDisplay(id: 1, x: 0, y: 0, width: 1512, height: 982, isMain: true),  // Shorter main
        TestDisplay(id: 3, x: 1512, y: 0, width: 1920, height: 1080, isMain: false)
    ]
    let result4 = mapDisplays(saved: saved4, live: live4)
    assert(result4.count == 2, "Should map both displays")
    assert(result4[1].targetY == 982, "Should adjust Y to avoid gap")
    print("✅ Test 4 passed: Y adjustment works")

    print("\n=== Test 5: Different display becomes main ===")
    let saved5 = [
        SavedPosition(x: 0, y: 0, isMain: true),
        SavedPosition(x: 173, y: 1080, isMain: false)
    ]
    let live5 = [
        TestDisplay(id: 3, x: 0, y: 0, width: 1920, height: 1080, isMain: true),  // Different main
        TestDisplay(id: 1, x: 173, y: 1080, width: 1512, height: 982, isMain: false)
    ]
    let result5 = mapDisplays(saved: saved5, live: live5)
    assert(result5.count == 2, "Should map both displays")
    assert(result5[0].displayID == 3, "Should use proximity matching")
    print("✅ Test 5 passed: Works with different main display")

    print("\n✅ All tests passed!")
}

// Run tests
runTests()