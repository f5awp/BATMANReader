// WebController.swift
// Singleton WKWebView engine.
// Drives the three-phase flow: login → navigate to report → scrape.
//
// ── Three customization points ───────────────────────────────────────
//  1. loginURL      — the login page (already set to the real AA URL)
//  2. reportURL     — the Expanded Schedule Report URL (needs calibration)
//  3. loginJS       — the CSS selectors for username/password fields
//
// To find the correct reportURL and field selectors:
//  • Run in DEBUG, enable "Show web view" in Settings.
//  • Log in manually, navigate to My Work History → Expanded Schedule.
//  • Copy the URL from the debug web view's address bar into reportURL.
//  • View page source to confirm field names for loginJS.
// ─────────────────────────────────────────────────────────────────────

import WebKit
import SwiftUI
import Observation

@MainActor
@Observable
final class WebController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {

    static let shared = WebController()

    // MARK: - Observable state (observed by ContentView)

    var phase: Phase = .idle
    var lastError: String?

    var statusMessage: String { phase.description }

    // MARK: - URLs

    private let loginURL  = URL(string: "https://aadisp.worknet.ascent.com/ArisWorkNet/login.do")!

    // ── UPDATE THIS ───────────────────────────────────────────────────
    // Navigate to the Expanded Schedule Report manually, then copy the
    // full URL (including any query parameters) here.
    // Example: "https://aadisp.worknet.ascent.com/ArisWorkNet/report/expandedSchedule.do?workerID=292216&..."
    private let reportURL = URL(string: "https://aadisp.worknet.ascent.com/ArisWorkNet/report/expandedSchedule.do")!
    // ─────────────────────────────────────────────────────────────────

    // MARK: - Internal state

    enum Phase: CustomStringConvertible {
        case idle, loadingLogin, injectingCredentials
        case awaitingPostLogin, navigatingToReport
        case scrapingReport, complete, failed

        var description: String {
            switch self {
            case .idle:                  return "Idle — tap Fetch to start."
            case .loadingLogin:          return "Loading login page…"
            case .injectingCredentials:  return "Signing in…"
            case .awaitingPostLogin:     return "Waiting for login redirect…"
            case .navigatingToReport:    return "Opening schedule report…"
            case .scrapingReport:        return "Reading schedule data…"
            case .complete:              return "Done"
            case .failed:                return "Failed — see error below."
            }
        }

        var isRunning: Bool {
            switch self {
            case .idle, .complete, .failed: return false
            default: return true
            }
        }
    }

    private var webView: WKWebView!
    private var continuation: CheckedContinuation<[Shift], Error>?
    private let parser = ScheduleParser()

    // MARK: - Init

    private override init() {
        super.init()
        let config = WKWebViewConfiguration()
        // "bridge" lets JS post messages back to Swift (reserved for future use)
        config.userContentController.add(self, name: "bridge")
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
    }

    // Expose the underlying view so ContentView can embed it for debugging.
    func makeWebView() -> WKWebView { webView }

    // MARK: - Public API

