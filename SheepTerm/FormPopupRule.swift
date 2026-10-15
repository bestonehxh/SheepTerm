import Foundation

/// `FormPopup`'s one decision (GlassChrome.swift), out here for the harness:
/// which row a pop-up shows for `selection`, and whether the binding must be
/// corrected. A selection that is not among the options (a host's
/// credentialID whose credential was deleted) used to SHOW the first row
/// while the binding kept the dead id, so Save stored something the form did
/// not show (review round 4). Now the first option is shown AND written back.
nonisolated enum FormPopupRule {
    /// `options` = the option values in row order (separators left out).
    /// nil index = no options at all.
    static func resolve<Value: Equatable>(selection: Value, options: [Value]) -> (index: Int?, writeBack: Value?) {
        if let index = options.firstIndex(of: selection) { return (index, nil) }
        guard let first = options.first else { return (nil, nil) }
        return (0, first)
    }
}
