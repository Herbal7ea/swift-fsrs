import Foundation
import Testing
@testable import FSRS

@Suite struct DankiFSRS6ContractTests {
    private struct Fixture: Decodable {
        struct Parameters: Decodable {
            let requestRetention: Double
            let maximumIntervalDays: Double
            let weights: [Double]
            let enableFuzz: Bool
            let enableShortTerm: Bool
            let learningSteps: [String]
            let relearningSteps: [String]
            let dayArithmetic: String
        }
        let schemaVersion: Int
        let contract: String
        let referenceEngine: String
        let parameters: Parameters
        let matrix: [MatrixVector]
        let seededSequence: [SeededStep]
        let stressSequence: StressSequence
    }

    private struct StressSequence: Decodable {
        let algorithm: String
        let seed: UInt32
        let count: Int
        let startAt: String
        let deltaMinutes: [Int]
        let checkpointInterval: Int
        let internalNumericTolerance: Double
        let checkpoints: [StressCheckpoint]
    }

    private struct StressCheckpoint: Decodable {
        let index: Int
        let schedulingAt: String
        let expected: Snapshot
    }

    private struct MatrixVector: Decodable {
        let state: String
        let scenario: String
        let rating: Int
        let schedulingAt: String
        let before: Snapshot
        let expected: Snapshot
    }

    private struct SeededStep: Decodable {
        let index: Int
        let rating: Int
        let schedulingAt: String
        let expected: Snapshot
    }

    private struct Snapshot: Decodable {
        let stateRaw: Int
        let dueAt: String
        let stability: Double
        let difficulty: Double
        let reps: Int
        let lapses: Int
        let scheduledDays: Double
        let learningSteps: Int
        let lastReviewAt: String?
    }

