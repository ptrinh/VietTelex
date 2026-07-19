// register-source — best-effort register + enable the VietTelex input source so
// it shows up (and ideally is already enabled) right after the .pkg installs,
// without a logout. Run BY THE CONSOLE USER (postinstall does this via
// `launchctl asuser`), because Text Input Source state is per GUI session.
//
// Fully auto-enabling is not guaranteed by macOS (enabling an input source is a
// user decision in System Settings), so TISEnableInputSource is best-effort: on
// systems where it doesn't take, the installer's final screen tells the user to
// tick ViệtTelex themselves. Registration, at least, makes it appear in the list.
//
// Compiled + Developer-ID-signed at pkg-build time (Scripts/make-pkg.sh); ships
// inside the pkg's scripts payload, so the target machine needs no toolchain.

import Foundation
import Carbon

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: register-source <app-path>\n".utf8))
    exit(2)
}

// 1) Register the bundle so the system knows about the input source now.
let appURL = URL(fileURLWithPath: args[1]) as CFURL
let regStatus = TISRegisterInputSource(appURL)
FileHandle.standardError.write(Data("TISRegisterInputSource -> \(regStatus)\n".utf8))

// 2) Best-effort: enable any input source belonging to VietTelex.
if let unmanaged = TISCreateInputSourceList(nil, true) {
    let list = unmanaged.takeRetainedValue() as? [TISInputSource] ?? []
    for src in list {
        guard let idPtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { continue }
        let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
        if id.lowercased().contains("viettelex") {
            let e = TISEnableInputSource(src)
            FileHandle.standardError.write(Data("enable \(id) -> \(e)\n".utf8))
        }
    }
}
exit(0)
