import Foundation
import Testing
@testable import FSRS

@Suite struct DankiFSRS6ContractV2Tests {
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
            let exactScheduleFields: [String]
        }

        struct ParameterVector: Decodable {
            let name: String
            let inputWeights: [Double]?
            let relearningSteps: [String]
            let enableShortTerm: Bool
            let expectedWeights: [Double]
        }

        struct StepVector: Decodable {
            let input: String
            let expectedMinutes: Int?
            let expectedError: Bool
        }

        struct Operations: Decodable {
            struct PreviewVector: Decodable {
                let before: Snapshot
                let schedulingAt: String
                let outcomes: [Outcome]
            }

            struct RollbackVector: Decodable {
                let before: Snapshot
                let rating: Int
                let schedulingAt: String
                let scheduled: RecordSnapshot
                let expectedPrevious: Snapshot
            }

            struct ForgetVector: Decodable {
                let resetCount: Bool
                let before: Snapshot
                let schedulingAt: String
                let expected: RecordSnapshot
            }

            struct RetrievabilityVector: Decodable {
                let name: String
                let before: Snapshot
                let at: String
                let expectedNumber: Double
                let expectedString: String
            }

            struct CustomStepsVector: Decodable {
                struct StepParameters: Decodable {
                    let learningSteps: [String]
                    let relearningSteps: [String]
                }
                let parameters: StepParameters
                let before: Snapshot
                let schedulingAt: String
                let outcomes: [Outcome]
            }

            struct RescheduleVector: Decodable {
                struct History: Decodable {
                    let rating: Int
                    let stateRaw: Int?
                    let dueAt: String?
                    let stability: Double?
                    let difficulty: Double?
                    let scheduledDays: Double
                    let learningSteps: Int
                    let reviewAt: String
                }
                struct Options: Decodable {
                    let skipManual: Bool
                    let updateMemoryState: Bool
                    let now: String
                }
                let currentCard: Snapshot
                let history: [History]
                let options: Options
                let expectedCollections: [RecordSnapshot]
                let expectedRescheduleItem: RecordSnapshot?
            }

            let preview: PreviewVector
            let rollback: [RollbackVector]
            let forget: [ForgetVector]
            let retrievability: [RetrievabilityVector]
            let fuzz: PreviewVector
            let customSteps: CustomStepsVector
            let reschedule: RescheduleVector
        }

        let schemaVersion: Int
        let contract: String
        let schedulingContract: String
        let referenceEngine: String
        let parameters: Parameters
        let matrix: [MatrixVector]
        let seededSequence: [SeededStep]
        let stressSequence: StressSequence
        let parameterVectors: [ParameterVector]
        let stepVectors: [StepVector]
        let operations: Operations
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

    private struct StressSequence: Decodable {
        let count: Int
        let checkpoints: [StressCheckpoint]
    }

    private struct StressCheckpoint: Decodable {
        let index: Int
        let schedulingAt: String
        let expected: Snapshot
    }

    private struct Outcome: Decodable {
        let rating: Int
        let expected: RecordSnapshot
    }

    private struct Snapshot: Decodable {
        let stateRaw: Int
        let dueAt: String
        let stability: Double
        let difficulty: Double
        let elapsedDays: Double?
        let reps: Int
        let lapses: Int
        let scheduledDays: Double
        let learningSteps: Int
        let lastReviewAt: String?
        let lastRatingRaw: Int
    }

    private struct LogSnapshot: Decodable {
        let ratingRaw: Int
        let stateRaw: Int
        let dueAt: String
        let stability: Double
        let difficulty: Double
        let elapsedDays: Double
        let lastElapsedDays: Double
        let scheduledDays: Double
        let learningSteps: Int
        let reviewAt: String
    }

    private struct RecordSnapshot: Decodable {
        let card: Snapshot
        let log: LogSnapshot
    }

    @Test func metadataAndParameterParity() throws {
        let fixture = try loadFixture()
        #expect(fixture.schemaVersion == 2)
        #expect(fixture.contract == "danki-fsrs-6-v2")
        #expect(fixture.schedulingContract == "fsrs-6/danki-contract-v1")
        #expect(fixture.referenceEngine == "ts-fsrs@5.4.2")
        #expect(fixture.parameters.dayArithmetic == "UTC calendar days")
        #expect(fixture.parameters.exactScheduleFields == [
            "state", "due", "reps", "lapses", "scheduledDays", "learningSteps", "lastReview",
        ])
        #expect(fixture.matrix.count == 96)
        #expect(fixture.seededSequence.count == 200)
        #expect(fixture.stressSequence.count == 10_000)
        #expect(fixture.stressSequence.checkpoints.count == 100)

        for vector in fixture.parameterVectors {
            let actual = FSRSParameters.tsFSRS6Compatible(
                w: vector.inputWeights,
                enableShortTerm: vector.enableShortTerm,
                relearningSteps: vector.relearningSteps
            )
            #expect(actual.w == vector.expectedWeights, Comment(rawValue: vector.name))
        }

        for vector in fixture.stepVectors {
            if vector.expectedError {
                #expect(throws: FSRSError.self) {
                    _ = try convertStepUnitToMinutes(vector.input)
                }
            } else {
                #expect(try convertStepUnitToMinutes(vector.input) == vector.expectedMinutes)
            }
        }
    }

    @Test func canonicalTransitionMatrixMatchesTSFSRS542() throws {
        let fixture = try loadFixture()
        let scheduler = makeScheduler(fixture.parameters)
        for vector in fixture.matrix {
            let actual = try scheduler.next(
                card: card(vector.before),
                now: date(vector.schedulingAt),
                grade: rating(vector.rating)
            )
            try expect(actual.card, matches: vector.expected, context: "\(vector.state)/\(vector.scenario)/\(vector.rating)")
        }
    }

    @Test func previewLogsRollbackForgetAndRetrievabilityMatch() throws {
        let fixture = try loadFixture()
        let scheduler = makeScheduler(fixture.parameters)
        let previewVector = fixture.operations.preview
        let preview = try scheduler.repeat(
            card: card(previewVector.before),
            now: date(previewVector.schedulingAt)
        )
        for outcome in previewVector.outcomes {
            try expect(
                #require(preview[rating(outcome.rating)]),
                matches: outcome.expected,
                context: "preview/\(outcome.rating)"
            )
        }

        for vector in fixture.operations.rollback {
            let scheduled = try scheduler.next(
                card: card(vector.before),
                now: date(vector.schedulingAt),
                grade: rating(vector.rating)
            )
            try expect(scheduled, matches: vector.scheduled, context: "rollback/scheduled/\(vector.rating)")
            let previous = try scheduler.rollback(card: scheduled.card, log: scheduled.log)
            try expect(previous, matches: vector.expectedPrevious, context: "rollback/previous/\(vector.rating)")
        }

        for vector in fixture.operations.forget {
            let actual = scheduler.forget(
                card: try card(vector.before),
                now: try date(vector.schedulingAt),
                resetCount: vector.resetCount
            )
            try expect(actual, matches: vector.expected, context: "forget/\(vector.resetCount)")
        }

        for vector in fixture.operations.retrievability {
            let actual = scheduler.getRetrievability(
                card: try card(vector.before),
                now: try date(vector.at)
            )
            #expect(abs(actual.number - vector.expectedNumber) < 1e-12, Comment(rawValue: vector.name))
            #expect(actual.string == vector.expectedString, Comment(rawValue: vector.name))
        }
    }

    @Test func seededFuzzCustomStepsAndManualHistoryMatch() throws {
        let fixture = try loadFixture()
        let fuzzVector = fixture.operations.fuzz
        let fuzzScheduler = FSRS(parameters: .tsFSRS6Compatible(
            requestRetention: fixture.parameters.requestRetention,
            maximumInterval: fixture.parameters.maximumIntervalDays,
            w: fixture.parameters.weights,
            enableFuzz: true,
            enableShortTerm: fixture.parameters.enableShortTerm,
            learningSteps: fixture.parameters.learningSteps,
            relearningSteps: fixture.parameters.relearningSteps
        ))
        for outcome in fuzzVector.outcomes {
            let actual = try fuzzScheduler.next(
                card: card(fuzzVector.before),
                now: date(fuzzVector.schedulingAt),
                grade: rating(outcome.rating)
            )
            try expect(actual, matches: outcome.expected, context: "fuzz/\(outcome.rating)")
        }

        let custom = fixture.operations.customSteps
        let customScheduler = FSRS(parameters: .tsFSRS6Compatible(
            requestRetention: fixture.parameters.requestRetention,
            maximumInterval: fixture.parameters.maximumIntervalDays,
            w: fixture.parameters.weights,
            enableFuzz: false,
            enableShortTerm: true,
            learningSteps: custom.parameters.learningSteps,
            relearningSteps: custom.parameters.relearningSteps
        ))
        let customPreview = try customScheduler.repeat(
            card: card(custom.before),
            now: date(custom.schedulingAt)
        )
        for outcome in custom.outcomes {
            try expect(
                #require(customPreview[rating(outcome.rating)]),
                matches: outcome.expected,
                context: "custom/\(outcome.rating)"
            )
        }

        let reschedule = fixture.operations.reschedule
        let history = try reschedule.history.map { entry in
            ReviewLog(
                rating: try rating(entry.rating, allowManual: true),
                state: try entry.stateRaw.map { try #require(CardState(rawValue: $0)) },
                due: try entry.dueAt.map(date),
                stability: entry.stability,
                difficulty: entry.difficulty,
                scheduledDays: entry.scheduledDays,
                learningSteps: entry.learningSteps,
                review: try date(entry.reviewAt)
            )
        }
        let currentCard = try card(reschedule.currentCard)
        let actual = try makeScheduler(fixture.parameters).reschedule(
            currentCard: currentCard,
            reviews: history,
            options: RescheduleOptions(
                skipManual: reschedule.options.skipManual,
                updateMemoryState: reschedule.options.updateMemoryState,
                now: date(reschedule.options.now),
                firstCard: currentCard
            )
        )
        #expect(actual.collections.count == reschedule.expectedCollections.count)
        for (index, expected) in reschedule.expectedCollections.enumerated() {
            try expect(#require(actual.collections[index]), matches: expected, context: "reschedule/\(index)")
        }
        if let expected = reschedule.expectedRescheduleItem {
            try expect(#require(actual.rescheduleItem), matches: expected, context: "reschedule/item")
        } else {
            #expect(actual.rescheduleItem == nil)
        }
    }

    private func makeScheduler(_ parameters: Fixture.Parameters) -> FSRS {
        FSRS(parameters: .tsFSRS6Compatible(
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
            elapsedDays: snapshot.elapsedDays ?? 0,
            scheduledDays: snapshot.scheduledDays,
            learningSteps: snapshot.learningSteps,
            reps: snapshot.reps,
            lapses: snapshot.lapses,
            state: try #require(CardState(rawValue: snapshot.stateRaw)),
            lastReview: try snapshot.lastReviewAt.map(date)
        )
    }

    private func rating(_ raw: Int, allowManual: Bool = false) throws -> Rating {
        let value = try #require(Rating(rawValue: raw))
        if !allowManual { #expect(value != .manual) }
        return value
    }

    private func expect(
        _ actual: RecordLogItem,
        matches expected: RecordSnapshot,
        context: String
    ) throws {
        try expect(actual.card, matches: expected.card, context: "\(context)/card")
        try expect(actual.log, matches: expected.log, context: "\(context)/log")
    }

    private func expect(_ actual: Card, matches expected: Snapshot, context: String) throws {
        #expect(actual.state.rawValue == expected.stateRaw, Comment(rawValue: context))
        #expect(abs(actual.due.timeIntervalSince(try date(expected.dueAt))) < 0.001, Comment(rawValue: context))
        #expect(abs(actual.stability - expected.stability) < 1e-8, Comment(rawValue: context))
        #expect(abs(actual.difficulty - expected.difficulty) < 1e-8, Comment(rawValue: context))
        #expect(actual.reps == expected.reps, Comment(rawValue: context))
        #expect(actual.lapses == expected.lapses, Comment(rawValue: context))
        #expect(abs(actual.scheduledDays - expected.scheduledDays) < 1e-8, Comment(rawValue: context))
        #expect(actual.learningSteps == expected.learningSteps, Comment(rawValue: context))
        if let expectedLastReview = expected.lastReviewAt {
            #expect(abs(try #require(actual.lastReview).timeIntervalSince(date(expectedLastReview))) < 0.001, Comment(rawValue: context))
        } else {
            #expect(actual.lastReview == nil, Comment(rawValue: context))
        }
    }

    private func expect(_ actual: ReviewLog, matches expected: LogSnapshot, context: String) throws {
        #expect(actual.rating.rawValue == expected.ratingRaw, Comment(rawValue: context))
        #expect(try #require(actual.state).rawValue == expected.stateRaw, Comment(rawValue: context))
        #expect(abs(try #require(actual.due).timeIntervalSince(date(expected.dueAt))) < 0.001, Comment(rawValue: context))
        #expect(abs(try #require(actual.stability) - expected.stability) < 1e-8, Comment(rawValue: context))
        #expect(abs(try #require(actual.difficulty) - expected.difficulty) < 1e-8, Comment(rawValue: context))
        #expect(abs(actual.elapsedDays - expected.elapsedDays) < 1e-8, Comment(rawValue: context))
        #expect(abs(actual.lastElapsedDays - expected.lastElapsedDays) < 1e-8, Comment(rawValue: context))
        #expect(abs(actual.scheduledDays - expected.scheduledDays) < 1e-8, Comment(rawValue: context))
        #expect(actual.learningSteps == expected.learningSteps, Comment(rawValue: context))
        #expect(abs(actual.review.timeIntervalSince(try date(expected.reviewAt))) < 0.001, Comment(rawValue: context))
    }

    private func loadFixture() throws -> Fixture {
        let url = try #require(Bundle.module.url(
            forResource: "danki-fsrs6-contract-v2",
            withExtension: "json",
            subdirectory: "Fixtures"
        ) ?? Bundle.module.url(
            forResource: "danki-fsrs6-contract-v2",
            withExtension: "json"
        ))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try #require(formatter.date(from: value))
    }
}
