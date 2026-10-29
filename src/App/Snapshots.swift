import AppKit
import SwiftUI

/// `--snapshot DIR`: renders each notch state to a PNG on a fake menu bar, for checking the
/// look without a screen recording permission.
@MainActor
enum Snapshots {
    static func render(to dir: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            print("cannot create \(dir.path): \(error.localizedDescription)")
            return false
        }
        let center = ActivityCenter()
        let model = NotchModel(activities: center, config: Config())
        model.geometry = NotchGeometry.compute(screenFrame: CGRect(x: 0, y: 0, width: 1470, height: 956),
                                               safeTop: 32, leftWidth: 645.5, rightWidth: 645.5)
        guard let metrics = model.metrics else { return false }

        var ok = true
        func shot(_ name: String) {
            let view = Backdrop(size: metrics.window, notch: metrics.notch) { NotchRootView(model: model) }
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                print("FAIL  \(name): render failed")
                ok = false
                return
            }
            let url = dir.appendingPathComponent("\(name).png")
            do {
                try png.write(to: url)
                print("wrote \(url.path)")
            } catch {
                print("FAIL  \(name): \(error.localizedDescription)")
                ok = false
            }
        }

        shot("1-idle")
        model.setHoveringForSnapshot(true); shot("2-hover"); model.setHoveringForSnapshot(false)
        if let a = TestActivities.sample("test.permission") { center.post(a) }
        shot("3-compact")
        model.setHoveringForSnapshot(true); shot("4-peek"); model.setHoveringForSnapshot(false)
        center.removeAll()
        if let a = TestActivities.sample("test.music") { center.post(a) }
        shot("5-compact-music")
        model.open(tab: .home); shot("6-open-home")
        model.tab = .terminal; shot("7-open-terminal")
        model.tab = .settings; shot("8-open-settings")
        model.close()

        // The prompter strip under the notch while it runs: one black shape, not two.
        center.removeAll()
        if let strip = FeatureRegistry.snapshotViews().first(where: { $0.name == "prompter-strip" })?.view {
            center.post(Activity(id: "prompter.running", priority: .info, symbol: "text.aligncenter",
                                 accessory: .progress(0.4), title: "Pitch", subtitle: "0:23 left"))
            let composite = Backdrop(size: metrics.window, notch: metrics.notch) {
                ZStack(alignment: .top) {
                    strip
                    NotchRootView(model: model)
                }
            }
            let renderer = ImageRenderer(content: composite)
            renderer.scale = 2
            if let image = renderer.cgImage,
               let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("9-prompter-under-notch.png"))
                print("wrote \(dir.appendingPathComponent("9-prompter-under-notch.png").path)")
            } else {
                print("FAIL  prompter composite: render failed")
                ok = false
            }
            center.removeAll()
        }

        for (name, view) in FeatureRegistry.snapshotViews() {
            let renderer = ImageRenderer(content: view.padding(12).background(Color(white: 0.3)))
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                print("FAIL  \(name): render failed")
                ok = false
                continue
            }
            let url = dir.appendingPathComponent("feature-\(name).png")
            do {
                try png.write(to: url)
                print("wrote \(url.path)")
            } catch {
                print("FAIL  \(name): \(error.localizedDescription)")
                ok = false
            }
        }
        return ok
    }
}

/// A gray "wallpaper" with a menu bar strip and a dark cutout where the hardware notch is,
/// so the shape's edges are visible.
private struct Backdrop<Content: View>: View {
    let size: CGSize
    let notch: CGSize
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .top) {
            Color(white: 0.55)
            Color(white: 0.75).frame(height: notch.height)
            Rectangle().fill(Color(red: 0.6, green: 0.1, blue: 0.1)).frame(width: notch.width, height: notch.height)
            content
        }
        .frame(width: size.width, height: size.height)
    }
}
