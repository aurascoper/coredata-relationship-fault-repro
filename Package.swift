// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "CoreDataRelationshipFaultRepro",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Repro")
    ]
)
