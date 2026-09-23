import Foundation

struct StatuslineUpdate: Decodable, Equatable {
    let sessionId: String
    let contextUsedPercentage: Double?
    let totalCostUSD: Double?
    /// Present only while the prompt cache is warm; nil means cold or unknown.
    var cacheExpiresAt: Date? = nil
    var cacheRecacheTokens: Int? = nil
    /// Whether the input carried a prompt_cache object at all.
    var hasPromptCache = false
    var transcriptPath: String? = nil

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case contextWindow = "context_window"
        case cost
        case promptCache = "prompt_cache"
        case transcriptPath = "transcript_path"
    }

    private struct PromptCache: Decodable {
        let warm: Bool?
        let expiresAt: Double?
        let recacheTokensIfCold: Int?

        enum CodingKeys: String, CodingKey {
            case warm
            case expiresAt = "expires_at"
            case recacheTokensIfCold = "recache_tokens_if_cold"
        }
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

        transcriptPath = try? container.decodeIfPresent(String.self, forKey: .transcriptPath)

        if let cache = try? container.decodeIfPresent(PromptCache.self, forKey: .promptCache) {
            hasPromptCache = true
            if cache.warm == true, let expiresAt = cache.expiresAt {
                cacheExpiresAt = Date(timeIntervalSince1970: expiresAt)
            }
            cacheRecacheTokens = cache.recacheTokensIfCold
        }
    }
}

struct StatuslineUpdateResult: Equatable {
    var updatedKeys: [String] = []
    var matchedKeys: [String] = []

    var changed: Bool {
        !updatedKeys.isEmpty
    }
}
