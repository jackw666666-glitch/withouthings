import UIKit

/// Draws what the watch asks for: unicode glyphs for notification text, app icons, activity icons.
/// White on black, ARGB pixels; the core thresholds them to 1-bit.
final class WatchRasterizer: Rasterizer {
    func glyph(codepoint: UInt32, width: UInt8, height: UInt8) -> Bitmap {
        guard let scalar = Unicode.Scalar(codepoint) else { return empty() }
        let text = String(Character(scalar))
        if text.trimmingCharacters(in: .whitespaces).isEmpty { return empty() }
        return draw(Int(width), Int(height)) { size in
            var font = UIFont.systemFont(ofSize: 100)
            let probe = (text as NSString).size(withAttributes: [.font: font])
            guard probe.width > 0, probe.height > 0 else { return }
            let scale = min(size.width / probe.width, size.height / font.lineHeight)
            font = UIFont.systemFont(ofSize: 100 * scale)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
            let w = (text as NSString).size(withAttributes: attrs).width
            (text as NSString).draw(at: CGPoint(x: (size.width - w) / 2, y: 0), withAttributes: attrs)
        }
    }

    /// Pictures for picture alerts, by their app id (filled by WatchController.notify before posting).
    static var pictures: [String: UIImage] = [:]

    func icon(appId: String, width: UInt8, height: UInt8) -> Bitmap {
        if let picture = Self.pictures[appId] {
            AppLog.log("picture icon \(appId) \(width)x\(height)")
            return draw(Int(width), Int(height)) { size in
                let ratio = min(size.width / picture.size.width, size.height / picture.size.height)
                let fit = CGSize(width: picture.size.width * ratio, height: picture.size.height * ratio)
                picture.draw(in: CGRect(x: (size.width - fit.width) / 2, y: (size.height - fit.height) / 2, width: fit.width, height: fit.height))
            }
        }
        guard let name = Self.appSymbols[appId] ?? Self.appSymbols.first(where: { appId.hasPrefix($0.key) })?.value
        else { return empty() }   // unknown app: the watch shows its default bell
        return symbol(name, Int(width), Int(height))
    }

    func activityGlyph(activity: UInt32, width: UInt8, height: UInt8) -> Bitmap {
        symbol(Self.activitySymbols[activity] ?? "figure.mixed.cardio", Int(width), Int(height))
    }

    private func symbol(_ name: String, _ w: Int, _ h: Int) -> Bitmap {
        guard let image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(weight: .bold)) else { return empty() }
        return draw(w, h) { size in
            let tinted = image.withTintColor(.white, renderingMode: .alwaysOriginal)
            let ratio = min(size.width / tinted.size.width, size.height / tinted.size.height)
            let fit = CGSize(width: tinted.size.width * ratio, height: tinted.size.height * ratio)
            tinted.draw(in: CGRect(x: (size.width - fit.width) / 2, y: (size.height - fit.height) / 2,
                                   width: fit.width, height: fit.height))
        }
    }

    private func draw(_ w: Int, _ h: Int, _ body: (CGSize) -> Void) -> Bitmap {
        guard w > 0, h > 0 else { return empty() }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            body(CGSize(width: w, height: h))
        }
        guard let cg = image.cgImage else { return empty() }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return empty() }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var pixels = [UInt32](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r = UInt32(rgba[i * 4]), g = UInt32(rgba[i * 4 + 1]), b = UInt32(rgba[i * 4 + 2])
            pixels[i] = 0xFF00_0000 | (r << 16) | (g << 8) | b      // ARGB, like Android's getPixels
        }
        return Bitmap(width: UInt8(w), height: UInt8(h), pixels: pixels)
    }

    private func empty() -> Bitmap { Bitmap(width: 0, height: 0, pixels: []) }

    static let appSymbols: [String: String] = [
        "com.apple.MobileSMS": "message.fill",
        "com.apple.mobilephone": "phone.fill",
        "com.apple.mobilemail": "envelope.fill",
        "com.apple.mobilecal": "calendar",
        "com.apple.reminders": "checklist",
        "com.apple.facetime": "video.fill",
        "com.apple.Home": "house.fill",
        "net.whatsapp.WhatsApp": "phone.bubble.fill",
        "com.facebook.Messenger": "bubble.left.and.bubble.right.fill",
        "com.burbn.instagram": "camera.fill",
        "com.jdubz.instagram": "camera.fill",
        "ph.telegra.Telegraph": "paperplane.fill",
        "com.hammerandchisel.discord": "gamecontroller.fill",
        "com.google.Gmail": "envelope.fill",
        "com.microsoft.Office.Outlook": "envelope.fill",
        "com.tinyspeck.chatlyio": "number",
        "com.reddit.Reddit": "bubble.left.fill",
        "com.spotify.client": "music.note",
        "com.google.ios.youtube": "play.rectangle.fill",
        "io.robbie.HomeAssistant": "house.fill",
        "com.jdubz.kiosk": "square.grid.2x2.fill",
        "com.ubercab.UberClient": "car.fill",
        "com.ubercab.UberEats": "bag.fill",
        "com.atebits.Tweetie2": "bird.fill",
        "com.toyopagroup.picaboo": "bolt.fill",
    ]

    static let activitySymbols: [UInt32: String] = [
        1: "figure.walk", 2: "figure.run", 3: "figure.hiking", 4: "figure.skating", 5: "bicycle",
        6: "figure.outdoor.cycle", 7: "figure.pool.swim", 8: "figure.surfing", 9: "figure.sailing",
        10: "figure.sailing", 11: "figure.surfing", 12: "figure.tennis", 13: "figure.table.tennis",
        14: "figure.squash", 15: "figure.badminton", 16: "figure.strengthtraining.traditional",
        17: "figure.mixed.cardio", 18: "figure.elliptical", 19: "figure.pilates", 20: "figure.basketball",
        21: "figure.soccer", 22: "figure.american.football", 23: "figure.rugby", 24: "figure.volleyball",
        25: "figure.waterpolo", 26: "figure.equestrian.sports", 27: "figure.golf", 28: "figure.yoga",
        29: "figure.dance", 30: "figure.boxing", 31: "figure.fencing", 32: "figure.wrestling",
        33: "figure.martial.arts", 34: "figure.skiing.downhill", 35: "figure.snowboarding",
        36: "figure.mixed.cardio", 187: "figure.rower", 188: "figure.dance", 191: "figure.baseball",
        192: "figure.handball",
    ]
}
