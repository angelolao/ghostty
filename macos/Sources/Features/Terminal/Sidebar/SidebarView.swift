import SwiftUI
import UniformTypeIdentifiers

/// A vertical sidebar that displays the list of tabs for the current window group.
struct SidebarView: View {
    @ObservedObject var tabManager: SidebarTabManager
    var activeTabColor: Color?
    var titleFontSize: CGFloat = 12
    var subtitleFontSize: CGFloat = 10
    @State private var draggingTabID: ObjectIdentifier?
    @State private var dropTargetTabID: ObjectIdentifier?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
                    SidebarTabCard(tab: tab, activeTabColor: activeTabColor, titleFontSize: titleFontSize, subtitleFontSize: subtitleFontSize)
                        .contentShape(Rectangle())
                        .opacity(draggingTabID == tab.id ? 0.4 : 1.0)
                        .overlay(alignment: .top) {
                            if dropTargetTabID == tab.id && draggingTabID != tab.id {
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(height: 2)
                                    .offset(y: -3)
                            }
                        }
                        .onTapGesture {
                            tabManager.selectTab(tab)
                        }
                        .onDrag {
                            draggingTabID = tab.id
                            return NSItemProvider(object: "\(index)" as NSString)
                        }
                        .onDrop(of: [UTType.text], delegate: TabDropDelegate(
                            tabManager: tabManager,
                            currentTab: tab,
                            currentIndex: index,
                            draggingTabID: $draggingTabID,
                            dropTargetTabID: $dropTargetTabID
                        ))
                        .contextMenu {
                            Button("Rename Tab...") {
                                tabManager.promptRenameTab(tab)
                            }

                            Divider()

                            Button("Close Tab") {
                                tabManager.closeTab(tab)
                            }

                            Button("Close Other Tabs") {
                                tabManager.closeOtherTabs(tab)
                            }
                            .disabled(tabManager.tabs.count <= 1)

                            Button("Close Tabs to the Right") {
                                tabManager.closeTabsToTheRight(of: tab)
                            }
                            .disabled({
                                guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tab.id }) else { return true }
                                return idx >= tabManager.tabs.count - 1
                            }())
                        }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct TabDropDelegate: DropDelegate {
    let tabManager: SidebarTabManager
    let currentTab: SidebarTabManager.TabItem
    let currentIndex: Int
    @Binding var draggingTabID: ObjectIdentifier?
    @Binding var dropTargetTabID: ObjectIdentifier?

    func dropEntered(info: DropInfo) {
        dropTargetTabID = currentTab.id
    }

    func dropExited(info: DropInfo) {
        if dropTargetTabID == currentTab.id {
            dropTargetTabID = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        draggingTabID != nil && draggingTabID != currentTab.id
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggingTabID else { return false }
        guard let sourceIndex = tabManager.tabs.firstIndex(where: { $0.id == draggingTabID }) else { return false }

        tabManager.moveTab(from: sourceIndex, to: currentIndex)

        self.draggingTabID = nil
        self.dropTargetTabID = nil
        return true
    }
}

private struct SidebarTabCard: View {
    let tab: SidebarTabManager.TabItem
    var activeTabColor: Color?
    var titleFontSize: CGFloat = 12
    var subtitleFontSize: CGFloat = 10

    private var branch: String? { tab.metadata["branch"] }

    private var activeTabBackground: Color {
        activeTabColor?.opacity(0.25) ?? Color.accentColor.opacity(0.12)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Title row
            HStack(spacing: 6) {
                Text(tab.displayTitle)
                    .font(.system(size: titleFontSize, weight: tab.isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundColor(tab.isSelected ? .primary : .secondary)

                Spacer()

                if tab.needsAttention {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 8, height: 8)
                }
            }

            // Info row: directory and/or git branch
            if tab.directoryName != nil || branch != nil {
                HStack(spacing: 10) {
                    if let dir = tab.directoryName {
                        Text(dir)
                            .font(.system(size: subtitleFontSize))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    if let branch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .font(.system(size: subtitleFontSize))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()
                }
            }

            // Custom metadata (anything other than "branch")
            let extraMeta = tab.metadata.filter { $0.key != "branch" }
            if !extraMeta.isEmpty {
                HStack(spacing: 10) {
                    ForEach(Array(extraMeta.keys.sorted()), id: \.self) { key in
                        if let value = extraMeta[key] {
                            Text("\(key): \(value)")
                                .font(.system(size: subtitleFontSize))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(tab.isSelected
                    ? activeTabBackground
                    : Color.clear)
        )
    }
}
