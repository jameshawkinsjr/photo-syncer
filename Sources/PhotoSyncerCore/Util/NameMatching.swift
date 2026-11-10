import Foundation

/// File-name matching, for services that don't keep the original bytes (Pix-Star) or don't
/// tell us an MD5 (Google). Names are compared without case, extension, spaces or punctuation:
///
///     "Summer Trip - 1 of 180.jpeg"      -> "summertrip1of180"
///     "Summer_Trip_-_1_of_180_5985.jpg"  -> "summertrip1of180"  (Pix-Star)
public enum NameMatching {
    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp",
    ]

    /// The comparable form of a local or uploaded file name.
    public static func key(_ fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        return squash(base)
    }

    /// The comparable form of a name as Pix-Star stores it: Pix-Star swaps spaces for
    /// underscores and appends "_<number>" to every upload.
    public static func pixStarKey(_ storedName: String) -> String {
        var base = (storedName as NSString).deletingPathExtension
        if let range = base.range(of: "_[0-9]+$", options: .regularExpression) {
            base.removeSubrange(range)
        }
        return squash(base)
    }

    static func squash(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// A file name safe to upload: the base name kept, the extension set to match the bytes.
    public static func uploadName(base: String, ext: String) -> String {
        let cleaned = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return cleaned + "." + ext
    }

    public static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }
}
