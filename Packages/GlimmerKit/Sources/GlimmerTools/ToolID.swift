/// Every tool in the tool palette, with its single-key shortcut.
/// Mirrors the web app's rail (`web/src/ui/ToolRail.tsx`); tools are implemented
/// phase by phase (see docs/PLAN.md §3).
public enum ToolID: String, CaseIterable, Sendable {
    case move, hand
    case rectangleMarquee, ellipseMarquee, lasso, magicWand, magicSelect
    case crop, freeTransform
    case brush, eraser, paintBucket, gradient, patternStamp
    case cloneStamp, healingBrush, dodge, burn, blur, sharpen, smudge
    case pen, type, shape
    case eyedropper

    public var shortcutKey: Character? {
        switch self {
        case .move: "v"
        case .hand: "h"
        case .rectangleMarquee, .ellipseMarquee: "m"
        case .lasso: "l"
        case .magicWand: "w"
        case .magicSelect: "a"
        case .crop: "c"
        case .freeTransform: "t"
        case .brush: "b"
        case .eraser: "e"
        case .paintBucket: "k"
        case .gradient: "g"
        case .cloneStamp: "s"
        case .healingBrush: "j"
        case .dodge, .burn: "o"
        case .pen: "p"
        case .type: "y"
        case .shape: "u"
        case .eyedropper: "i"
        case .patternStamp, .blur, .sharpen, .smudge: nil
        }
    }
}
