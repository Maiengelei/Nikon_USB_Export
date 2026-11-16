import AppKit
import ImageIO
import SwiftUI

@main
struct NikonUSBExportApp: App {
    @StateObject private var model = CameraModel()
    var body: some Scene {
        Window("Nikon USB Export", id: "export") {
            ExportWindow(model: model)
                .frame(minWidth: 820, minHeight: 560)
                .onAppear { model.start() }
        }
        .defaultSize(width: 980, height: 660)
    }
}

private struct SlotConfirmation: Identifiable {
    let id: UInt32
    let slot: Slot
}

private struct ExportWindow: View {
    @ObservedObject var model: CameraModel
    @State private var selected: UInt32?
    @State private var folders = [Entry]()
    @State private var photoIDs = Set<UInt32>()
    @AppStorage("showPhotoThumbnails") private var showThumbnails = false
    @State private var confirmation: SlotConfirmation?

    private var store: Storage? { model.catalog.stores.first { $0.id == selected } }
    private var parentID: UInt32 { folders.last?.id ?? 0 }
    private var rows: [Entry] { store?.children[parentID] ?? [] }
    private var singlePhoto: Entry? {
        guard photoIDs.count == 1, let id = photoIDs.first else { return nil }
        return rows.first { $0.object.isPhoto && $0.id == id }
    }
    private var ready: Bool { model.destination != nil && !model.exporting && !model.scanning }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                sidebar.frame(minWidth: 200, idealWidth: 228, maxWidth: 300)
                browser.frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            controls
        }
        .toolbar {
            ToolbarItem {
                Button {
                    let assignments = model.catalog.stores.map { store in
                        store.hexID + " → " + (model.catalog.slots[store.id]?.title ?? "卡槽待确认")
                    }
                    NSPasteboard.general.clearContents()
                    let notes = model.scanNotes + [model.thumbnailReadNote].compactMap { $0 }
                    NSPasteboard.general.setString((notes + assignments).joined(separator: "\n"), forType: .string)
                } label: { Label("复制读取记录", systemImage: "doc.on.doc") }
                .disabled(model.scanNotes.isEmpty)
                .help("复制本次 USB 读取的存储标识、目录样本及卡槽关联")
            }
            ToolbarItem {
                Button(action: model.refresh) { Label("刷新目录", systemImage: "arrow.clockwise") }
                    .disabled(!model.canRefresh)
            }
        }
        .onChange(of: model.catalog.stores.map(\.id)) { _, ids in
            selectStore(ids.first)
        }
        .alert(item: $confirmation) { choice in
            Alert(title: Text("确认物理卡槽"),
                  message: Text("请在机身回放中核对目录和照片，或确认机身仅装这一张卡。将当前存储关联到\(choice.slot.title)（\(choice.slot.medium)），仅对此次读取有效。"),
                  primaryButton: .default(Text("确认关联")) { model.confirm(choice.slot, id: choice.id) },
                  secondaryButton: .cancel(Text("取消")))
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("相机存储", systemImage: "camera").font(.headline).padding(.horizontal)
            List(model.catalog.stores, selection: Binding(get: { selected }, set: selectStore)) { storage in
                VStack(alignment: .leading, spacing: 4) {
                    Label(model.catalog.slots[storage.id]?.title ?? "待确认卡槽", systemImage: "sdcard")
                        .font(.headline)
                    Text(storage.hexID).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4).tag(storage.id)
            }
            .listStyle(.sidebar)
            ForEach(model.catalog.failedStores) { failure in
                VStack(alignment: .leading, spacing: 4) {
                    Label(failure.title, systemImage: "exclamationmark.triangle")
                        .font(.caption.bold()).foregroundStyle(.orange)
                    Text(failure.operation + " · " + failure.detail).font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled).padding(.horizontal)
            }
            if showThumbnails, !model.exporting, let photo = singlePhoto {
                PhotoThumbnail(model: model, entry: photo)
                    .id(photo)
                    .padding(.horizontal, 12)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(model.connected ? Color.green : .secondary).frame(width: 7, height: 7)
                Text(model.status).font(.caption).textSelection(.enabled)
            }.padding([.horizontal, .bottom])
        }.padding(.top, 16)
    }

    @ViewBuilder private var browser: some View {
        if let store {
            let slot = model.catalog.slots[store.id]
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(slot.map { "\($0.title) · \($0.medium)" } ?? "待确认卡槽").font(.title2.bold())
                        if let slot {
                            Text(store.reportedSlot == slot ? "相机卷标与存储标识一致" : "已人工核对")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text([store.description, store.label, store.hexID, bytes(Int64(clamping: store.capacity))]
                            .filter { !$0.isEmpty }.joined(separator: "  ·  "))
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    if store.reportedSlot == nil {
                        Menu(slot == nil ? "核对卡槽" : "更改关联") {
                            ForEach(Slot.allCases) { choice in
                                Button("\(choice.title) · \(choice.medium)") {
                                    confirmation = SlotConfirmation(id: store.id, slot: choice)
                                }
                                .disabled(model.catalog.slots.values.contains(choice) || model.catalog.failedStores.contains { $0.slot == choice })
                            }
                            if slot != nil { Button("解除关联") { model.confirm(nil, id: store.id) } }
                        }.fixedSize().disabled(model.exporting)
                    }
                }.padding([.horizontal, .top], 18)
                HStack {
                    Button {
                        photoIDs.removeAll()
                        _ = folders.popLast()
                    } label: { Image(systemName: "chevron.left") }
                        .disabled(folders.isEmpty).accessibilityLabel("上一级目录")
                    Text((["卡根目录"] + (folders.last?.path ?? [])).joined(separator: " / "))
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Toggle("显示缩略图", isOn: $showThumbnails)
                        .toggleStyle(.switch).controlSize(.small)
                }.padding(.horizontal, 18)
                Divider()
                if rows.isEmpty {
                    Spacer()
                    Text("此目录没有照片或子目录").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    List(rows, selection: Binding(get: { photoIDs }, set: { proposed in
                        photoIDs = Set(rows.lazy.filter { $0.object.isPhoto && proposed.contains($0.id) }.map(\.id))
                    })) { row in
                        if row.object.isFolder {
                            Button {
                                photoIDs.removeAll()
                                folders.append(row)
                            } label: {
                                HStack {
                                    Label(row.object.name, systemImage: "folder")
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        } else {
                            HStack {
                                Label(row.object.name, systemImage: "photo")
                                Spacer()
                                Text(bytes(Int64(row.object.size))).font(.caption).foregroundStyle(.secondary)
                            }.contentShape(Rectangle()).tag(row.id)
                        }
                    }.listStyle(.inset)
                        .help("点选照片，按住 ⌘ 可多选，按住 Shift 可连续选择")
                }
            }
        } else {
            VStack(spacing: 12) {
                if model.scanning { ProgressView().controlSize(.large) }
                else { Image(systemName: "camera").font(.system(size: 38)).foregroundStyle(.secondary) }
                Text(model.status).font(.title2.bold())
                if !model.connected && !model.scanning {
                    Text("将 USB 数据线接到机身的数据接口，并选择 MTP/PTP。")
                        .foregroundStyle(.secondary)
                }
            }.padding().multilineTextAlignment(.center).textSelection(.enabled)
        }
    }

    private func selectStore(_ id: UInt32?) {
        selected = id
        let initial = model.catalog.stores.first { $0.id == id }?.initialFolder
        folders = initial.map { [$0] } ?? []
        photoIDs.removeAll()
        confirmation = nil
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("导出到", systemImage: "externaldrive")
                Text(model.destination?.path ?? "尚未选择文件夹")
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("选择文件夹…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.prompt = "选择"
                    if panel.runModal() == .OK { model.destination = panel.url }
                }.disabled(model.exporting)
            }
            HStack {
                Button(photoIDs.isEmpty ? "导出所选照片" : "导出所选 \(photoIDs.count) 张") {
                    if let store { model.export(.photos(storage: store.id, parent: parentID, ids: photoIDs)) }
                }.disabled(!ready || photoIDs.isEmpty || store.flatMap { model.catalog.slots[$0.id] } == nil)
                Button("导出当前目录") {
                    if let store, let path = folders.last?.path { model.export(.folder(storage: store.id, path: path)) }
                }.disabled(!ready || folders.isEmpty || store.flatMap { model.catalog.slots[$0.id] } == nil)
                Spacer()
                ForEach(Slot.allCases) { slot in
                    Button("导出\(slot.title)全部") { model.export(.card(slot)) }
                        .disabled(!ready || !model.catalog.slots.values.contains(slot))
                }
                Button("双卡全部导出") { model.export(.both) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!ready || !model.catalog.canExportBoth)
            }
            if let report = model.report {
                if model.exporting && report.total > 0 {
                    HStack {
                        ProgressView(value: Double(report.processed), total: Double(report.total))
                        Text("\(report.processed) / \(report.total) 张").font(.caption.monospacedDigit())
                    }
                }
                Text(model.exporting ? report.current : report.summary)
                    .font(.caption).foregroundStyle(report.failure != nil ? Color.red : (report.conflicts.isEmpty ? .secondary : .orange))
                    .lineLimit(3).textSelection(.enabled)
                if !report.conflicts.isEmpty {
                    Button("复制同名冲突清单（\(report.conflicts.count)）") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report.conflicts.joined(separator: "\n"), forType: .string)
                    }
                }
            }
        }.padding(16)
    }

    private func bytes(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

private struct PhotoThumbnail: View {
    @ObservedObject var model: CameraModel
    let entry: Entry
    @State private var image: CGImage?
    @State private var unavailable = false

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable().scaledToFit()
                } else {
                    Text(unavailable ? "此照片的缩略图不可用" : "正在读取缩略图…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity).frame(height: 124)
            Text(entry.object.name).font(.caption).lineLimit(1).truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("照片缩略图，" + entry.object.name)
        .task {
            do {
                let data = try await model.thumbnail(for: entry)
                try Task.checkCancellation()
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                kCGImageSourceCreateThumbnailWithTransform: true,
                                                kCGImageSourceThumbnailMaxPixelSize: 512]
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                else { unavailable = true; return }
                image = preview
            } catch {
                if !Task.isCancelled { unavailable = true }
            }
        }
    }
}
