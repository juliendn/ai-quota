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
                // A partial blur over the menu-bar window's glass. At full
                // strength any SwiftUI material here made the sheet read as opaque;
                // with none, shapes and text behind stayed too sharp.
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(0.7)
            } else {
                // Sequoia's MenuBarExtra material is substantially more transparent
                // than Tahoe's glass treatment. Stabilize contrast while retaining a
                // small amount of desktop color.
                Rectangle()
                    .fill(.regularMaterial)
                    .overlay {
                        Color(nsColor: .windowBackgroundColor).opacity(0.92)
                    }
            }
            sheetTint
        }
    }

    // Plum glass over the window's own glass: a 53% tint (66% in light) lets the
    // desktop through; captions are near-white / deep plum to stay legible.
    private var sheetTint: some View {
        ZStack {
            Color.sheetTint
            EllipticalGradient(colors: [.sheetGlow, .clear], center: .topLeading,
                               startRadiusFraction: 0, endRadiusFraction: 0.75)
            EllipticalGradient(colors: [.sheetGlowTrailing, .clear], center: .bottomTrailing,
                               startRadiusFraction: 0, endRadiusFraction: 0.6)
        }
        .overlay { sheetRim }
        .allowsHitTesting(false)
    }

    // Specular edge, brightest at the top-leading corner, for the Liquid Glass read.
    @ViewBuilder
    private var sheetRim: some View {
        if #available(macOS 26.0, *) {
            ContainerRelativeShape()
                .strokeBorder(
                    LinearGradient(stops: [
                        .init(color: .sheetRim, location: 0),
                        .init(color: .sheetRim.opacity(0.15), location: 0.35),
                        .init(color: .clear, location: 0.6),
                        .init(color: .sheetRim.opacity(0.35), location: 1),
                    ], startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1
                )
        }
    }

    private func openSettingsWindow() {
        menuBarWindow?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

    // MARK: - Authenticated layout

    private var visibleServices: [ServiceType] {
        ServiceType.allCases.filter { viewModel.enrolledServices.contains($0) }
    }

    private func canOpen(_ service: ServiceType) -> Bool {
        switch service {
        case .codex: viewModel.isCodexAuthenticated || viewModel.codexUsage != nil
        case .claude: viewModel.isClaudeAuthenticated || viewModel.claudeUsage != nil
        case .cursor: viewModel.isCursorAuthenticated || viewModel.cursorUsage != nil
        }
    }

    private func openService(_ service: ServiceType) {
        guard canOpen(service), navigationPhase == .overview else { return }
        hoveredService = nil
        focusedService = nil
        selectedService = service
        selectedAccountID = nil
        navigationPhase = reduceMotion || detailSize == overviewSize ? .detail : .expanding
    }

    private func openAccount(_ account: ConnectedAccount) {
        guard navigationPhase == .overview else { return }
        if account.connectionKind == .legacyPrimary {
            openService(account.provider)
        } else {
            selectedService = account.provider
            selectedAccountID = account.id
            navigationPhase = reduceMotion || detailSize == overviewSize ? .detail : .expanding
        }
    }

    private var gridAuthenticatedContent: some View {
        VStack(spacing: 0) {
            header
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            MacAccountGridView(width: overviewWidth, maxHeight: overviewBodyMaxHeight,
                               openAccount: openAccount, openSettings: openSettingsWindow,
                               leadingContent: AnyView(overviewNotices), connect: connectService)
            updateAvailableRow
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { updateHeight = $0 }
            footer
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
    }

    private var hasOverviewNotices: Bool {
        !errorBanners.isEmpty || (viewModel.isCodexAuthenticated && resetAnnouncement != nil)
            || quotaInsightHeight > 0
    }

    private var overviewNotices: some View {
        VStack(spacing: 0) {
            ForEach(errorBanners) { banner in
                errorBanner(banner).padding(.bottom, 8)
            }
            groupedAlerts(inset: false)
                .padding(.bottom, quotaInsightHeight > 0 ? 16 : 0)
        }
    }

    private func groupedAlerts(inset: Bool) -> some View {
        MacQuotaInsightRow(inset: inset,
            announcementTitle: viewModel.isCodexAuthenticated ? resetAnnouncement?.title : nil,
            onReadMore: { showResetDetails = true },
            onDismissAnnouncement: {
                #if DEMO_MODE
                demoResetDismissed = true
                #else
                if let announcement = resetAnnouncement { dismissedResetID = announcement.id }
                #endif
            }, onHeightChange: { quotaInsightHeight = $0 })
    }

    private func connectService(_ service: ServiceType) {
        Task {
            switch service {
            case .codex: await viewModel.signIn()
            case .claude: await viewModel.signInClaude()
            case .cursor: await viewModel.signInCursor()
            }
        }
    }

    private func service(at x: CGFloat) -> ServiceType? {
        guard !visibleServices.isEmpty else { return nil }
        let column = min(visibleServices.count - 1, max(0, Int(x / (overviewWidth / CGFloat(visibleServices.count)))))
        return visibleServices[column]
    }

    // One tracking region spans both rows, including their padding and divider.
    // Child controls such as Refresh and Connect keep their own button actions.
    private var serviceArea: some View {
        VStack(spacing: 0) {
            gaugeRow.padding(.top, 16).padding(.bottom, 10)
            statsRow
        }
        .contentShape(Rectangle())
        .background {
            HStack(spacing: 0) {
                ForEach(visibleServices, id: \.self) { service in
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.quaternary)
                        .foregroundStyle(.primary)
                        .opacity(hoveredService == service || focusedService == service ? 1 : 0)
                        .frame(maxWidth: .infinity)
                        .padding(5)
                }
            }.allowsHitTesting(false)
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                hoveredService = service(at: location.x).flatMap { canOpen($0) ? $0 : nil }
            case .ended:
                hoveredService = nil
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hoveredService)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: focusedService)
        .onTapGesture(coordinateSpace: .local) { location in
            if let service = service(at: location.x) { openService(service) }
        }
    }

    private func serviceTarget<Content: View>(_ service: ServiceType, @ViewBuilder content: () -> Content) -> some View {
        let name = service.displayName
        return ServiceFocusRegion(enabled: canOpen(service) && navigationPhase == .overview,
                                  content: content()) { focused in
            if focused {
                focusedService = service
            } else if focusedService == service {
                focusedService = nil
            }
        }
            .onKeyPress(keys: [.return, .space]) { _ in
                guard canOpen(service) else { return .ignored }
                openService(service)
                return .handled
            }
            .accessibilityAction(named: Text("View \(name) details")) { openService(service) }
            .accessibilityHint(canOpen(service) ? "Opens \(name) analytics and statistics" : "")
    }

    @ViewBuilder
    private var authenticatedContent: some View {
        VStack(spacing: 0) {
            header

            ForEach(errorBanners) { banner in
                errorBanner(banner)
                Divider()
            }

            groupedAlerts(inset: true)

            serviceArea

            updateAvailableRow
            footer
        }
    }

    // MARK: - Gauge slots

    @ViewBuilder
    private var codexGaugeSlot: some View {
        if viewModel.isCodexAuthenticated {
            if let u = viewModel.codexUsage {
                if u.reportedWindowShape == nil,
                   let budget = u.monthlyBudget,
                   let used = budget.used, let limit = budget.limit,
                   used.isFinite, used >= 0, limit.isFinite, limit > 0 {
                    BudgetGaugeView(
                        used: used, limit: limit,
                        usedText: budgetValue(used, unit: budget.unit),
                        limitText: budgetValue(limit, unit: budget.unit),
                        unitLabel: budget.unit?.lowercased() == "credit" ? "credits this month"
                            : (budget.unit?.lowercased() == "usd" ? "monthly spend" : "monthly allowance"),
                        icon: "logo-openai", label: "Codex", resetAt: budget.resetAt,
                        readingAt: u.fetchedAt,
                        isRefreshing: viewModel.isCodexLoading,
                        onRefresh: { viewModel.manualRefresh() }
                    )
                } else if u.reportedWindowShape != nil {
                    let hasHourlyWindow = u.reportedWindowShape == .dual
                    CircularGaugeView(
                        primaryPercent: hasHourlyWindow ? u.hourlyUsedPercent : u.weeklyUsedPercent,
                        primaryLimitReached: hasHourlyWindow ? u.hourlyUsedPercent >= 100 : u.isWeeklyExhausted,
                        showsPrimaryMetric: true,
                        secondaryPercent: u.weeklyUsedPercent,
                        secondaryLimitReached: u.isWeeklyExhausted,
                        showsSecondaryMetric: hasHourlyWindow,
                        isLoading: false,
                        icon: "logo-openai",
                        label: "Codex",
                        primaryLabel: hasHourlyWindow ? formatWindowDuration(u.hourlyWindowSeconds) : "7d",
                        secondaryLabel: "7d",
                        resetAt: hasHourlyWindow ? (u.hourlyResetAt == .distantFuture ? nil : u.hourlyResetAt) : (u.weeklyResetAt == .distantFuture ? nil : u.weeklyResetAt),
                        weeklyResetAt: u.weeklyResetAt == .distantFuture ? nil : u.weeklyResetAt,
                        isRefreshing: viewModel.isCodexLoading,
                        onRefresh: { viewModel.manualRefresh() }
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Codex usage")
                    .accessibilityValue(codexAccessibilitySummary(u))
                } else {
                    unavailableCodexUsage
                }
            } else {
                if viewModel.isCodexLoading {
                    CircularGaugeView(
                        primaryPercent: 0, primaryLimitReached: false,
                        showsPrimaryMetric: true,
                        secondaryPercent: 0, secondaryLimitReached: false,
                        showsSecondaryMetric: true,
                        isLoading: true, icon: "logo-openai",
                        label: "Codex", primaryLabel: "5h", secondaryLabel: "7d",
                        resetAt: nil, weeklyResetAt: nil, isRefreshing: true, onRefresh: {}
                    )
                } else {
                    unavailableCodexUsage
                }
            }
        } else if viewModel.isCodexRecovering {
            loadingGauge(icon: "logo-openai", label: "Codex")
        } else {
            connectGauge(icon: "logo-openai", label: "Codex") {
                Task { await viewModel.signIn() }
            }
        }
    }

    @ViewBuilder
    private var claudeGaugeSlot: some View {
        if viewModel.isClaudeAuthenticated {
            if let u = viewModel.claudeUsage {
                if u.primaryMetric.kind == .spendLimit,
                   let spend = u.spendLimit,
                   spend.used.isFinite, spend.used >= 0,
                   spend.limit.isFinite, spend.limit > 0 {
                    BudgetGaugeView(
                        used: spend.used, limit: spend.limit,
                        usedText: budgetValue(spend.used, unit: spend.currencyCode),
                        limitText: budgetValue(spend.limit, unit: spend.currencyCode),
                        unitLabel: spend.currencyCode?.uppercased() == "USD" ? "monthly spend" : "monthly allowance",
                        icon: "logo-claude", label: "Claude Code", resetAt: nil,
                        readingAt: u.fetchedAt,
                        isRefreshing: viewModel.isClaudeLoading,
                        onRefresh: { viewModel.manualRefresh() }
                    )
                } else {
                    CircularGaugeView(
                        primaryPercent: u.usedPercent,
                        primaryLimitReached: u.limitReached,
                        showsPrimaryMetric: true,
                        secondaryPercent: Int(u.sevenDayUtilization?.rounded() ?? 0),
                        secondaryLimitReached: (u.sevenDayUtilization ?? 0) >= 100,
                        showsSecondaryMetric: u.primaryMetric.kind != .sevenDay && u.sevenDayUtilization != nil,
                        isLoading: false,
                        icon: "logo-claude",
                        label: "Claude Code",
                        primaryLabel: u.primaryMetricLabel,
                        secondaryLabel: "7d",
                        resetAt: u.resetAt,
                        weeklyResetAt: u.sevenDayResetsAt,
                        isRefreshing: viewModel.isClaudeLoading,
                        onRefresh: { viewModel.manualRefresh() }
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Claude usage")
                    .accessibilityValue(claudeAccessibilitySummary(u))
                }
            } else {
                CircularGaugeView(
                    primaryPercent: 0, primaryLimitReached: false,
                    showsPrimaryMetric: true,
           