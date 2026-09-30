//
//  L10n.swift
//  Textream
//

import Foundation

enum L10n {
    static func string(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: Locale.current, arguments: arguments)
    }

    static var webLanguageCode: String {
        let preferred = Bundle.main.preferredLocalizations.first ?? Locale.current.identifier
        return preferred.hasPrefix("zh") ? "zh-Hans" : "en"
    }

    static func webStringsJSON(_ values: [String: String]) -> String {
        let localized = values.mapValues { string($0) }
        guard
            let data = try? JSONSerialization.data(withJSONObject: localized, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return json
    }
}
