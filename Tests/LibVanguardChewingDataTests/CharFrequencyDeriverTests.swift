// (c) 2021 and onwards The vChewing Project (MulanPSL-2.0 License).
// ====================
// This code is released under the SPDX-License-Identifier: `MulanPSL-2.0`.

import Foundation
@testable import LibVanguardChewingData
import Testing

private typealias Unigram = VCDataBuilder.Unigram
private typealias GramTable = [Unigram.Category: [String: Unigram.GramSet]]

private func makeTable(_ rows: [(Unigram.Category, String, String, Int)]) -> GramTable {
  var table = GramTable()
  for (category, key, value, count) in rows {
    let gram = Unigram(key: key, value: value, score: 0, count: count, category: category)
    table[category, default: [:]][key, default: []].insert(gram)
  }
  return table
}

private func count(of value: String, at key: String, in table: GramTable) -> Int? {
  table[.kanji]?[key]?.first(where: { $0.value == value })?.count
}

@Test
func testCharFrequencyDerivedCountsSkipCustomAndDeduplicateAcrossTables() {
  let phrases = makeTable([
    (.moe, "ㄗㄞˋ-ㄐㄧㄢˋ", "再見", 100),
    (.tabe, "ㄗㄞˋ-ㄐㄧㄢˋ", "再見", 40), // Same pair in another table: counted once (max).
    (.macv, "ㄒㄧㄢˋ-ㄗㄞˋ", "現在", 30),
    (.custom, "ㄗㄞˋ-ㄒㄧㄢˋ", "在線", 999), // Custom tables never contribute.
    (.moe, "ㄗㄞˋ-ㄒㄧㄢˋ", "在線上", 5), // Length mismatch: ignored.
  ])
  let derived = VCDataBuilder.CharFrequencyDeriver.derivedCounts(from: phrases)
  #expect(derived["ㄗㄞˋ"]?["再"] == 100)
  #expect(derived["ㄐㄧㄢˋ"]?["見"] == 100)
  #expect(derived["ㄗㄞˋ"]?["在"] == 30)
  #expect(derived["ㄒㄧㄢˋ"]?["現"] == 30)
  #expect(derived["ㄒㄧㄢˋ"]?["線"] == nil)
}

@Test
func testCharFrequencyOffModeLeavesKanjiUntouched() {
  var kanji = makeTable([(.kanji, "ㄗㄞˋ", "在", 7138), (.kanji, "ㄗㄞˋ", "再", 7100)])
  let before = kanji
  let phrases = makeTable([(.moe, "ㄗㄞˋ-ㄐㄧㄢˋ", "再見", 100)])
  VCDataBuilder.CharFrequencyDeriver.apply(mode: .off, kanjiTable: &kanji, phraseTable: phrases)
  #expect(kanji == before)
}

@Test
func testCharFrequencyReplaceModePreservesMassAndKeepsUnmatchedEntries() {
  var kanji = makeTable([
    (.kanji, "ㄗㄞˋ", "在", 10),
    (.kanji, "ㄗㄞˋ", "再", 10),
    (.kanji, "ㄗㄞˋ", "載", 7), // No phrase evidence: unchanged.
    (.kanji, "ㄚ", "あ", -1), // Kana: unchanged.
  ])
  let phrases = makeTable([
    (.moe, "ㄒㄧㄢˋ-ㄗㄞˋ", "現在", 290),
    (.moe, "ㄗㄞˋ-ㄐㄧㄢˋ", "再見", 90),
  ])
  VCDataBuilder.CharFrequencyDeriver.apply(mode: .replace, kanjiTable: &kanji, phraseTable: phrases)
  // derived(在) = 300, derived(再) = 100; scale = 20 / 400 = 0.05.
  #expect(count(of: "在", at: "ㄗㄞˋ", in: kanji) == 15)
  #expect(count(of: "再", at: "ㄗㄞˋ", in: kanji) == 5)
  #expect(count(of: "載", at: "ㄗㄞˋ", in: kanji) == 7)
  #expect(count(of: "あ", at: "ㄚ", in: kanji) == -1)
}

@Test
func testCharFrequencyShiftModeAddsCenteredScoreBias() {
  var kanji = makeTable([(.kanji, "ㄗㄞˋ", "在", 9), (.kanji, "ㄗㄞˋ", "再", 9)])
  let phrases = makeTable([
    (.moe, "ㄒㄧㄢˋ-ㄗㄞˋ", "現在", 990),
    (.moe, "ㄗㄞˋ-ㄐㄧㄢˋ", "再見", 90),
  ])
  VCDataBuilder.CharFrequencyDeriver.apply(
    mode: .shift, kanjiTable: &kanji, phraseTable: phrases, gamma: 1
  )
  // log10(1 + 999) = 3, log10(1 + 99) = 2, median = 2.5; bias = ±0.5.
  let grams = kanji[.kanji]?["ㄗㄞˋ"] ?? []
  let biasZai = grams.first(where: { $0.value == "在" })?.scoreBias ?? .nan
  let biasZai4 = grams.first(where: { $0.value == "再" })?.scoreBias ?? .nan
  #expect(abs(biasZai - 0.5) < 1e-9)
  #expect(abs(biasZai4 + 0.5) < 1e-9)
  #expect(grams.allSatisfy { $0.count == 9 })
}
