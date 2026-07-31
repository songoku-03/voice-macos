import Testing
import Foundation
@testable import Core

@Suite struct BundleIntegrityTests {
    
    @Test func testClassifyLocationEligible() {
        let home = "/Users/testuser"
        
        let app1 = "/Users/testuser/Applications/SoundsSource.app"
        #expect(BundleIntegrityChecker.classifyLocation(path: app1, homeDirectoryPath: home) == .eligible)
        
        let app2 = "/Applications/SoundsSource.app"
        #expect(BundleIntegrityChecker.classifyLocation(path: app2, homeDirectoryPath: home) == .eligible)
    }
    
    @Test func testClassifyLocationProtectedFolders() {
        let home = "/Users/testuser"
        
        let docs = "/Users/testuser/Documents/GitHub/voice-macos/build/SoundsSource.app"
        #expect(
            BundleIntegrityChecker.classifyLocation(path: docs, homeDirectoryPath: home) ==
            .ineligible(reason: .protectedFolder("Documents"))
        )
        
        let desktop = "/Users/testuser/Desktop/SoundsSource.app"
        #expect(
            BundleIntegrityChecker.classifyLocation(path: desktop, homeDirectoryPath: home) ==
            .ineligible(reason: .protectedFolder("Desktop"))
        )
        
        let downloads = "/Users/testuser/Downloads/SoundsSource.app"
        #expect(
            BundleIntegrityChecker.classifyLocation(path: downloads, homeDirectoryPath: home) ==
            .ineligible(reason: .protectedFolder("Downloads"))
        )
    }
    
    @Test func testClassifyLocationAppTranslocation() {
        let home = "/Users/testuser"
        let translocation = "/private/var/folders/12/34/AppTranslocation/56/d/SoundsSource.app"
        #expect(
            BundleIntegrityChecker.classifyLocation(path: translocation, homeDirectoryPath: home) ==
            .ineligible(reason: .appTranslocation)
        )
    }
    
    @Test func testDiagnoseMissingBundle() {
        let home = "/Users/testuser"
        let nonExistentPath = "/Users/testuser/Applications/NonExistent.app"
        let bundleURL = URL(fileURLWithPath: nonExistentPath)
        
        let result = BundleIntegrityChecker.diagnose(
            bundleURL: bundleURL,
            runningExecutablePath: nil,
            homeDirectoryPath: home
        )
        #expect(result == .missing)
    }
    
    @Test func testDiagnoseIneligibleLocation() {
        let home = "/Users/testuser"
        let docsPath = "/Users/testuser/Documents/SoundsSource.app"
        
        let eligibility = BundleIntegrityChecker.classifyLocation(path: docsPath, homeDirectoryPath: home)
        if case .ineligible(let reason) = eligibility {
            #expect(reason == .protectedFolder("Documents"))
        } else {
            Issue.record("Expected ineligible location")
        }
    }
    
    @Test func testDiagnoseNilBundleURL() {
        let result = BundleIntegrityChecker.diagnose(bundleURL: nil)
        #expect(result == .unknown)
    }
}
