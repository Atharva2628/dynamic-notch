// Written by hand for Dynamic Notch. Upstream generates the full XTGETTCAP table from
// `swifterm-terminfo` with a build plugin; this keeps the replies programs actually ask
// for (true color and color count). Unknown keys get the terminal's "not found" reply.

#if !SWIFTTERM_EMBEDDED
/// The terminfo data that SwiftTerm reports over XTGETTCAP, keyed by the uppercase
/// hex-encoded capability name.
enum SwiftTermTerminfo {
    static let xtgettcapReplies: [String: String] = [
        "436F": "\u{1b}P1+r436F=323536\u{1b}\\",               // Co = 256
        "524742": "\u{1b}P1+r524742=38\u{1b}\\",                // RGB = 8
        "636F6C6F7273": "\u{1b}P1+r636F6C6F7273=323536\u{1b}\\", // colors = 256
    ]
}
#endif
