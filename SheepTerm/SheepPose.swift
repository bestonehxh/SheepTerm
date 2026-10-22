// Where the status bar sheep is, frame by frame — the input `SheepGlyph` draws. The same enum as SheepTermUIState
// on Windows and Linux; the Mac works the numbers out in WalkingSheepView / SleepingSheepView's own timelines.
public enum SheepPose: Equatable, Sendable {
    /// Walking back and forth: horizontal offset (pt), vertical bob (pt), mirrored when heading right.
    case walking(x: Double, bob: Double, mirrored: Bool)
    /// Napping: opacity and vertical offset of the drifting zzz (the drawn z's keep their own timeline).
    case sleeping(zOpacity: Double, zOffsetY: Double)
    case closed
}
