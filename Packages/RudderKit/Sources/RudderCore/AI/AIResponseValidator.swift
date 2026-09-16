import Foundation

public enum AIValidationIssue: Hashable, Sendable, CustomStringConvertible {
    case unsupportedSchemaVersion(Int)
    case unknownDecisionStatus(String)
    case unknownCategory(String)
    case unknownComplexity(String)
    case unknownResearchLevel(String)
    case unknownRiskSeverity(String)
    case unknownQuestionKind(String)
    case emptyUnderstanding
    case noOptions
    case duplicateOptionID(String)
    case duplicateCriterionID(String)
    case optionMissingName(String)
    case criterionMissingName(String)
    case scoreOutOfRange(option: String, criterion: String, value: Double)
    case scoreForUnknownCriterion(option: String, criterion: String)
    case missingScore(option: String, criterion: String)
    case weightsUnusable
    case recommendationMissing
    case recommendationForUnknownOption(String)
    case recommendationForEliminatedOption(String)
    case recommendationWithoutReasons
    case insecureSourceURL(String)
    case malformedSourceURL(String)
    case malformedTimestamp(String)
    case questionImpactOutOfRange(String)
    case overlongText(field: String, length: Int)
    case allOptionsEliminated

    /// Repairable issues are fixed silently; unrepairable ones force a retry or a fallback.
    public var isFatal: Bool {
        switch self {
        case .unsupportedSchemaVersion, .unknownDecisionStatus, .unknownCategory,
             .unknownComplexity, .noOptions, .emptyUnderstanding,
             .recommendationForUnknownOption, .allOptionsEliminated:
            return true
        default:
            return false
        }
    }

    public var description: String {
        switch self {
        case .unsupportedSchemaVersion(let v): return "unsupported schema version \(v)"
        case .unknownDecisionStatus(let v): return "unknown decisionStatus '\(v)'"
        case .unknownCategory(let v): return "unknown category '\(v)'"
        case .unknownComplexity(let v): return "unknown complexity '\(v)'"
        case .unknownResearchLevel(let v): return "unknown research level '\(v)'"
        case .unknownRiskSeverity(let v): return "unknown risk severity '\(v)'"
        case .unknownQuestionKind(let v): return "unknown question kind '\(v)'"
        case .emptyUnderstanding: return "understanding.restatement is empty"
        case .noOptions: return "no options"
        case .duplicateOptionID(let id): return "duplicate option id '\(id)'"
        case .duplicateCriterionID(let id): return "duplicate criterion id '\(id)'"
        case .optionMissingName(let id): return "option '\(id)' has no name"
        case .criterionMissingName(let id): return "criterion '\(id)' has no name"
        case .scoreOutOfRange(let o, let c, let v): return "score \(v) out of range for \(o)/\(c)"
        case .scoreForUnknownCriterion(let o, let c): return "option '\(o)' scores unknown criterion '\(c)'"
        case .missingScore(let o, let c): return "option '\(o)' has no score for criterion '\(c)'"
        case .weightsUnusable: return "criteria weights are unusable"
        case .recommendationMissing: return "no recommendation"
        case .recommendationForUnknownOption(let id): return "recommendation points at unknown option '\(id)'"
        case .recommendationForEliminatedOption(let id): return "recommendation points at eliminated option '\(id)'"
        case .recommendationWithoutReasons: return "recommendation has no reasons"
        case .insecureSourceURL(let url): return "insecure source url '\(url)'"
        case .malformedSourceURL(let url): return "malformed source url '\(url)'"
        case .malformedTimestamp(let value): return "malformed timestamp '\(value)'"
        case .questionImpactOutOfRange(let id): return "question '\(id)' has an impossible impact"
        case .overlongText(let field, let length): return "\(field) is \(length) characters"
        case .allOptionsEliminated: return "every option was eliminated"
        }
    }
}

public enum AIValidationError: Error, Sendable {
    case unrepairable([AIValidationIssue])
}