    @Test func metadataAndCoverage() throws {
        let fixture = try loadFixture()
        #expect(fixture.schemaVersion == 1)
        #expect(fixture.contract == "danki-fsrs-6-v1")
        #expect(fixture.referenceEngine == "ts-fsrs@5.4.1")
        #expect(fixture.parameters.weights.count == 21)
        #expect(fixture.parameters.dayArithmetic == "UTC calendar days")
        #expect(fixture.matrix.count == 96)
        #expect(fixture.seededSequence.count == 200)
        #expect(fixture.stressSequence.count == 10_000)
        #expect(Set(fixture.matrix.map {
            "\($0.state)|\($0.scenario)|\($0.rating)"
        }).count == fixture.matrix.count)
    }

    @Test func completeTransitionMatrixMatchesContract() throws {
        let fixture = try loadFixture()
        let fsrs = scheduler(fixture.parameters)
        for vector in fixture.matrix {
            let actual = try fsrs.next(
                card: card(vector.before),
                now: date(vector.schedulingAt),
                grade: try #require(Rating(rawValue: vector.rating))
            ).card
            try expect(actual, matches: vector.expected, context: "\(vector.state)/\(vector.scenario)/\(vector.rating)")
        }
    }

    @Test func longSeededHistoryMatchesContract() throws {
        let fixture = try loadFixture()
        let fsrs = scheduler(fixture.parameters)
        var current = Card(due: try date("2026-08-29T18:00:00.000Z"))
        for step in fixture.seededSequence {
            current = try fsrs.next(
                card: current,
                now: date(step.schedulingAt),
                grade: try #require(Rating(rawValue: step.rating))
            ).card
            try expect(current, matches: step.expected, context: "seeded step \(step.index)")
        }
    }

    @Test func deterministicStressHistoryMatchesContract() throws {
        let fixture = try loadFixture()
        let stress = fixture.stressSequence
        #expect(stress.algorithm == "lcg32-v1")
        let fsrs = scheduler(fixture.parameters)
        var random = stress.seed
        var schedulingAt = try date(stress.startAt)
        var current = Card(due: schedulingAt)
        var checkpointIndex = 0
        for index in 1...stress.count {
            random = lcg32(random)
            let rating = try #require(Rating(rawValue: Int(random % 4) + 1))
            random = lcg32(random)
            let delta = stress.deltaMinutes[Int(random % UInt32(stress.deltaMinutes.count))]
            schedulingAt = schedulingAt.addingTimeInterval(Double(delta) * 60)
            current = try fsrs.next(card: current, now: schedulingAt, grade: rating).card
            if index % stress.checkpointInterval == 0 {
                let checkpoint = stress.checkpoints[checkpointIndex]
                checkpointIndex += 1
                #expect(checkpoint.index == index)
                #expect(abs(schedulingAt.timeIntervalSince(try date(checkpoint.schedulingAt))) < 0.001)
                try expect(
                    current,
                    matches: checkpoint.expected,
                    context: "stress step \(index)",
                    internalNumericTolerance: stress.internalNumericTolerance
                )
            }
        }
        #expect(checkpointIndex == stress.checkpoints.count)
    }

    private func scheduler(_ parameters: Fixture.Parameters) -> FSRS {
        FSRS(parameters: FSRSParameters(
            requestRetention: parameters.requestRetention,
            maximumInterval: parameters.maximumIntervalDays,
            w: parameters.weights,
            enableFuzz: parameters.enableFuzz,
            enableShortTerm: parameters.enableShortTerm,
            learningSteps: parameters.learningSteps,
            relearningSteps: parameters.relearningSteps
        ))
    }

    private func card(_ snapshot: Snapshot) throws -> Card {
        Card(
            due: try date(snapshot.dueAt),
            stability: snapshot.stability,
            difficulty: snapshot.difficulty,
            elapsedDays: 0,
            scheduledDays: snapshot.scheduledDays,
            learningSteps: snapshot.learningSteps,
            reps: snapshot.reps,
            lapses: snapshot.lapses,
            state: try #require(CardState(rawValue: snapshot.stateRaw)),
            lastReview: try snapshot.lastReviewAt.map(date)
        )
    }

    private func expect(
        _ actual: Card,
        matches expected: Snapshot,
        context: String,
        internalNumericTolerance: Double = 0.00000001
    ) throws {
        #expect(actual.state.rawValue == expected.stateRaw, Comment(rawValue: context))
        #expect(abs(actual.due.timeIntervalSince(try date(expected.dueAt))) < 0.001, Comment(rawValue: context))
        #expect(abs(actual.stability - expected.stability) < internalNumericTolerance, Comment(rawValue: context))
        #expect(abs(actual.difficulty - expected.difficulty) < internalNumericTolerance, Comment(rawValue: context))
        #expect(actual.reps == expected.reps, Comment(rawValue: context))
        #expect(actual.lapses == expected.lapses, Comment(rawValue: context))
        #expect(abs(actual.scheduledDays - expected.scheduledDays) < 0.00000001, Comment(rawValue: context))
        #expect(actual.learningSteps == expected.learningSteps, Comment(rawValue: context))
        if let expectedLastReview = expected.lastReviewAt {
            let lastReview = try #require(actual.lastReview)
            #expect(abs(lastReview.timeIntervalSince(try date(expectedLastReview))) < 0.001, Comment(rawValue: context))
        } else {
            #expect(actual.lastReview == nil, Comment(rawValue: context))
        }
    }

    private func loadFixture() throws -> Fixture {
        let url = try #require(Bundle.module.url(
            forResource: "danki-fsrs6-contract-v1",
            withExtension: "json",
            subdirectory: "Fixtures"
        ) ?? Bundle.module.url(
            forResource: "danki-fsrs6-contract-v1",
            withExtension: "json"
        ))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try #require(formatter.date(from: value))
    }

    private func lcg32(_ value: UInt32) -> UInt32 {
        value &* 1_664_525 &+ 1_013_904_223
    }
}
