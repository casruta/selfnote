import Foundation
import NaturalLanguage

enum NoteFormatter {
    struct Draft: Equatable {
        let title: String
        let body: String
    }

    private struct Sentence {
        let text: String
        let startsParagraph: Bool
    }

    private static func sentences(in transcript: String, locale: Locale) -> [Sentence] {
        let tokenizer = NLTokenizer(unit: .sentence)
        let language = locale.language.languageCode?.identifier
        if let language { tokenizer.setLanguage(NLLanguage(rawValue: language)) }

        var sentences: [Sentence] = []
        for line in transcript.split(whereSeparator: \.isNewline) {
            let paragraph = String(line)
            tokenizer.string = paragraph
            var startsParagraph = true
            tokenizer.enumerateTokens(in: paragraph.startIndex..<paragraph.endIndex) { range, _ in
                let text = paragraph[range].trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    sentences.append(Sentence(text: text, startsParagraph: startsParagraph))
                    startsParagraph = false
                }
                return true
            }
        }
        return sentences
    }

    static func draft(from transcript: String, locale: Locale) -> Draft {
        let sentences = sentences(in: transcript, locale: locale)
        let language = locale.language.languageCode?.identifier
        guard let first = sentences.first else { return Draft(title: "", body: transcript) }

        let firstCue = language == "en" ? cue(in: first.text) : nil
        let phrase = firstCue.flatMap { $0.content.isEmpty ? nil : $0.content } ?? first.text
        let fullTitle = phrase.hasSuffix(".") && !phrase.hasSuffix("..") ? String(phrase.dropLast()) : phrase
        let title = fullTitle.count <= 64 ? fullTitle : String(fullTitle.prefix(61)) + "…"
        let useFirstAsHeading = sentences.count > 1 && firstCue == nil && fullTitle.count <= 48
            && fullTitle.split(whereSeparator: \.isWhitespace).count <= 5

        var body = ""
        var previousWasList = false
        var breakParagraph = false
        for sentence in sentences.dropFirst(useFirstAsHeading ? 1 : 0) {
            let command = language == "en" ? cue(in: sentence.text) : nil
            let isList = command?.prefix.isEmpty == false
            let content = command?.content ?? sentence.text
            if command?.prefix == "" { breakParagraph = true }
            guard !content.isEmpty else { continue }
            if !body.isEmpty {
                if isList && previousWasList {
                    body += "\n"
                } else if sentence.startsParagraph || breakParagraph || isList || previousWasList {
                    body += "\n\n"
                } else {
                    body += " "
                }
            }
            body += (command?.prefix ?? "") + content
            previousWasList = isList
            breakParagraph = false
        }
        return Draft(title: title, body: body)
    }

    static func summary(from transcript: String, locale: Locale) -> String {
        let sentences = sentences(in: transcript, locale: locale)
        let english = locale.language.languageCode?.identifier == "en"
        let content = sentences.compactMap { sentence -> String? in
            let text = (english ? cue(in: sentence.text)?.content : nil) ?? sentence.text
            return text.isEmpty ? nil : text
        }
        return content.prefix(2).joined(separator: " ")
    }

    private static func cue(in sentence: String) -> (prefix: String, content: String)? {
        // Delimiters keep ordinary phrases like “to do this properly” as prose.
        let rules = [("to do", "- [ ] "), ("bullet", "- "), ("new paragraph", "")]
        for (words, prefix) in rules {
            for separator in [",", ":"] {
                let marker = words + separator
                if let range = sentence.range(of: marker, options: [.anchored, .caseInsensitive]) {
                    let content = sentence[range.upperBound...].trimmingCharacters(in: .whitespaces)
                    if !content.isEmpty { return (prefix, content) }
                }
            }
        }
        if ["new paragraph", "new paragraph."].contains(sentence.lowercased()) {
            return ("", "")
        }
        return nil
    }

    static func togglingTask(at index: Int, in body: String) -> String {
        var lines = body.components(separatedBy: "\n")
        guard lines.indices.contains(index) else { return body }
        let line = lines[index]
        if line.hasPrefix("- [ ] ") {
            lines[index] = "- [x] " + line.dropFirst(6)
        } else if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
            lines[index] = "- [ ] " + line.dropFirst(6)
        } else {
            return body
        }
        return lines.joined(separator: "\n")
    }
}
