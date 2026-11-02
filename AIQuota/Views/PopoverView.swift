import SwiftUI
import QuartzCore
import AIQuotaKit
import MobileAccessCore

struct PopoverView: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @Environment(UpdaterViewModel.sel