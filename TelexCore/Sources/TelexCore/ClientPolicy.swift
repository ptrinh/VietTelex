// ClientPolicy.swift
// Pure, testable classification of client apps by bundle identifier.
//
// Remote-desktop / virtualization / screen-sharing apps forward raw scancodes to a
// guest OS; a synthesized Unicode syllable is meaningless there and comes out wrong.
// For those clients the IME must behave exactly as if it were OFF.

public enum ClientPolicy {

    /// Built-in force-passthrough list. Best-effort but conservative: these are
    /// specific reverse-DNS ids that will not collide with ordinary apps.
    public static let forcePassthroughBundleIDs: Set<String> = [
        // Microsoft Remote Desktop (legacy) and Windows App (new) share this id.
        "com.microsoft.rdc.macos",
        "com.microsoft.rdc.osx.beta",
        // Virtualization
        "com.parallels.desktop.console",
        "com.vmware.fusion",
        "com.utmapp.UTM",
        // Screen sharing / remote control
        "com.apple.ScreenSharing",
        "com.citrix.receiver.icaviewer.mac",
        "com.teamviewer.TeamViewer",
        "com.realvnc.vncviewer",
        "com.nulana.remotixmac",
    ]

    /// True when the built-in list marks this client as force-passthrough.
    public static func isRemoteDesktop(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return forcePassthroughBundleIDs.contains(id)
    }
}
