import Foundation
import Testing
@testable import xelated

/// Batch sizing decides how much goes onto the phone at once. Too much wedges the phone;
/// too little means babysitting dozens of handoffs.
@Suite("Batch planning")
struct BatchPlanningTests {
    private func items(_ sizes: [Int64]) -> [MediaItem] {
        sizes.enumerated().map { index, size in
            makeItem(name: "f\(index).jpg", bytes: size)
        }
    }

    private func plan(
        _ sizes: [Int64],
        free: Int64,
        cap: Int64 = 8 * oneGiB
    ) throws -> BatchPlan? {
        try AndroidBackupService.makePlan(from: items(sizes), freeBytes: free, cap: cap)
    }

    @Test("On a roomy phone the user's cap is the limit")
    func capLimitsBatchOnRoomyPhone() throws {
        let plan = try #require(try plan(Array(repeating: oneGiB, count: 40), free: 50 * oneGiB))

        #expect(plan.totalBytes <= 8 * oneGiB)
        #expect(plan.items.count == 8)
    }

    @Test("Headroom is 10% of free space when that exceeds the floor")
    func headroomIsProportionalWhenRoomy() throws {
        let plan = try #require(try plan([oneGiB], free: 50 * oneGiB))
        #expect(plan.headroomBytes == 5 * oneGiB)
    }

    @Test("Headroom never drops below the 2 GiB floor")
    func headroomHasAFloor() throws {
        // 10% of a nearly-full phone is far too little for a photo app's upload queue.
        let plan = try #require(try plan([oneGiB], free: 6 * oneGiB))
        #expect(plan.headroomBytes == 2 * oneGiB)
    }

    @Test("On a full phone, free space limits the batch instead of the cap")
    func freeSpaceLimitsBatchOnFullPhone() throws {
        let plan = try #require(try plan(Array(repeating: oneGiB, count: 40), free: 6 * oneGiB))

        #expect(plan.totalBytes <= 6 * oneGiB - plan.headroomBytes)
        #expect(plan.items.count == 4)
    }

    @Test("Packing is greedy, so a huge file doesn't stall smaller ones")
    func greedyPackingSkipsOversizedFile() throws {
        let plan = try #require(
            try plan([20 * oneGiB, oneGiB, oneGiB, oneGiB], free: 50 * oneGiB)
        )

        #expect(plan.items.count == 3)
        #expect(plan.items.allSatisfy { $0.byteSize == oneGiB })
    }

    @Test("A file larger than the cap eventually travels alone")
    func oversizedFileGoesAlone() throws {
        // Once it's all that's left, the greedy pass takes nothing and the fallback
        // sends it by itself.
        let plan = try #require(try plan([12 * oneGiB], free: 50 * oneGiB))

        #expect(plan.items.count == 1)
        #expect(plan.totalBytes == 12 * oneGiB)
    }

    @Test("Every file is sent and the loop terminates")
    func loopAlwaysTerminates() throws {
        // Mirrors the coordinator's batch loop. A file that's skipped on every pass
        // would spin here forever.
        var remaining = items([12 * oneGiB, oneGiB, oneGiB, 9 * oneGiB] + Array(repeating: oneGiB, count: 7))
        var batches = 0

        while !remaining.isEmpty {
            batches += 1
            try #require(batches < 25, "batch loop failed to terminate")

            let plan = try #require(
                try AndroidBackupService.makePlan(
                    from: remaining, freeBytes: 50 * oneGiB, cap: 8 * oneGiB
                )
            )
            try #require(!plan.items.isEmpty, "planner stalled with items outstanding")
            remaining.removeAll { plan.items.contains($0) }
        }

        #expect(remaining.isEmpty)
    }

    @Test("A file too big for the phone fails loudly")
    func oversizedForDeviceThrows() throws {
        // Silently skipping would leave the run looking complete while a photo was
        // never backed up.
        #expect(throws: AndroidBackupError.self) {
            _ = try plan([40 * oneGiB], free: 10 * oneGiB)
        }
    }

    @Test("A phone with no free space at all fails")
    func fullPhoneThrows() throws {
        #expect(throws: AndroidBackupError.self) {
            _ = try plan([oneGiB], free: 0)
        }
    }

    @Test("Nothing outstanding yields no plan")
    func emptyInputYieldsNil() throws {
        #expect(try plan([], free: 50 * oneGiB) == nil)
    }
}
