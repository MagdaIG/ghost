// swift-tools-version:5.9
//
// Ghost se compila solo con las Command Line Tools de Xcode:
//   swift build -c release
// El bundle Ghost.app lo arma ./install.sh (Info.plist, icono, CLI y firma ad-hoc).

import PackageDescription

let package = Package(
    name: "Ghost",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Ghost", targets: ["Ghost"])
    ],
    targets: [
        .executableTarget(
            name: "Ghost",
            path: "Sources/Ghost",
            // SwiftPM no admite Info.plist como recurso: install.sh lo copia a Ghost.app/Contents.
            exclude: ["Resources/Info.plist"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
