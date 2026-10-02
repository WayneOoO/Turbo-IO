import Foundation

/// 眼镜屏只吃纯文本、单条 ≤512 字节（见 `AssistantAnswerPrototype.chat`）。
/// 这里把 Hermes 的回答处理成「能上屏的样子」：
/// 去 Markdown 符号 → 换行归并成句号 → 按 UTF-8 边界切片 → 截断保护。
/// 全部是纯函数、不碰设备，方便在没有眼镜的情况下自检。
enum HermesAnswerText {
    /// 设备侧 `StandbyVoiceSession.cloudText` 的单轮总上限是 8192 字节，这里留余量。
    static let maximumBytes = 8_000
    /// `AssistantAnswerPrototype.chat` / `cloudText` 的单条硬上限（字节）。
    static let chunkBytes = 512

    /// Markdown → 眼镜屏可读纯文本。
    static func plain(_ raw: String) -> String {
        var lines: [String] = []
        var inFence = false
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()      // 代码块整体不上屏：眼镜屏放不下等宽排版
                continue
            }
            if inFence { continue }
            var text = stripInline(line)
            // 标题 / 引用 / 无序列表 / 有序列表 的前导标记
            text = replace("^\\s{0,3}(#{1,6}\\s+|>\\s?|[-*+]\\s+|\\d{1,3}[.)、]\\s+)", with: "", in: text)
            text = text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !isRule(text) else { continue }   // 空行、表格分隔行、水平线不上屏
            lines.append(text)
        }
        // 换行归并成句号，并压掉连着的空句与多余空白
        var out = lines.joined(separator: "。")
        out = replace("(\\s*。\\s*){2,}", with: "。", in: out)
        out = replace("[ \\t]{2,}", with: " ", in: out)
        out = replace("([，、；：？！])\\s*。", with: "$1", in: out)   // 「如下：。」→「如下：」
        out = replace("^(?:。|\\s)+", with: "", in: out)
        out = replace("[ \\t\\n]+$", with: "", in: out)
        return out
    }

    /// 表格分隔行 `|---|---|` 与水平线 `---` 不上屏。
    private static func isRule(_ text: String) -> Bool {
        let probe = text
            .replacingOccurrences(of: "|", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\t", with: "")
        return !probe.isEmpty && probe.allSatisfy { $0 == "-" || $0 == "—" || $0 == "–" }
    }

    /// UTF-8 边界安全的截断；超长时以省略号收尾。
    static func prefix(_ text: String, bytes: Int) -> String {
        guard bytes > 0 else { return "" }
        guard text.utf8.count > bytes else { return text }
        var out = ""
        var used = 0
        let budget = max(0, bytes - 3)          // 给省略号（3 字节）留位置
        for character in text {
            let size = String(character).utf8.count
            if used + size > budget { break }
            out.append(character)
            used += size
        }
        return out.isEmpty ? "" : out + "…"
    }

    /// 按 UTF-8 边界切片，每片 ≤ size 字节；不劈开任何字符。
    static func chunks(_ text: String, size: Int = chunkBytes) -> [String] {
        guard size > 0, !text.isEmpty else { return [] }
        var out: [String] = []
        var current = ""
        var used = 0
        for character in text {
            let bytes = String(character).utf8.count
            if bytes > size { continue }        // 单字符就超限：丢掉，保证每片都合法
            if used + bytes > size {
                out.append(current)
                current = ""
                used = 0
            }
            current.append(character)
            used += bytes
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// 行内 Markdown：图片丢掉、链接留文字、强调符与表格竖线清掉。
    private static func stripInline(_ line: String) -> String {
        var text = line
        text = replace("!\\[[^\\]]*\\]\\([^)]*\\)", with: "", in: text)
        text = replace("\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", in: text)
        text = text.replacingOccurrences(of: "`", with: "")
        text = replace("\\*", with: "", in: text)
        text = replace("~", with: "", in: text)
        text = replace("_{2,}", with: "", in: text)
        text = text.replacingOccurrences(of: "|", with: " ")
        return text
    }

    /// 正则替换；表达式异常时原样返回，不抛错、不吞正文。
    private static func replace(_ pattern: String, with template: String, in text: String) -> String {
        guard !text.isEmpty, let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}
