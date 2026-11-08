import SwiftUI

struct ProfileSwitcher: View {
    let current: AppProfile
    let onSwitch: (AppProfile) -> Void

    var body: some View {
        Menu {
            ForEach(AppProfile.allCases) { profile in
                Button {
                    onSwitch(profile)
                } label: {
                    Label(profile.displayName, systemImage: profile.systemImage)
                }
                .disabled(profile == current)
            }
        } label: {
            Label("\(current.displayName) Profile", systemImage: current.systemImage)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Switch profile")
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
