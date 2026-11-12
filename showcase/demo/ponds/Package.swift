// swift-tools-version: 5.9
import PackageDescription
// A throwaway demo repo for the Pixlz video: nothing here matters.
let package = Package(name: "Ponds", targets: [.target(name: "Ponds"), .testTarget(name: "PondsTests", dependencies: ["Ponds"])])
