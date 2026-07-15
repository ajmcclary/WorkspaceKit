import XCTest
@testable import WorkspacePathLookup

final class PathMatcherPerformanceTests: XCTestCase {

    func testCanonicalPerformance_ASCII() {
        let names = (0..<200_000).map { "src/mod\($0)/deep/name-\($0).swift" }
        measure {
            var total = 0
            for n in names {
                // mimic what build() does
                let k1 = PathMatchIndexes.canonical((n as NSString).lastPathComponent, caseSensitive: false)
                let comps = n.split(separator: "/").map(String.init)
                if comps.count >= 2 {
                    let lastTwo = comps[comps.count-2] + "/" + comps[comps.count-1]
                    let k2 = PathMatchIndexes.canonical(lastTwo, caseSensitive: false)
                    total += k1.count + k2.count
                }
            }
            XCTAssertGreaterThan(total, 0)
        }
    }

    func testCanonicalPerformance_NonASCII() {
        // Sprinkle EN dashes / fullwidth digits ~1% of names
        var names = (0..<200_000).map { "src/mod\($0)/deep/name-\($0).swift" }
        for i in stride(from: 0, to: names.count, by: 97) {
            names[i] = "ｓｒｃ/ｍｏｄ\(i)/deep/name–\(i).swift" // fullwidth letters + EN dash
        }
        measure {
            var total = 0
            for n in names {
                // mimic what build() does
                let k1 = PathMatchIndexes.canonical((n as NSString).lastPathComponent, caseSensitive: false)
                let comps = n.split(separator: "/").map(String.init)
                if comps.count >= 2 {
                    let lastTwo = comps[comps.count-2] + "/" + comps[comps.count-1]
                    let k2 = PathMatchIndexes.canonical(lastTwo, caseSensitive: false)
                    total += k1.count + k2.count
                }
            }
            XCTAssertGreaterThan(total, 0)
        }
    }
    
    func testFoldHomoglyphsPerformance_ASCII() {
        let names = (0..<100_000).map { "src/component\($0)/utils/helper-\($0).swift" }
        measure {
            var total = 0
            for n in names {
                let folded = PathCharPolicy.foldHomoglyphsIfNeeded(n)
                total += folded.count
            }
            XCTAssertGreaterThan(total, 0)
        }
    }
    
	func testFoldHomoglyphsPerformance_Mixed() {
		var names = (0..<100_000).map { "src/component\($0)/utils/helper-\($0).swift" }
		// Add some non-ASCII variants (~5%)
		for i in stride(from: 0, to: names.count, by: 19) {
			names[i] = "src/component\(i)/utils/helper–\(i).swift" // EN dash
		}
		measure {
			var total = 0
			for n in names {
				let folded = PathCharPolicy.foldHomoglyphsIfNeeded(n)
				total += folded.count
			}
			XCTAssertGreaterThan(total, 0)
		}
	}
	
	func testLocatePerformance_WithAndWithoutParentheses() async {
		var files: [(String, String)] = []
		let roots = [
			"/Users/test/projA",
			"/Users/test/projB"
		]
		for i in 0..<200 {
			files.append(("src/features/Feature(Foo\(i))/index.ts", roots[0]))
			files.append(("src/features/Feature(Bar\(i))/index.ts", roots[0]))
			files.append(("lib/{Core}/Math+Utils\(i).swift", roots[1]))
			files.append(("docs/Guides (v2)/Intro\(i).md", roots[1]))
			files.append(("assets/icons/#hash%\(-i).svg", roots[0]))
		}
		let snapshot = await PathMatcherTestHelper.makeSnapshot(files: files)

		// Warm-up
		_ = PathMatcher.locate(userPath: "Feature(Foo10)/index.ts", snapshot: snapshot)
		_ = PathMatcher.locate(userPath: "Guides (v2)/Intro20.md", snapshot: snapshot)

		let queries = [
			"Feature(Foo150)/index.ts",
			"Feature(Bar75)/index.ts",
			"Math+Utils42.swift",
			"Guides (v2)/Intro180.md",
			"#hash%0.svg"
		]

		measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
			for query in queries {
				_ = PathMatcher.locate(userPath: query, snapshot: snapshot)
			}
		}
	}
	
	func testPathMatcherBuildSnapshot_LargeRepo() {
		// Simulate large repo with 50k files
		var files: [(String, String)] = []
		let root = "/Users/test/largerepo"
        
        for i in 0..<50_000 {
            let depth = i % 5 + 1
            var path = "src"
            for d in 1...depth {
                path += "/level\(d)"
            }
            path += "/file\(i).swift"
            files.append((path, root))
        }
        
        measure {
            Task {
                let snapshot = await PathMatcherTestHelper.makeSnapshot(files: files)
                XCTAssertGreaterThan(snapshot.filesByFullPath.count, 0)
            }
        }
    }
}
