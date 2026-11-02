import SwiftUI
import ServiceManagement
import UserNotifications
import AIQuotaKit
import MobileAccessCore

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General", accounts = "Accounts", notifications = "Notifications", about = "About"
    var id: Self { self }
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .accounts: "person.crop.circle"
        case .notifications: "bell"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var page: SettingsPage = .general

    var body: some View {
        TabView(selection: $page) {
            ForEach(SettingsPage.allCases) { item in
                Group {
                    switch item {
                    case .general: GeneralSettingsPane()
                    case .accounts: AccountsSettingsPane()
                    case .notifications: NotificationsSettingsPane()
                    case .about: AboutSettingsPane()
                    }
                }
                .tabItem { Label(item.rawValue, systemImage: item.icon) }
                .tag(item)
            }
        }
        .background(SettingsWindowPresentation())
        .frame(minWidth: 540, idealWidth: 600, minHeight: 560, idealHeight: 650)
        .tint(Color.brand)
        .onChange(of: viewModel.settings) {
            if !viewModel.isReadOnlyPreview { viewModel.saveSettings() }
        }
    }
}
