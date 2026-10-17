import SwiftUI

@MainActor
struct NativeEnrollmentView: View {
    let launch: NativeAppLaunch
    var pending: NativeEnrollmentRecord? = nil
    @State private var pastedInvitation = ""
    private var flow: NativeGuidedJoinCoordinator { launch.guidedJoin }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let message = flow.message {
                        Label(message, systemImage: "info.circle")
                            .font(.caption).padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if launch.diagnostics.hasEvents {
                        ShareLink(item: launch.diagnostics.shareText) {
                            Label("Share diagnostic history", systemImage: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier("enrollment-client-diagnostics-share")
                    }
                    content
                    if flow.canOpenInvitationEntry {
                        Button("Use another invitation") { flow.openInvitationEntry() }.buttonStyle(.bordered)
                    }
                    if flow.busy { ProgressView("Contacting the invited server") }
                }
                .padding(20).frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(title)
            .toolbar {
                if flow.screen == .confirmation || flow.currentAccount?.isApproved == true {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Not now") { Task { await flow.keepCurrentAccount() } }
                    }
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch flow.screen {
        case .welcome:
            heading("Welcome to Harklight", symbol: "envelope.open")
            Text("To join a server, open the invitation link its owner sent you on this device.")
            card {
                Text("I got a link").font(.headline)
                Text("Tap the link in the message. It opens here on its own.").foregroundStyle(.secondary)
            }
            card {
                Text("Link won't open?").font(.headline)
                Text("Paste the full invitation the owner sent you. Harklight checks it before you choose Join.")
                SecureField("Full invitation", text: $pastedInvitation)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("Full invitation")
                primary("Check invitation") {
                    let invitation = pastedInvitation
                    pastedInvitation = ""
                    Task { await flow.pasteInvitation(invitation) }
                }
            }
            Text("Don't have an invitation? Ask the person who runs the server. There is nothing to assemble here first.")
                .font(.footnote).foregroundStyle(.secondary)
        case .verifying:
            heading("Checking the invitation", symbol: "shield")
            Text("Confirming that the invited server is the one this link expects.")
        case .confirmation:
            heading("Join \(flow.invitation?.serverName ?? "this server")?", symbol: "person.badge.plus")
            Text("\(flow.invitation?.approvingOwnerLabel ?? "The owner") invited this device.")
            destination
            card {
                labeled("You join as", flow.invitation?.claimedAccountLabel ?? "The invited account")
                Text("This is what the invitation says. The server confirms the account when you join.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            card {
                Text("This device").font(.caption).foregroundStyle(.secondary)
                TextField("Device name", text: Binding(get: { flow.deviceName }, set: { flow.deviceName = $0 }))
                    .accessibilityLabel("This device's name")
            }
            primary("Join") { Task { await flow.join() } }
            Text("The owner still has to approve this device. Joining lets it receive requests; it gets no owner or sender rights.")
                .font(.footnote).foregroundStyle(.secondary)
        case .joining:
            heading("Joining…", symbol: "person.badge.plus")
            Text("This device creates and keeps its own identity, then sends one join request.")
            Text("Nothing private needs to be shared or typed.").foregroundStyle(.secondary)
        case .pending:
            heading(flow.attempt?.cancellationRequested == true ? "Confirming cancellation" : "Waiting for approval", symbol: "clock")
            if flow.attempt?.cancellationRequested == true {
                Text("Your cancellation is saved. Harklight will not renew this join while it confirms the outcome.")
            } else {
                Text("Waiting for \(flow.invitation?.approvingOwnerLabel ?? "the server owner").")
            }
            requestDetails
            if let code = flow.currentApprovalCode, let deadline = flow.attempt?.approvalExpiresAt {
                card {
                    Text("Last confirmed approval code").font(.caption).foregroundStyle(.secondary)
                    Text(code).font(.title.monospaced().weight(.bold)).textSelection(.enabled)
                        .accessibilityLabel("Approval code \(code)")
                    Text("Approval window closes \(Date(timeIntervalSince1970: Double(deadline) / 1000), format: .dateTime.month().day().hour().minute()).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if flow.attempt?.cancellationRequested != true, flow.attempt?.approvalCode != nil {
                Text("The saved approval details have not been confirmed as current. Harklight will refresh this request when it reaches the server.")
                    .foregroundStyle(.secondary)
            }
            primary("Check again") { Task { await flow.retry() } }
            if flow.attempt?.cancellationRequested != true {
                Button("Cancel this request") { Task { await flow.cancelRequest() } }
                    .buttonStyle(.bordered).disabled(flow.busy)
            }
            Text("You can leave Harklight. It remembers this request and picks up where you left off.")
                .font(.footnote).foregroundStyle(.secondary)
        case .unreachable:
            heading("Can't reach the server", symbol: "wifi.slash")
            requestDetails
            Text(flow.attempt == nil ? "No join request has been sent. Check Wi-Fi or cellular, then try again." :
                 "The current approval state could not be checked. Your request and this device's identity are saved. Check Wi-Fi or cellular, then try again.")
            primary("Try again") { Task { await flow.retry() } }
            if flow.attempt != nil {
                Button("Cancel this request") { Task { await flow.cancelRequest() } }
                    .buttonStyle(.bordered).disabled(flow.busy)
            }
            Text(flow.attempt == nil ? "Trying again checks the invited server before you join." :
                 "Trying again continues the same saved request. It will not ask the owner twice.")
                .font(.footnote).foregroundStyle(.secondary)
        case .approvedFinishing:
            heading("Approved, finishing up", symbol: "checkmark.shield")
            Text("The owner approved this device. Harklight is confirming its connection to the server.")
            Text("Not connected yet.").foregroundStyle(.secondary)
            if let progress = launch.foregroundConnectProgress {
                VStack(alignment: .leading, spacing: 8) {
                    if progress.outcome == .connecting { ProgressView() }
                    Text(progress.message)
                        .font(.callout)
                        .accessibilityIdentifier("foreground-connect-progress")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            if let diagnostic = launch.foregroundConnectDiagnostic {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connection details include the app build, observed phase and queued-operation receipt state. Answers and credentials are excluded.")
                        .font(.footnote).foregroundStyle(.secondary)
                    ShareLink(item: diagnostic.shareText) {
                        Label("Share connection details", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("foreground-connect-diagnostics")
                }
            }
            primary("Try again") { Task { await flow.retry() } }
                .disabled(flow.busy)
        case .connected:
            heading("Connected", symbol: "checkmark.circle")
            Text("\(flow.currentAccount?.deviceLabel ?? flow.deviceName) is now part of \(flow.currentAccount?.serverDisplayName ?? flow.invitation?.serverName ?? "Harklight").")
            Text("Requests for this account will show up here.")
            primary("Continue") { flow.continueConnected() }
        case .notifications:
            heading("Hear about requests when Harklight is closed", symbol: "bell")
            Text("Requests can wait on someone's answer. With notifications on, this device can tell you when one arrives.")
            Text("Without them, you will still see requests when you open Harklight.").foregroundStyle(.secondary)
            primary("Turn on notifications") { Task { await flow.chooseNotifications(true) } }
            Button("Not now") { Task { await flow.chooseNotifications(false) } }.buttonStyle(.bordered)
        case .invitationExpired:
            heading("This invitation expired", symbol: "clock.badge.xmark")
            Text("This invitation cannot add a device now. Ask the owner for a fresh invitation.")
        case .approvalExpired:
            if flow.attempt?.cancellationRequested == true {
                heading("Confirming cancellation", symbol: "clock")
                Text("Your cancellation is saved. Harklight will check again when it can reach the server and will not renew this join.")
                primary("Try again") { Task { await flow.retry() } }
            } else {
                heading("Continuing your join", symbol: "clock.arrow.circlepath")
                Text("The previous approval window ended. Harklight keeps this device's identity and renews the same request when it can reach the server.")
                Text("No new invitation or Join is needed. The owner must still approve this device.")
                primary("Try again") { Task { await flow.retry() } }
                Button("Cancel this request") { Task { await flow.cancelRequest() } }
                    .buttonStyle(.bordered).disabled(flow.busy)
            }
        case .invitationUsed:
            heading("This invitation was already used", symbol: "exclamationmark.shield")
            Text("Each invitation adds one device. If another request was not yours, tell the owner before asking for a new invitation.")
        case .declined:
            heading("The owner declined this device", symbol: "xmark.circle")
            Text("This device was not added. If that was a mistake, ask the owner for a new invitation.")
        case .revoked:
            heading("This device was revoked", symbol: "xmark.shield")
            Text("This request will not be renewed. Ask the owner if this device should join again.")
        case .cancelled:
            heading("Request cancelled", symbol: "xmark.circle")
            Text("The server confirmed cancellation. This device was not added. Ask the owner for a fresh invitation if you want to join later.")
            primary("Done") { Task { await flow.keepCurrentAccount() } }
        case .refused:
            heading("Joining could not be confirmed", symbol: "exclamationmark.shield")
            Text("Ask the owner for help or a new invitation. Your current account has been kept.")
        case .existingAccount:
            heading("This device is already joined", symbol: "person.crop.circle.badge.checkmark")
            card {
                Text("Current account").font(.headline)
                labeled("Server", flow.currentAccount?.serverDisplayName ?? flow.currentAccount?.host ?? "Harklight")
                labeled("Joined as", flow.currentAccount?.accountDisplayName ?? "Your account")
            }
            destination
            primary("Keep current account") { Task { await flow.keepCurrentAccount() } }
            Button("Replace with this invitation…") { flow.considerReplacement() }.buttonStyle(.bordered)
        case .replacementConfirmation:
            heading("Replace this account?", symbol: "arrow.triangle.2.circlepath")
            Text("The current server must confirm removing this device before Harklight replaces its account. You would need another invitation to return.")
            primary("Remove and replace") { Task { await flow.confirmReplacement() } }
            Button("Keep current account") { Task { await flow.keepCurrentAccount() } }.buttonStyle(.bordered)
        }
    }

    private var title: String {
        switch flow.screen {
        case .welcome: return "Harklight"
        case .connected: return "Connected"
        case .notifications: return "Notifications"
        case .confirmation, .verifying, .invitationExpired, .invitationUsed, .refused,
             .existingAccount, .replacementConfirmation: return "Invitation"
        default: return "Joining"
        }
    }

    private var destination: some View {
        card {
            labeled("Server", flow.invitation?.serverName ?? "Invited server")
            labeled("Verified address", flow.invitation?.enrollmentURL.host ?? "")
            Text("This address is the server the invitation expects. The account name is a claim until the server confirms it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var requestDetails: some View {
        card {
            labeled("Server", flow.invitation?.serverName ?? "Invited server")
            labeled("Device", flow.attempt?.deviceLabel ?? flow.deviceName)
            labeled("Joining as", flow.invitation?.claimedAccountLabel ?? "The invited account")
        }
    }

    private func heading(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.title2.weight(.semibold))
    }

    private func labeled(_ caption: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption).font(.caption).foregroundStyle(.secondary)
            Text(value)
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.25)))
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule).disabled(flow.busy)
    }
}
