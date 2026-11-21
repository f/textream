// With Xcode selected, run from the repository root:
// out=$(mktemp -d)
// xcrun swiftc -swift-version 5 -parse-as-library -enable-testing -emit-library -emit-module -module-name Textream -emit-module-path "$out/Textream.swiftmodule" Textream/Textream/*.swift -o "$out/libTextream.dylib"
// xcrun swiftc -parse-as-library -I "$out" -L "$out" -lTextream -Xlinker -rpath -Xlinker "$out" tests/CJKScriptWords.swift -o "$out/check" && "$out/check"
import Foundation
@testable import Textream

@main
struct CJKScriptWords {
    static func main() {
        let cases: [(String, [String])] = [
            ("那一年他 36 歲，搬到新的城市，而且換過三份工作。",
             ["那", "一", "年", "他", "36", "歲，", "搬", "到", "新", "的", "城", "市，", "而", "且", "換", "過", "三", "份", "工", "作。"]),
            ("他說：「（好！）」", ["他", "說：", "「（好！）」"]),
            ("答…次", ["答…", "次"]),
            ("値1234.56円、次", ["値", "1234.56", "円、", "次"]),
            ("版本v1.2「新」", ["版", "本", "v1.2", "「新」"]),
            ("， 字 。", ["，", "字", "。"]),
            ("[pause] hello, world!", ["[pause]", "hello,", "world!"]),
        ]
        for (text, expected) in cases {
            let actual = splitTextIntoWords(text)
            guard actual == expected else {
                print("Unexpected display words for \(text): \(actual)")
                exit(1)
            }
        }
        precondition(!WordFlowLayout.isAnnotationWord("歲，"))
        precondition(WordFlowLayout.isAnnotationWord("[pause]"))
        precondition(paragraphBreakWordIndices(in: "歳。\n\n次") == [1])
        print("CJK script and annotation checks passed")
    }
}
