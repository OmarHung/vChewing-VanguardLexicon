// (c) 2021 and onwards The vChewing Project (MulanPSL-2.0 License).
// ====================
// This code is released under the SPDX-License-Identifier: `MulanPSL-2.0`.

import Foundation

// MARK: - VCDataBuilder.Unigram

extension VCDataBuilder {
  public final class Unigram: Codable, Hashable, @unchecked Sendable, CustomStringConvertible {
    // MARK: Lifecycle

    public init(
      key: String,
      value: String,
      score: Double,
      count: Int,
      category: Category
    ) {
      self.key = key
      self.value = value
      self.score = score
      self.count = count
      self.type = category
      self.timestamp = VCDataBuilder.Unigram.nextStableSerial()
      self.scoreBias = 0
    }

    /// Internal copy initializer that keeps the stable serial (timestamp) of the source,
    /// so derived copies retain the original tie-breaking order during serialization.
    private init(
      copying source: Unigram,
      count: Int,
      scoreBias: Double
    ) {
      self.key = source.key
      self.value = source.value
      self.score = source.score
      self.count = count
      self.type = source.type
      self.timestamp = source.timestamp
      self.scoreBias = scoreBias
    }

    public required init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.key = try container.decode(String.self, forKey: .key)
      self.value = try container.decode(String.self, forKey: .value)
      self.score = try container.decode(Double.self, forKey: .score)
      self.count = try container.decode(Int.self, forKey: .count)
      self.type = try container.decode(Category.self, forKey: .category)
      self.timestamp = try container.decodeIfPresent(Double.self, forKey: .timestamp)
        ?? VCDataBuilder.Unigram.nextStableSerial()
      self.scoreBias = try container.decodeIfPresent(Double.self, forKey: .scoreBias) ?? 0
    }

    // MARK: Public

    public typealias GramSet = Set<VCDataBuilder.Unigram>

    public enum Category: String, Codable, CaseIterable, Sendable {
      case macv = "MACV"
      case tabe = "TABE"
      case moe = "MOED"
      case custom = "CUST"
      case misc = "MISC"
      case kanji = "KANJ"
      case bpmf = "BPMF"
      case cns = "CNS"
      case gbex = "GBEX"

      // MARK: Internal

      var description: String { rawValue }
    }

    public static let naturalE: Double = exp(1.0)

    public let key: String
    public let value: String
    public private(set) var score: Double = -1.0
    public let count: Int
    public let type: Category
    public let timestamp: Double
    /// Additive log10 offset applied by `weighten(norm:)` before rounding.
    /// Always 0 unless a derived-frequency mode (see `CharFrequencyMode`) assigns one.
    public let scoreBias: Double

    public var keyValueHash: Int {
      "\(key)\t\(value)".hashValue
    }

    public var normDelta: Double? {
      switch type {
      case .macv: break
      case .tabe: break
      case .moe: break
      case .kanji: break
      case .bpmf: break
      case .custom: return nil
      case .misc: return nil
      case .cns: return nil
      case .gbex: return nil
      }
      guard (1 ... 6).contains(keyCells.count) else { return nil }
      return Self.naturalE ** (Double(value.count) / 3.0 - 1.0) * Double(count)
    }

    public var description: String {
      "(\(key), \(value), \(score), \(type)"
    }

    public var keyCells: [String] {
      guard key.last != "-" else { return [key] }
      return key.split(separator: "-").map(\.description)
    }

    public var spanLength: Int {
      keyCells.count
    }

    public static func == (lhs: Unigram, rhs: Unigram) -> Bool {
      lhs.hashValue == rhs.hashValue
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(key)
      hasher.combine(value)
      hasher.combine(score)
      hasher.combine(count)
      hasher.combine(type)
      hasher.combine(timestamp)
    }

    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(key, forKey: .key)
      try container.encode(value, forKey: .value)
      try container.encode(score, forKey: .score)
      try container.encode(count, forKey: .count)
      try container.encode(type, forKey: .category)
      try container.encode(timestamp, forKey: .timestamp)
      if scoreBias != 0 {
        try container.encode(scoreBias, forKey: .scoreBias)
      }
    }

    public func weighten(norm: Double) {
      var weight: Double = 0
      switch count {
      case -2: // 拗音假名
        weight = -13
      case -1: // 單個假名
        weight = -13
      case 0: // 墊底低頻漢字與詞語
        weight = log10(
          Self.naturalE ** (Double(value.count) / 3.0 - 1.0) * 0.25 / norm
        )
      default:
        weight = log10(
          Self.naturalE ** (Double(value.count) / 3.0 - 1.0) * Double(count) / norm
        )
      }
      if count >= 0 {
        weight += scoreBias
      }
      let weightRounded: Double = weight.rounded(toPlaces: 3) // 為了節省生成的檔案體積，僅保留小數點後三位。
      score = weightRounded
    }

    // MARK: Internal

    /// Returns a copy with a different raw count and score bias (key, value, category and
    /// stable serial are kept). The returned unigram still needs `weighten(norm:)`.
    func replacing(count newCount: Int, scoreBias newScoreBias: Double = 0) -> Unigram {
      Unigram(copying: self, count: newCount, scoreBias: newScoreBias)
    }

    static func sortForSerialization(_ lhs: VCDataBuilder.Unigram, _ rhs: VCDataBuilder.Unigram)
      -> Bool {
      let lhsKey = lhs.key.asEncryptedBopomofoKeyChain
      let rhsKey = rhs.key.asEncryptedBopomofoKeyChain
      if lhsKey != rhsKey {
        return lhsKey < rhsKey
      }
      if lhs.score != rhs.score {
        return lhs.score > rhs.score
      }
      if lhs.timestamp != rhs.timestamp {
        return lhs.timestamp < rhs.timestamp
      }
      if lhs.value != rhs.value {
        return lhs.value < rhs.value
      }
      if lhs.type != rhs.type {
        return lhs.type.description < rhs.type.description
      }
      return lhs.count > rhs.count
    }

    // MARK: Private

    private enum CodingKeys: String, CodingKey {
      case key = "k"
      case value = "v"
      case score = "s"
      case count = "c"
      case category = "t"
      case timestamp = "d"
      case scoreBias = "b"
    }

    private static let stableSerialLock = NSLock()
    nonisolated(unsafe) private static var stableSerialCursor: Double = 0

    private static func nextStableSerial() -> Double {
      stableSerialLock.lock()
      defer { stableSerialLock.unlock() }
      let result = stableSerialCursor
      stableSerialCursor += 1
      return result
    }
  }
}
