import SwiftUI
import QuartzCore
import AIQuotaKit
import MobileAccessCore

struct PopoverView: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @Environment(UpdaterViewModel.self) private var updater
    @Environment(\.openSettings) private var openSettings

    /// Captured reference so opening Settings can dismiss the menu bar panel.
    @State private var menuBarWindow: NSWindow?
    @State private var selectedService: ServiceType?
    @State private var selectedAccountID: String?
    @State private var hoveredService: ServiceType?
    @State private var focusedService: ServiceType?
    @State private var overviewHeight: CGFloat?
    @State private var headerHeight: CGFloat = 64
    @State private var footerHeight: CGFloat = 50
    @State private var updateHeight: CGFloat = 0
    @State private var quotaInsightHeight: CGFloat = 0
    @State private var navigationPhase: PopoverNavigationPhase = .overview
    @State private var presentationID = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var resetNotice = CodexResetNotice()
    @AppStorage(CodexResetNotice.dismissalKey) private var dismissedResetID = ""
    @State private var demoResetDismissed = false
    @State private var showResetDetails = false

    private var resetAnnouncement: CodexResetAnnouncement? {
        #if DEMO_MODE
        demoResetDismissed ? nil : CodexResetNotice.demoAnnouncement
        #else
        resetNotice.announcement(dismissedID: dismissedResetID)
        #endif
    }

    private var overviewWidth: CGFloat {
        let visibleWidth = (menuBarWindow?.screen ?? NSScreen.main)?.visibleFrame.width ?? 800
        let accountCount = viewModel.enrolledServices.count + viewModel.additionalAccounts.count
        let ideal: CGFloat = accountCount == 1 ? 420 : 480
        return min(ideal, max(280, visibleWidth - 16))
    }
    private var overviewBodyMaxHeight: CGFloat {
        let screen = menuBarWindow?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 800)
        let top = menuBarWindow?.frame.maxY ?? visible.maxY
        let available = min(visible.height * 0.88, top - visible.minY - 16)
        return max(1, available - headerHeight - footerHeight - updateHeight)
    }
    private var overviewSize: CGSize {
        CGSize(width: overviewWidth, height: overviewHeight ?? 400)
    }
    private var detailSize: CGSize {
        let screen = menuBarWindow?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 800)
        let top = menuBarWindow?.frame.maxY ?? visible.maxY
        let availableHeight = max(120, min(visible.height - 16, top - visible.minY - 12))
        // Keep the native panel's horizontal bounds fixed while navigating.
        // With two accounts the former 652 -> 460 point resize visibly swept
        // the detail sheet sideways from its menu-bar anchor.
        // Keep the sheet's height when entering details. A fixed detail cap
        // made a four-account overview visibly shrink on every card click.
        // Smaller overviews can expand to a useful scroll viewport.
        let preferredHeight = max(overviewSize.height, 540)
        return CGSize(width: overviewWidth, height: min(availableHeight, preferredHeight))
    }
    private var popoverSize: CGSize {
        navigationPhase.isExpanded ? detailSize : overviewSize
    }
    private var popoverLayoutSize: CGSize {
        // Publishing the compact ideal early makes MenuBarExtra resize the
        // window before AppKit can animate it. Commit it after the native close.
        navigationPhase == .shrinking ? detailSize : popoverSize
    }

    var body: some View {
        MenuBarPopoverHost(
            content: AnyView(pageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .environment(viewModel).environment(updater)),
            size: popoverSize,
            layoutSize: popoverLayoutSize,
            animateResize: !reduceMotion && navigationPhase.resizesWindow,
            presentationID: presentationID,
            onCapture: { menuBarWindow = $0 },
            onResizeFinished: finishNavigationResize
        )
        .sheet(isPresented: $showResetDetails) { MacResetDetailsView() }
        .onAppear { presentationID += 1 }
        .task(id: viewModel.isCodexAuthenticated) {
            #if !DEMO_MODE
            guard !viewModel.isReadOnlyPreview, viewModel.isCodexAuthenticated else { return }
            while !Task.isCancelled {
                await resetNotice.refresh()
                do { try await Task.sleep(for: .seconds(60)) }
                catch { return }
            }
            #endif
        }
        .onDisappear { resetNavigation() }
        .onChange(of: viewModel.enrolledServices) { _, services in
            if let selectedService, !services.contains(selectedService) { resetNavigation() }
        }
    }

    private var pageContent: some View {
        ZStack(alignment: .topLeading) {
            gridAuthenticatedContent
            .frame(width: overviewWidth)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if height > 0, navigationPhase == .overview, overviewHeight != height { overviewHeight = height }
            }
            // Crossfade into the overview before the native window begins its
            // close so the returning panel always has content while shrinking.
            .modifier(PopoverPageVisibility(isVisible: navigationPhase.showsOverview,
                                            reduceMotion: reduceMotion, distance: 0, onHidden: {}))
            .allowsHitTesting(navigationPhase == .overview)
            .accessibilityHidden(navigationPhase != .overview)

            if let selectedService {
                    Group {
                        if let selectedAccountID,
                           let session = viewModel.additionalAccounts.first(where: { $0.id == selectedAccountID }) {
                            MacAdditionalAccountDetailView(session: session, height: detailSize.height,
                                                           close: closeService, openSettings: openSettingsWindow,
                                                           reconnect: {
                                                               Task { await viewModel.reconnectAccount(id: session.id) }
                                                           })
                        } else {
                            ServiceDetailView(service: selectedService, height: detailSize.height,
                                              close: closeService, reconnect: {
                                                  Task {
                                                      switch selectedService {
                                                      case .codex: await viewModel.signIn()
                                                      case .claude: await viewModel.signInClaude()
                                                      case .cursor: await viewModel.signInCursor()
                                                      }
                                                  }
                                              })
                        }
                    }
                    .frame(width: detailSize.width)
                    // A provider can have several accounts. Give each detail
                    // its own navigation and scroll state when switching cards.
                    .id("\(selectedService.rawValue):\(selectedAccountID ?? "primary")")
                    // Start revealing the detail as the window expands. Waiting
                    // for the resize completion leaves a blank full-height panel.
                    .modifier(PopoverPageVisibility(isVisible: navigationPhase.showsDetail,
                                                    reduceMotion: reduceMotion, distance: 6,
                                                    onHidden: finishDetailFade))
                    .allowsHitTesting(navigationPhase == .detail)
                    .accessibilityHidden(navigationPhase != .detail)
            }
        }
        .frame(width: popoverLayoutSize.width, height: popoverLayoutSize.height, alignment: .topLeading)
        .clipped()
        .background { popoverSurface }
        .background {
            Button("") { viewModel.manualRefresh() }
                .keyboardShortcut("r", modifiers: .command)
                .hidden()
        }
    }

    private func finishNavigationResize(_ size: CGSize) {
        guard size == popoverSize else { return }
        switch navigationPhase {
        case .expanding:
            navigationPhase = .detail
        case .shrinking:
            selectedService = nil
            selectedAccountID = nil
            navigationPhase = .overview
        default:
            break
        }
    }

    private func closeService() {
        guard navigationPhase == .detail else { return }
        if reduceMotion {
            resetNavigation()
            return
        }
        navigationPhase = .fadingDetail
    }

    private func finishDetailFade() {
        guard navigationPhase == .fadingDetail else { return }
        if detailSize == overviewSize {
            selectedService = nil
            selectedAccountID = nil
            navigationPhase = .overview
        } else {
            navigationPhase = .shrinking
        }
    }

    private func resetNavigation() {
        selectedService = nil
        selectedAccountID = nil
        navigationPhase = .overview
        hoveredService = nil
        focusedService = nil
        presentationID += 1
    }

    @ViewBuilder
    private var popoverSurface: some View {
        ZStack {
            if #available(macOS 26.0, *) {
   