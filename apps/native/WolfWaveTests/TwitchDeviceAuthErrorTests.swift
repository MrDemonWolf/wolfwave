//
//  TwitchDeviceAuthErrorTests.swift
//  WolfWaveTests
//
//  Created by MrDemonWolf, Inc. on 3/19/26.
//

import XCTest
@testable import WolfWave

nonisolated final class TwitchDeviceAuthErrorTests: XCTestCase {

    // MARK: - LocalizedError Conformance Tests

    @MainActor func testAllErrorCasesConformToLocalizedError() {
        let errors: [TwitchDeviceAuthError] = [
            .invalidResponse,
            .accessDenied,
            .expiredToken,
            .authorizationPending,
            .slowDown,
            .invalidClient,
            .unknown("test"),
        ]

        for error in errors {
            guard let desc = error.errorDescription else {
                XCTFail("Expected non-nil errorDescription for \(error)")
                return
            }
            XCTAssertFalse(desc.isEmpty, "Error \(error) should have a non-empty errorDescription")
        }
    }

    @MainActor func testUnknownEmptyStringReturnsEmptyDescription() {
        let error = TwitchDeviceAuthError.unknown("")
        XCTAssertEqual(error.errorDescription, "")
    }

    // MARK: - Error Description Content Tests

    @MainActor func testInvalidResponseDescription() {
        let error = TwitchDeviceAuthError.invalidResponse
        XCTAssertEqual(error.errorDescription, "Invalid response from Twitch")
    }

    @MainActor func testAccessDeniedDescription() {
        let error = TwitchDeviceAuthError.accessDenied
        XCTAssertEqual(error.errorDescription, "Access denied by user")
    }

    @MainActor func testExpiredTokenDescription() {
        let error = TwitchDeviceAuthError.expiredToken
        XCTAssertEqual(error.errorDescription, "Device code expired")
    }

    @MainActor func testAuthorizationPendingDescription() {
        let error = TwitchDeviceAuthError.authorizationPending
        XCTAssertEqual(error.errorDescription, "Waiting for user authorization")
    }

    @MainActor func testSlowDownDescription() {
        let error = TwitchDeviceAuthError.slowDown
        XCTAssertEqual(error.errorDescription, "Polling too quickly")
    }

    @MainActor func testInvalidClientDescription() {
        let error = TwitchDeviceAuthError.invalidClient
        XCTAssertEqual(error.errorDescription, "Invalid client credentials")
    }

    @MainActor func testUnknownCustomMessageDescription() {
        let msg = "Something went wrong"
        let error = TwitchDeviceAuthError.unknown(msg)
        XCTAssertEqual(error.errorDescription, msg)
    }

    // MARK: - Human Readability Tests

    @MainActor func testErrorDescriptionsAreHumanReadable() {
        let errors: [TwitchDeviceAuthError] = [
            .invalidResponse,
            .accessDenied,
            .expiredToken,
            .authorizationPending,
            .slowDown,
            .invalidClient,
        ]

        for error in errors {
            guard let desc = error.errorDescription else {
                XCTFail("Expected non-nil errorDescription for \(error)")
                return
            }
            // Should not contain technical jargon like "nil", "null", error codes
            XCTAssertFalse(desc.contains("nil"), "Description should not contain 'nil': \(desc)")
            XCTAssertFalse(desc.contains("null"), "Description should not contain 'null': \(desc)")
            // Should be a readable sentence (starts with uppercase)
            XCTAssertTrue(desc.first?.isUppercase == true, "Description should start with uppercase: \(desc)")
        }
    }

    // MARK: - TwitchDeviceCodeResponse Boundary Tests

    @MainActor func testDeviceCodeResponseWithZeroExpiresIn() {
        let response = TwitchDeviceCodeResponse(
            deviceCode: "device123",
            userCode: "ABCD-1234",
            verificationURI: "https://twitch.tv/activate",
            verificationURIComplete: nil,
            expiresIn: 0,
            interval: 5
        )
        XCTAssertEqual(response.expiresIn, 0)
    }

    @MainActor func testDeviceCodeResponseWithMinimalInterval() {
        let response = TwitchDeviceCodeResponse(
            deviceCode: "device123",
            userCode: "ABCD-1234",
            verificationURI: "https://twitch.tv/activate",
            verificationURIComplete: nil,
            expiresIn: 600,
            interval: 1
        )
        XCTAssertEqual(response.interval, 1)
    }

    @MainActor func testDeviceCodeResponseWithEmptyUserCode() {
        let response = TwitchDeviceCodeResponse(
            deviceCode: "device123",
            userCode: "",
            verificationURI: "https://twitch.tv/activate",
            verificationURIComplete: nil,
            expiresIn: 600,
            interval: 5
        )
        XCTAssertTrue(response.userCode.isEmpty)
    }
}
