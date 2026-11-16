import SwiftUI
import UIKit

@main
struct NikonUSBExportApp: App {
    @StateObject private var connection = IOSConnection()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ExportHome(connection: connection, model: connection.camera)
                .onChange(of: phase, initial: true) { _, new in
                    switch new {
                    case .active: Task { await connection.connect(requestAccess: false) }
                    case .background: connection.suspend()
                    default: break
                    }
                }
        }
    }
}

private struct FolderLocation: Hashable {
    let storeID: UInt32
    let parent: Entry?
}

private struct ExportHome: View {
    @ObservedObject var connection: IOSConnection
    @ObservedObject var model: CameraModel
    @Environment(\.openURL) private var openURL
    @State private var path = [FolderLocation]()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("USB 相机") {
                    switch connection.access {
                    case .waiting:
                        Text("连接 Nikon Z 8 的 USB 数据口，在机身上选择 MTP/PTP。")
                        Button("允许访问相机") { Task { await connection.connect(requestAccess: true) } }
                    case .requesting: ProgressView("正在请求相机访问权限")
                    case .denied:
                        Text("请在系统设置中允许访问外接相机，再返回应用。")
                        Button("打开设置") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                    case .ready:
                        if model.scanning { ProgressView(model.status) }
                        else { Label(model.status, systemImage: "camera") }
                    }
                }
                if !model.catalog.stores.isEmpty || !model.catalog.failedStores.isEmpty {
                    Section("存储卡") {
                        ForEach(model.catalog.stores) { store in
                            NavigationLink(value: FolderLocation(storeID: store.id, parent: nil)) {
                                VStack(alignment: .leading) {
                                    Text(model.catalog.slots[store.id].map { "\($0.title) · \($0.medium)" } ?? "待核对卡槽")
                                    Text([store.label, store.hexID].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        ForEach(model.catalog.failedStores) { failure in
                            Label(failure.localizedDescription, systemImage: "exclamationmark.triangle")
                        }
                        if model.catalog.canExportBoth {
                            Button("导出两张卡的全部照片") { model.export(.both) }
                                .disabled(model.exporting || model.destination == nil)
                        }
                    }
                }
                Section("导出位置") {
                    if let error = connection.folderError {
                        Text(error).foregroundStyle(.red)
                        Button("重试") { Task { await connection.connect(requestAccess: false) } }
                    } else {
                        Label("文件 › \(UIDevice.current.userInterfaceIdiom == .pad ? "我的 iPad" : "我的 iPhone") › Nikon USB Export",
                              systemImage: "folder")
                    }
                }
            }
            .navigationTitle("相机导出")
            .navigationDestination(for: FolderLocation.self) { location in
                if let store = model.catalog.stores.first(where: { $0.id == location.storeID }) {
                    CameraFolder(model: model, store: store, parent: location.parent)
                } else {
                    ContentUnavailableView("目录已变化", systemImage: "arrow.clockwise")
                }
            }
            .toolbar {
                if connection.access == .ready {
                    Button("刷新目录", systemImage: "arrow.clockwise") { model.refresh() }
                        .disabled(!model.canRefresh)
                }
            }
        }
        .onChange(of: model.catalog.stores.map(\.id)) { _, _ in path.removeAll() }
        .safeAreaInset(edge: .bottom) {
            if let report = model.report {
                VStack(alignment: .leading, spacing: 4) {
                    if model.exporting {
                        ProgressView(value: Double(report.processed), total: Double(max(1, report.total)))
                        Text(report.current).lineLimit(1).truncationMode(.middle)
                    } else {
                        Text(report.summary).textSelection(.enabled)
                        if !report.conflicts.isEmpty { ShareLink("分享冲突清单", item: report.conflicts.joined(separator: "\n")) }
                    }
                }
                .font(.footnote).padding().frame(maxWidth: .infinity, alignment: .leading).background(.bar)
            }
        }
    }
}

private struct CameraFolder: View {
    @ObservedObject var model: CameraModel
    let store: Storage
    let parent: Entry?
    @State private var selection = Set<UInt32>()
    @State private var confirming = false
    private var slot: Slot? { model.catalog.slots[store.id] }
    private var rows: [Entry] { store.children[parent?.id ?? 0] ?? [] }

    var body: some View {
        List {
            Section {
                if store.reportedSlot == nil {
                    Button(slot == nil ? "核对卡槽" : "更改卡槽关联") { confirming = true }
                        .disabled(model.exporting)
                }
                if let slot {
                    Button(parent == nil ? "导出\(slot.title)全部照片" : "导出此目录及子目录") {
                        if let parent { model.export(.folder(storage: store.id, path: parent.path)) }
                        else { model.export(.card(slot)) }
                    }
                    .disabled(model.exporting || model.destination == nil)
                    if !selection.isEmpty {
                        Button("导出所选照片（\(selection.count)）") {
                            model.export(.photos(storage: store.id, parent: parent?.id ?? 0, ids: selection))
                        }.disabled(model.exporting || model.destination == nil)
                    }
                }
            }
            Section {
                if rows.isEmpty { Text("此目录没有照片或子目录").foregroundStyle(.secondary) }
                ForEach(rows) { row in
                    if row.object.isFolder {
                        NavigationLink(value: FolderLocation(storeID: store.id, parent: row)) {
                            Label(row.object.name, systemImage: "folder")
                        }
                    } else {
                        Button {
                            if !selection.insert(row.id).inserted { selection.remove(row.id) }
                        } label: {
                            HStack {
                                Image(systemName: selection.contains(row.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(Color.accentColor)
                                Text(row.object.name).foregroundStyle(.primary)
                                Spacer()
                                Text(Int64(row.object.size).formatted(.byteCount(style: .file)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityAddTraits(selection.contains(row.id) ? .isSelected : [])
                    }
                }
            }
        }
        .navigationTitle(parent?.object.name ?? (slot?.title ?? "卡根目录"))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("核对物理卡槽", isPresented: $confirming, titleVisibility: .visible) {
            ForEach(Slot.allCases) { choice in
                Button("\(choice.title) · \(choice.medium)") { model.confirm(choice, id: store.id) }
                    .disabled(model.catalog.slots.values.contains(choice) || model.catalog.failedStores.contains { $0.slot == choice })
            }
            if slot != nil { Button("解除关联") { model.confirm(nil, id: store.id) } }
        } message: {
            Text("用机身回放核对卡槽与照片，或只装一张已知卡后再关联。")
        }
    }
}
