// Apple's own icon variants (dark, monochrome) from IconServices, the framework the real Dock uses.
// Private API, so everything is looked up at runtime and BetterDock falls back to its own renderer
// when it is unavailable.
import AppKit
import ObjectiveC

enum SystemIcons {
    private static let loaded: Bool = dlopen("/System/Library/PrivateFrameworks/IconServices.framework/IconServices", RTLD_NOW) != nil
    private static var cache: [String: CGImage] = [:]

    /// appearance: 0 light, 1 dark. variant: 0 full colour, 2 monochrome.
    static func image(path: String, appearance: Int, variant: Int, pixels: Int = 256) -> CGImage? {
        let key = "\(path)|\(appearance)|\(variant)|\(pixels)"
        if let hit = cache[key] { return hit }
        guard loaded,
              let iconClass = NSClassFromString("ISIcon") as? NSObject.Type,
              let descClass = NSClassFromString("ISImageDescriptor") as? NSObject.Type else { return nil }

        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard let iconAlloc = (iconClass as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject,
              let icon = iconAlloc.perform(NSSelectorFromString("initWithURL:"), with: url)?.takeUnretainedValue() as? NSObject,
              let descAlloc = (descClass as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject else { return nil }

        typealias InitSize = @convention(c) (AnyObject, Selector, CGSize, CGFloat) -> Unmanaged<AnyObject>
        typealias SetUInt = @convention(c) (AnyObject, Selector, UInt) -> Void
        typealias Prepare = @convention(c) (AnyObject, Selector, NSArray) -> Void
        typealias Render = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<CGImage>?

        func imp<T>(_ object: AnyObject, _ name: String, _: T.Type) -> (Selector, T)? {
            let sel = NSSelectorFromString(name)
            guard let method = class_getInstanceMethod(object_getClass(object), sel) else { return nil }
            return (sel, unsafeBitCast(method_getImplementation(method), to: T.self))
        }

        guard let (initSel, initFn) = imp(descAlloc, "initWithSize:scale:", InitSize.self) else { return nil }
        let descriptor = initFn(descAlloc, initSel, CGSize(width: pixels / 2, height: pixels / 2), 2).takeUnretainedValue()
        if let (sel, fn) = imp(descriptor, "setAppearance:", SetUInt.self) { fn(descriptor, sel, UInt(appearance)) }
        if let (sel, fn) = imp(descriptor, "setAppearanceVariant:", SetUInt.self) { fn(descriptor, sel, UInt(variant)) }
        if let (sel, fn) = imp(icon, "prepareImagesForImageDescriptors:", Prepare.self) { fn(icon, sel, [descriptor] as NSArray) }
        guard let (renderSel, renderFn) = imp(icon, "CGImageForImageDescriptor:", Render.self),
              let image = renderFn(icon, renderSel, descriptor)?.takeUnretainedValue() else { return nil }
        cache[key] = image
        return image
    }
}