/// A response that has been checked and, where safely possible, repaired.
public struct ValidatedAIResponse: Sendable {
    public let status: ReadinessState
    public let category: DecisionCategory
    public let complexity: DecisionComplexity
    public let understanding: DecisionUnderstanding
    public let preliminaryOptionID: String?
    public let preliminaryRationale: String?
    public let questions: [QuestionCandidate]
    public let researchLevel: ResearchLevel
    public let researchTopics: [String]
    public let criteria: [Criterion]
    public let options: [DecisionOption]
    public let recommendedOptionID: String?
    public let headline: String
    public let reasons: [RecommendationReason]
    public let tradeOffs: [TradeOff]
    public let risks: [Risk]
    public let assumptions: [Assumption]
    public let research: [ResearchFinding]
    public let conflicts: [InformationConflict]
    public let counterpoints: [String]
    /// Non-fatal problems that were repaired. Useful for logging, never shown raw to the user.
    public let repairedIssues: [AIValidationIssue]
}

/// Validates and repairs whatever the backend returned before any of it reaches the UI.
///
/// Nothing here can throw its way into a crash: the worst case is a thrown
/// `AIValidationError` that the caller turns into a retry or a user-facing message.
public enum AIResponseValidator {

    public static let maximumTextLength = 2_000

    public static func validate(_ response: AIDecisionResponse, now: Date = Date()) throws -> ValidatedAIResponse {
        var issues: [AIValidationIssue] = []

        guard response.schemaVersion == AIDecisionResponse.currentSchemaVersion else {
            throw AIValidationError.unrepairable([.unsupportedSchemaVersion(response.schemaVersion)])
        }

        guard let status = ReadinessState(rawValue: response.decisionStatus) else {
            throw AIValidationError.unrepairable([.unknownDecisionStatus(response.decisionStatus)])
        }
        guard let category = DecisionCategory(rawValue: response.category) else {
            throw AIValidationError.unrepairable([.unknownCategory(response.category)])
        }
        guard let complexity = DecisionComplexity(rawValue: response.complexity) else {
            throw AIValidationError.unrepairable([.unknownComplexity(response.complexity)])
        }

        let restatement = response.understanding.restatement.trimmed
        guard !restatement.isEmpty else {
            throw AIValidationError.unrepairable([.emptyUnderstanding])
        }

        // --- Criteria -------------------------------------------------------
        var seenCriterionIDs = Set<String>()
        var criteria: [Criterion] = []
        for dto in response.criteria {
            let id = dto.id.trimmed
            guard !id.isEmpty else { continue }
            guard !seenCriterionIDs.contains(id) else {
                issues.append(.duplicateCriterionID(id))
                continue
            }
            let name = dto.name.trimmed
            guard !name.isEmpty else {
                issues.append(.criterionMissingName(id))
                continue
            }
            seenCriterionIDs.insert(id)
            criteria.append(
                Criterion(
                    id: id,
                    name: name.truncated(to: 120),
                    weight: dto.weight.isFinite ? max(0, dto.weight) : 0,
                    rationale: dto.rationale?.trimmed.truncated(to: maximumTextLength)
                )
            )
        }

        if !criteria.isEmpty && criteria.allSatisfy({ $0.weight == 0 }) {
            // Repairable: treat every criterion as equally important.
            issues.append(.weightsUnusable)
            criteria = criteria.map { Criterion(id: $0.id, name: $0.name, weight: 1, rationale: $0.rationale) }
        }

        // --- Options --------------------------------------------------------
        var seenOptionIDs = Set<String>()
        var options: [DecisionOption] = []
        for dto in response.options {
            let id = dto.id.trimmed
            guard !id.isEmpty else { continue }
            guard !seenOptionIDs.contains(id) else {
                issues.append(.duplicateOptionID(id))
                continue
            }
            let name = dto.name.trimmed
            guard !name.isEmpty else {
                issues.append(.optionMissingName(id))
                continue
            }
            seenOptionIDs.insert(id)

            var scores: [String: Double] = [:]
            for (criterionID, rawValue) in dto.scores {
                guard seenCriterionIDs.contains(criterionID) else {
                    issues.append(.scoreForUnknownCriterion(option: id, criterion: criterionID))
                    continue
                }
                guard rawValue.isFinite else {
                    issues.append(.scoreOutOfRange(option: id, criterion: criterionID, value: rawValue))
                    continue
                }
                if rawValue < 0 || rawValue > 1 {
                    issues.append(.scoreOutOfRange(option: id, criterion: criterionID, value: rawValue))
                }
                scores[criterionID] = min(max(rawValue, 0), 1)
            }
            for criterion in criteria where scores[criterion.id] == nil {
                // Unknown performance becomes an explicit "no information" mid-point.
                issues.append(.missingScore(option: id, criterion: criterion.id))
                scores[criterion.id] = 0.5
            }

            options.append(
                DecisionOption(
                    id: id,
                    name: name.truncated(to: 120),
                    summary: dto.summary?.trimmed.truncated(to: maximumTextLength),
                    scores: scores,
                    failedConstraints: dto.failedConstraints.compactMap {
                        let value = $0.trimmed
                        return value.isEmpty ? nil : value.truncated(to: 200)
                    }
                )
            )
        }

        let needsOptions = (status == .ready)
        if options.isEmpty && needsOptions {
            throw AIValidationError.unrepairable([.noOptions])
        }
        if !options.isEmpty && options.allSatisfy(\.isEliminated) && needsOptions {
            throw AIValidationError.unrepairable([.allOptionsEliminated])
        }

        // --- Recommendation -------------------------------------------------
        var recommendedOptionID: String?
        var headline = ""
        var reasons: [RecommendationReason] = []

        if let dto = response.recommendation {
            let optionID = dto.optionId.trimmed
            if !seenOptionIDs.contains(optionID) {
                if needsOptions {
                    throw AIValidationError.unrepairable([.recommendationForUnknownOption(optionID)])
                }
                issues.append(.recommendationForUnknownOption(optionID))
            } else if options.first(where: { $0.id == optionID })?.isEliminated == true {
                // Never recommend something the user's own constraints rule out.
                issues.append(.recommendationForEliminatedOption(optionID))
            } else {
                recommendedOptionID = optionID
                headline = dto.headline.trimmed.truncated(to: 200)
                reasons = dto.reasons.compactMap { reason in
                    let title = reason.title.trimmed
                    guard !title.isEmpty else { return nil }
                    return RecommendationReason(
                        title: title.truncated(to: 140),
                        detail: reason.detail.trimmed.truncated(to: maximumTextLength)
                    )
                }
                if reasons.isEmpty { issues.append(.recommendationWithoutReasons) }
            }
        } else if status == .ready {
            issues.append(.recommendationMissing)
        }

        // --- Questions ------------------------------------------------------
        var questions: [QuestionCandidate] = []
        for dto in response.requiredQuestions {
            let text = dto.text.trimmed
            guard !text.isEmpty else { continue }
            let kind = QuestionKind(rawValue: dto.kind) ?? {
                issues.append(.unknownQuestionKind(dto.kind))
                return .freeText
            }()
            if !dto.expectedImpact.isFinite || dto.expectedImpact < 0 || dto.expectedImpact > 1 {
                issues.append(.questionImpactOutOfRange(dto.id))
            }
            questions.append(
                QuestionCandidate(
                    id: dto.id.trimmed.isEmpty ? UUID().uuidString : dto.id.trimmed,
                    text: text.truncated(to: 300),
                    kind: kind,
                    choices: dto.choices.compactMap {
                        let value = $0.trimmed
                        return value.isEmpty ? nil : value.truncated(to: 120)
                    },
                    expectedImpact: dto.expectedImpact.isFinite ? dto.expectedImpact : 0,
                    friction: dto.friction.isFinite ? dto.friction : 0.25,
                    answerableByResearch: dto.answerableByResearch,
                    knowledgeKey: dto.knowledgeKey?.trimmed
                )
            )
        }

        // --- Research -------------------------------------------------------
        let researchLevel: ResearchLevel
        if let level = ResearchLevel(rawValue: response.researchNeeded.level) {
            researchLevel = level
        } else {
            issues.append(.unknownResearchLevel(response.researchNeeded.level))
            researchLevel = .none
        }

        var research: [ResearchFinding] = []
        for dto in response.research {
            let claim = dto.claim.trimmed
            guard !claim.isEmpty else { continue }

            var url: URL?
            if let raw = dto.sourceUrl?.trimmed, !raw.isEmpty {
                if let parsed = URL(string: raw), let scheme = parsed.scheme?.lowercased(), parsed.host != nil {
                    if scheme == "https" {
                        url = parsed
                    } else {
                        // A source we cannot fetch securely is not a source we will link.
                        issues.append(.insecureSourceURL(raw))
                    }
                } else {
                    issues.append(.malformedSourceURL(raw))
                }
            }

            var retrievedAt: Date?
            if let raw = dto.retrievedAt?.trimmed, !raw.isEmpty {
                if let parsed = ISO8601Parsing.date(from: raw) {
                    retrievedAt = parsed
                } else {
                    issues.append(.malformedTimestamp(raw))
                }
            }

            research.append(
                ResearchFinding(
                    claim: claim.truncated(to: maximumTextLength),
                    sourceTitle: dto.sourceTitle?.trimmed.truncated(to: 200),
                    sourceURL: url,
                    retrievedAt: retrievedAt,
                    // A claim is only "verified" if it survived validation *and* the model said so.
                    unverified: !dto.verified || url == nil
                )
            )
        }

        // --- Everything else -------------------------------------------------
        let risks: [Risk] = response.risks.compactMap { dto in
            let title = dto.title.trimmed
            guard !title.isEmpty else { return nil }
            let severity = RiskSeverity(rawValue: dto.severity) ?? {
                issues.append(.unknownRiskSeverity(dto.severity))
                return .medium
            }()
            return Risk(
                title: title.truncated(to: 140),
                detail: dto.detail.trimmed.truncated(to: maximumTextLength),
                severity: severity
            )
        }

        let assumptions: [Assumption] = response.assumptions.compactMap { dto in
            let statement = dto.statement.trimmed
            guard !statement.isEmpty else { return nil }
            return Assumption(
                statement: statement.truncated(to: maximumTextLength),
                impactIfWrong: dto.impactIfWrong.trimmed.truncated(to: maximumTextLength)
            )
        }

        let tradeOffs: [TradeOff] = response.tradeoffs.compactMap { dto in
            let gaining = dto.gaining.trimmed
            let givingUp = dto.givingUp.trimmed
            guard !gaining.isEmpty, !givingUp.isEmpty else { return nil }
            return TradeOff(gaining: gaining.truncated(to: 200), givingUp: givingUp.truncated(to: 200))
        }

        let conflicts: [InformationConflict] = response.conflicts.compactMap { dto in
            let topic = dto.topic.trimmed
            guard !topic.isEmpty else { return nil }
            return InformationConflict(
                topic: topic.truncated(to: 200),
                detail: dto.detail.trimmed.truncated(to: maximumTextLength)
            )
        }

        let fatal = issues.filter(\.isFatal)
        guard fatal.isEmpty else { throw AIValidationError.unrepairable(fatal) }

        return ValidatedAIResponse(
            status: status,
            category: category,
            complexity: complexity,
            understanding: DecisionUnderstanding(
                restatement: restatement.truncated(to: maximumTextLength),
                knownContext: response.understanding.knownContext.cleaned(limit: 12),
                whatMatters: response.understanding.whatMatters.cleaned(limit: 12)
            ),
            preliminaryOptionID: response.preliminaryRecommendation
                .map(\.optionId.trimmed)
                .flatMap { seenOptionIDs.contains($0) ? $0 : nil },
            preliminaryRationale: response.preliminaryRecommendation?.rationale.trimmed.truncated(to: maximumTextLength),
            questions: questions,
            researchLevel: researchLevel,
            researchTopics: response.researchNeeded.topics.cleaned(limit: 10),
            criteria: criteria,
            options: options,
            recommendedOptionID: recommendedOptionID,
            headline: headline,
            reasons: reasons,
            tradeOffs: tradeOffs,
            risks: risks,
            assumptions: assumptions,
            research: research,
            conflicts: conflicts,
            counterpoints: response.whatCouldMakeMeWrong.cleaned(limit: 6),
            repairedIssues: issues
        )
    }
}

/// ISO8601DateFormatter is strict about fractional seconds, so both shapes are tried.
enum ISO8601Parsing {
    nonisolated(unsafe) private static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let lock = NSLock()

    static func date(from string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return withFractionalSeconds.date(from: string) ?? plain.date(from: string)
    }
}
