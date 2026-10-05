// (c) 2021 and onwards The vChewing Project (MulanPSL-2.0 License).
// ====================
// This code is released under the SPDX-License-Identifier: `MulanPSL-2.0`.

import Foundation

// MARK: - VCDataBuilder.CharFrequencyMode

extension VCDataBuilder {
  /// How single-character (`.kanji`) unigram counts are adjusted with frequencies derived
  /// from the phrase tables. See `ValueAdds/Specs/CharFrequencyFromPhrases.md`.
  ///
  /// Selected with the `VC_CHARFREQ_MODE` environment variable (`off|replace|blend|shift`).
  /// Unknown or missing values fall back to `defaultMode`.
  public enum CharFrequencyMode: String, CaseIterable, Sendable {
    /// Keep the counts from `char-kanji-core.txt` unchanged.
    case off
    /// `count' = k · derived`, where `k` rescales the derived counts so that the adjusted
    /// characters keep their original total mass (and therefore the global norm).
    case replace
    /// `count' = original^(1−λ) · (k · derived)^λ` (geometric blend, λ = `VC_CHARFREQ_LAMBDA`).
    case blend
    /// Keep the original count and add `γ · (log10(1 + derived) − M)` to the final score,
    /// where `M` is the median of `log10(1 + derived)` over adjusted characters with a
    /// non-zero original count (γ = `VC_CHARFREQ_GAMMA`).
    case shift

    // MARK: Public

    public static let defaultMode: Self = .off
    public static let defaultLambda: Double = 0.5
    public static let defaultGamma: Double = 0.5

    public static var current: Self {
      environmentValue(for: "VC_CHARFREQ_MODE").flatMap { Self(rawValue: $0.lowercased()) }
        ?? defaultMode
    }

    public static var lambda: Double {
      environmentValue(for: "VC_CHARFREQ_LAMBDA").flatMap(Double.init) ?? defaultLambda
    }

    public static var gamma: Double {
      environmentValue(for: "VC_CHARFREQ_GAMMA").flatMap(Double.init) ?? defaultGamma
    }

    // MARK: Private

    private static func environmentValue(for key: String) -> String? {
      let raw = ProcessInfo.processInfo.environment[key]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard let raw, !raw.isEmpty else { return nil }
      return raw
    }
  }
}

// MARK: - VCDataBuilder.CharFrequencyDeriver

extension VCDataBuilder {
  /// Derives a per-(character, reading) frequency from the phrase tables and applies it to
  /// the `.kanji` unigrams of one script (CHS or CHT).
  ///
  /// For every phrase entry of the included categories, the phrase count is added to each
  /// of its (character, reading) positions. A (phrase, reading) pair listed by more than one
  /// table is counted once, with its largest count. The character's own count from
  /// `char-kanji-core.txt` is added once on top.
  ///
  /// Only `.kanji` unigrams with a non-negative count and a non-zero phrase-derived count are
  /// touched; kana (counts −1/−2), BPMF symbols, CNS, GBEX, misc entries and all phrases are
  /// left unchanged. The global norm is not modified.
  enum CharFrequencyDeriver {
    // MARK: Internal

    /// Phrase categories that contribute to the derived frequency. Custom tables
    /// (`phrases-custom-*`, including game-specific ones) are excluded on purpose.
    static let contributingCategories: [Unigram.Category] = [.moe, .tabe, .macv]

    static func apply(
      mode: CharFrequencyMode,
      kanjiTable: inout [Unigram.Category: [String: Unigram.GramSet]],
      phraseTable: [Unigram.Category: [String: Unigram.GramSet]],
      lambda: Double = CharFrequencyMode.lambda,
      gamma: Double = CharFrequencyMode.gamma
    ) {
      guard mode != .off, let kanjiByReading = kanjiTable[.kanji] else { return }
      let derivedFromPhrases = derivedCounts(from: phraseTable)

      // Pass 1: collect deterministic aggregates (integer sums, sorted median).
      var sumOriginal = 0
      var sumDerived = 0
      var logsForMedian = [Double]()
      for (reading, grams) in kanjiByReading {
        for gram in grams {
          guard gram.count >= 0 else { continue }
          let fromPhrases = derivedFromPhrases[reading]?[gram.value] ?? 0
          guard fromPhrases > 0 else { continue }
          let derived = fromPhrases + gram.count
          sumOriginal += gram.count
          sumDerived += derived
          if gram.count > 0 {
            logsForMedian.append(log10(1.0 + Double(derived)))
          }
        }
      }
      guard sumDerived > 0 else { return }
      let scale = Double(sumOriginal) / Double(sumDerived)
      let medianLog = median(of: logsForMedian)

      // Pass 2: replace the affected unigrams with adjusted copies.
      var adjusted = [String: Unigram.GramSet]()
      adjusted.reserveCapacity(kanjiByReading.count)
      for (reading, grams) in kanjiByReading {
        var newSet = Unigram.GramSet()
        newSet.reserveCapacity(grams.count)
        for gram in grams {
          let fromPhrases = derivedFromPhrases[reading]?[gram.value] ?? 0
          guard gram.count >= 0, fromPhrases > 0 else {
            newSet.insert(gram)
            continue
          }
          let derived = Double(fromPhrases + gram.count)
          let newGram: Unigram
          switch mode {
          case .off:
            newGram = gram
          case .replace:
            newGram = gram.replacing(count: roundedCount(scale * derived))
          case .blend:
            guard gram.count > 0 else {
              newGram = gram
              break
            }
            let blended = pow(Double(gram.count), 1 - lambda) * pow(scale * derived, lambda)
            newGram = gram.replacing(count: roundedCount(blended))
          case .shift:
            let bias = gamma * (log10(1.0 + derived) - medianLog)
            newGram = gram.replacing(count: gram.count, scoreBias: bias)
          }
          newSet.insert(newGram)
        }
        adjusted[reading] = newSet
      }
      kanjiTable[.kanji] = adjusted
    }

    /// Returns `[reading: [character: summed phrase count]]`.
    static func derivedCounts(
      from phraseTable: [Unigram.Category: [String: Unigram.GramSet]]
    )
      -> [String: [String: Int]] {
      // Deduplicate (phrase, reading) pairs across tables, keeping the largest count.
      var bestCounts = [String: [String: Int]]() // reading chain -> phrase -> count
      for category in contributingCategories {
        guard let byReading = phraseTable[category] else { continue }
        for (readingChain, grams) in byReading {
          for gram in grams where gram.count > 0 {
            let existing = bestCounts[readingChain]?[gram.value] ?? 0
            if gram.count > existing {
              bestCounts[readingChain, default: [:]][gram.value] = gram.count
            }
          }
        }
      }
      var result = [String: [String: Int]]()
      for (readingChain, phrases) in bestCounts {
        let readings = readingChain.split(separator: "-").map(String.init)
        for (phrase, count) in phrases {
          let chars = phrase.map(String.init)
          guard chars.count == readings.count else { continue }
          for (char, reading) in zip(chars, readings) {
            result[reading, default: [:]][char, default: 0] += count
          }
        }
      }
      return result
    }

    // MARK: Private

    private static func roundedCount(_ value: Double) -> Int {
      max(1, Int(value.rounded()))
    }

    private static func median(of values: [Double]) -> Double {
      guard !values.isEmpty else { return 0 }
      let sorted = values.sorted()
      let mid = sorted.count / 2
      if sorted.count.isMultiple(of: 2) {
        return (sorted[mid - 1] + sorted[mid]) / 2
      }
      return sorted[mid]
    }
  }
}
