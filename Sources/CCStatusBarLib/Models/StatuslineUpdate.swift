import Foundation

struct StatuslineUpdate: Decodable, Equatable {
    let sessionId: String
    let contextUsedPercentage: Double?
    let totalCostUSD: Double?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case contextWindow = "context_window"
        case cost
    }

    private struct ContextWindow: Decodable {
        let usedPercentage: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
        }
    }

    private struct Cost: Decodable {
        let totalCostUSD: Double?

        enum CodingKeys: String, CodingKey {
            case totalCostUSD = "total_cost_usd"
        }
    }

    init(sessionId: String, contextUsedPercentage: Double? = nil, totalCostUSD: Double? = nil) {
        self.sessionId = sessionId
        self.contextUsedPercentage = contextUsedPercentage
        self.totalCostUSD = totalCostUSD
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)

        contextUsedPercentage = try container
            .decodeIfPresent(ContextWindow.self, forKey: .contextWindow)?
            .usedPercentage
        totalCostUSD = try container
            .decodeIfPresent(Cost.self, forKey: .cost)?
            .totalCostUSD
    }
}

struct StatuslineUpdateResult: Equatable {
    var updatedKeys: [String] = []
    var matchedKeys: [String] = []

    var changed: Bool {
        !updatedKeys.isEmpty
    }
}