    /// Logs in, navigates to the Expanded Schedule Report, scrapes, parses,
    /// saves to ShiftStore, and schedules day-before notifications.
    /// Throws on any failure. Safe to call multiple times.
    func fetchSchedule() async throws -> [Shift] {
        // Prevent re-entrant calls
        guard !phase.isRunning else {
            throw NSError(domain: "BATMANReader", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "A fetch is already in progress."])
        }
        lastError = nil

        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            self.phase = .loadingLogin
            self.webView.load(URLRequest(url: self.loginURL))
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        switch phase {
        case .loadingLogin:
            injectCredentials()
        case .awaitingPostLogin:
            phase = .navigatingToReport
            webView.load(URLRequest(url: reportURL))
        case .navigatingToReport:
            phase = .scrapingReport
            scrapeReport()
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail("Navigation error: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        fail("Could not reach server: \(error.localizedDescription)")
    }

    // MARK: - Step 1: Credential injection

    private func injectCredentials() {
        phase = .injectingCredentials
        let settings = SettingsManager.shared
        let user = settings.username.jsEscaped
        let pass = settings.password.jsEscaped

        // ── UPDATE SELECTORS IF NEEDED ────────────────────────────────
        // These target the most common ARIS/WorkNet login field names.
        // If login fails with NO_FIELDS, inspect the page source and
        // update the querySelector strings below.
        let js = """
        (function() {
            var u = document.querySelector("input[name='username']")
                 || document.querySelector("input[name='j_username']")
                 || document.querySelector("input[type='text']");
            var p = document.querySelector("input[name='password']")
                 || document.querySelector("input[name='j_password']")
                 || document.querySelector("input[type='password']");

            if (!u || !p) { return 'NO_FIELDS'; }

            u.value = '\(user)';
            p.value = '\(pass)';

            // Trigger framework-level change events so JS-driven forms register the fill
            ['input','change'].forEach(function(ev) {
                u.dispatchEvent(new Event(ev, {bubbles:true}));
                p.dispatchEvent(new Event(ev, {bubbles:true}));
            });

            var form = p.closest('form') || document.querySelector('form');
            if (!form) { return 'NO_FORM'; }

            form.submit();
            return 'SUBMITTED';
        })();
        """

        webView.evaluateJavaScript(js) { [weak self] result, error in
            guard let self else { return }
            if let error {
                self.fail("Credential JS error: \(error.localizedDescription)")
                return
            }
            switch result as? String {
            case "SUBMITTED":
                self.phase = .awaitingPostLogin
            case "NO_FIELDS":
                self.fail("Login fields not found. Open WebController.swift and update the querySelector selectors.")
            case "NO_FORM":
                self.fail("Login form not found. Try targeting the submit button instead.")
            default:
                self.fail("Unexpected login result: \(result ?? "nil")")
            }
        }
    }

    // MARK: - Step 2: Scrape the full page HTML

    private func scrapeReport() {
        webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, error in
            guard let self else { return }
            if let error {
                self.fail("Could not read report HTML: \(error.localizedDescription)")
                return
            }
            guard let html = result as? String, !html.isEmpty else {
                self.fail("Report page returned empty HTML. Verify reportURL is correct.")
                return
            }
            self.processReport(html)
        }
    }

    // PHASE 2 (automation): `report` will be the CSV captured from the report
    // download. The parser keys on the user's employee ID (== Settings username).
    private func processReport(_ report: String) {
        Task {
            do {
                let shifts = try parser.parse(csv: report, targetWorkerID: SettingsManager.shared.username)

                // 1. Persist + diff + sync personal calendar events
                let diff = await ShiftStore.shared.save(shifts)

                // 2. Rebuild availability for off days on shared calendar
                await AvailabilityManager.shared.buildFromSchedule()

                // 3. Reschedule all day-before notifications
                await NotificationManager.shared.scheduleAll(for: shifts)

                let workingCount = shifts.filter { !$0.isOff }.count
                phase     = .complete
                lastError = nil
                continuation?.resume(returning: shifts)
                continuation = nil

                print("✅ BATMANReader: \(workingCount) shifts. \(diff.summary)")
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    // MARK: - JS bridge (reserved for future interactive use)

    func userContentController(_ controller: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        // Future: handle interactive bridge messages here
        print("Bridge message: \(message.body)")
    }

    // MARK: - Error handling

    private func fail(_ message: String) {
        phase = .failed
        lastError = message
        print("❌ BATMANReader WebController: \(message)")
        continuation?.resume(throwing: NSError(
            domain: "BATMANReader",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        ))
        continuation = nil
    }
}

// MARK: - String extension

private extension String {
    /// Escapes a string for safe embedding in a JS single-quoted string literal.
    var jsEscaped: String {
        self
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'",  with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
