import XCTest
import WorkspaceKitCSupport

/// `repo_dice_coefficient` (bigram Sørensen–Dice, ASCII case-folded) must
/// give the same values as the table-based reference it replaced.
final class DiceCoefficientTests: XCTestCase {

	/// The former implementation: two 65,536-entry bigram tables.
	private func reference(_ a: String, _ b: String) -> Double {
		let x = Array(a.utf8), y = Array(b.utf8)
		if x.isEmpty || y.isEmpty { return 0 }
		if x == y { return 1 }
		func lower(_ c: UInt8) -> UInt8 { (c >= 65 && c <= 90) ? c + 32 : c }
		if x.count == 1 || y.count == 1 { return x[0] == y[0] ? 1 : 0 }
		var ta = [Int](repeating: 0, count: 65_536), tb = ta
		for i in 0..<(x.count - 1) { ta[Int(lower(x[i])) << 8 | Int(lower(x[i + 1]))] += 1 }
		for i in 0..<(y.count - 1) { tb[Int(lower(y[i])) << 8 | Int(lower(y[i + 1]))] += 1 }
		var intersection = 0
		for i in 0..<65_536 { intersection += min(ta[i], tb[i]) }
		return 2.0 * Double(intersection) / Double(x.count - 1 + y.count - 1)
	}

	private func dice(_ a: String, _ b: String) -> Double {
		a.withCString { pa in b.withCString { pb in repo_dice_coefficient(pa, pb) } }
	}

	func testKnownValues() {
		XCTAssertEqual(dice("night", "nacht"), 0.25)
		XCTAssertEqual(dice("Hello", "hello"), 1.0)
		XCTAssertEqual(dice("aaaa", "aa"), 0.5)
		XCTAssertEqual(dice("", "x"), 0.0)
		XCTAssertEqual(dice("a", "abc"), 1.0)
		XCTAssertEqual(dice("ab", "cd"), 0.0)
	}

	func testMatchesTheTableReferenceOnRandomInputs() {
		var generator = SystemRandomNumberGenerator()
		let alphabet = Array("aAbBcC ()_-{}=;é\t")
		for _ in 0..<300 {
			let a = String((0..<Int.random(in: 0...60, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! })
			let b = String((0..<Int.random(in: 0...60, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! })
			XCTAssertEqual(dice(a, b), reference(a, b), accuracy: 1e-12, "\(a.debugDescription) vs \(b.debugDescription)")
		}
		let long = String(repeating: "func value() -> Int { return 42 }\n", count: 400)
		XCTAssertEqual(dice(long, long + "x"), reference(long, long + "x"), accuracy: 1e-12)
	}
}
