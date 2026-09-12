import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let ink = Color(red: 0.095, green: 0.105, blue: 0.125)
private let canvas = Color(red: 0.12, green: 0.13, blue: 0.15)
private let accent = Color(red: 0.70, green: 0.79, blue: 0.98)
private let muted = Color.white.opacity(0.48)

struct StudioButton: ButtonStyle {
    var primary = false
    var destructive = false
    @Environment(\.isEnabled) var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.studio(12.5, weight: .medium))
            .padding(.horizontal, 14).frame(minHeight: 40)
            .foregroundStyle(primary ? ink : destructive ? Color(red: 0.98, green: 0.58, blue: 0.61) : Color.white.opacity(0.85))
            .background(primary ? accent : Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
            .opacity(enabled ? 1 : 0.35)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

struct StudioView: View {
    @ObservedObject var store: StudioStore
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(.white.opacity(0.055)).frame(width: 1)
            VStack(spacing: 0) {
                galleryToolbar
                gallery
                Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
                DockEditor(store: store)
            }.frame(maxWidth: .infinity)
            Rectangle().fill(.white.opacity(0.055)).frame(width: 1)
            Inspector(store: store).frame(width: 256)
        }
        .padding(.top, 28)
        .background(canvas.ignoresSafeArea())
        .foregroundStyle(Color.white.opacity(0.9))
        .preferredColorScheme(.dark)
        .frame(minWidth: 1100, minHeight: 700)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.bottomthird.inset.filled").font(.system(size: 19)).foregroundStyle(accent)
                Text("Dock Studio").font(.studio(15, weight: .medium))
            }.padding(.horizontal, 18).padding(.top, 19).padding(.bottom, 34)
            ForEach([("All widgets", "square.grid.2x2"), ("System", "cpu"), ("Time", "clock"), ("Personal", "text.alignleft")], id: \.0) { title, symbol in
                Button { store.category = title } label: {
                    HStack(spacing: 11) {
                        Image(systemName: symbol).font(.system(size: 14)).frame(width: 20)
                        Text(title).font(.studio(12.5))
                        Spacer(minLength: 0)
                        if title == "All widgets" { Text("16").font(.studio(11)).foregroundStyle(muted) }
                    }
                    .padding(.horizontal, 12).frame(height: 42)
                    .foregroundStyle(store.category == title ? .white.opacity(0.95) : .white.opacity(0.50))
                    .background(store.category == title ? Color.white.opacity(0.065) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.horizontal, 10).padding(.bottom, 4)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 7) {
                    Circle().fill(store.placements.isEmpty ? muted : WidgetAccent.mint.color).frame(width: 5, height: 5)
                    Text(store.placements.isEmpty ? "Nothing applied yet" : "\(store.placements.count) widgets in your Dock").font(.studio(11)).foregroundStyle(muted)
                }
                Text("Widgets keep running when you close this window.").font(.studio(11)).foregroundStyle(.white.opacity(0.34)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                Button { store.reloadLayout() } label: { Label("Reload layout", systemImage: "arrow.clockwise").font(.studio(11.5)).frame(height: 40, alignment: .leading) }.buttonStyle(.plain).foregroundStyle(muted)
                Button { store.permission() } label: { Label("Accessibility", systemImage: "hand.raised").font(.studio(11.5)).frame(height: 40, alignment: .leading) }.buttonStyle(.plain).foregroundStyle(muted)
            }.padding(18)
        }.frame(width: 174).background(ink)
    }
    private var galleryToolbar: some View {
        HStack(alignment: .center) {
            Text(store.category == "All widgets" ? "Widgets" : store.category).font(.studio(22, weight: .medium))
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(muted)
                TextField("Find a widget", text: $store.search).textFieldStyle(.plain).font(.studio(12.5))
            }.padding(.horizontal, 12).frame(width: 177, height: 38)
                .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        }.padding(.horizontal, 26).padding(.top, 15).padding(.bottom, 24)
    }
    private var gallery: some View {
        ScrollView {
            if store.filteredKinds.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").font(.system(size: 22)).foregroundStyle(muted)
                    Text("No matching widgets").font(.studio(15))
                    Button("Clear search") { store.search = "" }.buttonStyle(StudioButton())
                }.frame(maxWidth: .infinity).padding(.top, 90)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 26) {
                    ForEach(store.filteredKinds) { kind in GalleryItem(kind: kind, store: store) }
                }.padding(.horizontal, 26).padding(.top, 1).padding(.bottom, 28)
            }
        }
    }
}

private struct GalleryItem: View {
    let kind: WidgetKind
    @ObservedObject var store: StudioStore
    @State private var hovering = false
    private var widget: WidgetInstance { store.catalog[kind] ?? WidgetInstance(kind: kind) }
    private var selected: Bool { store.selectedID == "catalog:\(kind.rawValue)" }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetFace(widget: widget, telemetry: store.telemetry, timers: store.timers)
                .frame(height: 74)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? accent.opacity(0.7) : Color.white.opacity(hovering ? 0.15 : 0.06), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 14))
                .onTapGesture { store.selectCatalog(kind) }
                .onDrag { NSItemProvider(object: "catalog:\(kind.rawValue)" as NSString) } preview: {
                    WidgetFace(widget: widget, telemetry: store.telemetry, timers: store.timers).frame(width: 152, height: 60)
                }
                .onHover { hovering = $0 }
                .help("Drag \(kind.title) into the Dock preview")
            HStack(spacing: 3) {
                Text(kind.title).font(.studio(12.5, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                Button { store.add(kind) } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .medium)).frame(width: 40, height: 40).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(muted).help("Add \(kind.title) to Dock preview").accessibilityLabel("Add \(kind.title)")
            }.padding(.top, 3)
            Text(kind.detail).font(.studio(11.5)).foregroundStyle(muted).lineSpacing(2).lineLimit(2).frame(height: 31, alignment: .topLeading)
        }
    }
}

private struct Inspector: View {
    @ObservedObject var store: StudioStore
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Customize").font(.studio(13, weight: .medium)).foregroundStyle(muted).padding(.top, 22).padding(.bottom, 25)
            if let widget = store.selectedWidget {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(spacing: 9) {
                            Image(systemName: widget.kind.symbol).font(.system(size: 16)).foregroundStyle(widget.accent.color)
                            Text(widget.kind.title).font(.studio(16, weight: .medium))
                        }
                        WidgetFace(widget: widget, telemetry: store.telemetry, timers: store.timers).frame(height: 78)
                        VStack(alignment: .leading, spacing: 10) {
                            fieldLabel("Width")
                            HStack(spacing: 5) {
                                ForEach(2...4, id: \.self) { units in
                                    Button { store.updateSelected { $0.units = units } } label: {
                                        Text("\(units)U").font(.studio(12.5, weight: .medium)).frame(maxWidth: .infinity).frame(height: 40)
                                            .foregroundStyle(widget.units == units ? accent : muted)
                                            .background(widget.units == units ? accent.opacity(0.11) : .white.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                                    }.buttonStyle(.plain).accessibilityLabel("\(units) units wide")
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            fieldLabel("Color")
                            HStack(spacing: 4) {
                                ForEach(WidgetAccent.allCases) { color in
                                    Button { store.updateSelected { $0.accent = color } } label: {
                                        Circle().fill(color.color).frame(width: 22, height: 22)
                                            .overlay(Circle().stroke(ink, lineWidth: 3).padding(3))
                                            .overlay { if widget.accent == color { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(ink) } }
                                            .frame(width: 40, height: 40)
                                    }.buttonStyle(.plain).accessibilityLabel(color.title).help(color.title)
                                }
                            }
                        }
                        configuration(widget)
                        if store.selectionIsPlaced {
                            VStack(spacing: 8) {
                                HStack(spacing: 7) {
                                    Button { store.moveSelected(-1) } label: { Image(systemName: "arrow.left").frame(maxWidth: .infinity) }.buttonStyle(StudioButton()).help("Move widget left")
                                    Button { store.moveSelected(1) } label: { Image(systemName: "arrow.right").frame(maxWidth: .infinity) }.buttonStyle(StudioButton()).help("Move widget right")
                                }
                                Button { store.removeSelected() } label: { Label("Remove widget", systemImage: "minus.circle").frame(maxWidth: .infinity) }.buttonStyle(StudioButton(destructive: true))
                            }
                        } else {
                            Button { store.add(widget.kind) } label: { Label("Add to Dock preview", systemImage: "plus").frame(maxWidth: .infinity) }.buttonStyle(StudioButton(primary: true))
                        }
                    }.padding(.bottom, 24)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "cursorarrow").font(.system(size: 22)).foregroundStyle(muted)
                    Text("Select a widget").font(.studio(16, weight: .medium))
                    Text("Choose its width, color, and settings here.").font(.studio(12)).foregroundStyle(muted).lineSpacing(3)
                }.padding(.top, 12)
                Spacer()
            }
        }.padding(.horizontal, 20).background(ink.opacity(0.55))
    }
    private func fieldLabel(_ text: String) -> some View { Text(text).font(.studio(12)).foregroundStyle(muted) }
    @ViewBuilder private func configuration(_ widget: WidgetInstance) -> some View {
        if widget.kind == .worldClock {
            VStack(alignment: .leading, spacing: 10) {
                fieldLabel("Time zone")
                Picker("Time zone", selection: Binding(get: { widget.timeZone }, set: { zone in store.updateSelected { $0.timeZone = zone } })) {
                    ForEach(["Europe/London", "America/New_York", "America/Los_Angeles", "Europe/Paris", "Asia/Tokyo", "Asia/Singapore", "Australia/Sydney", "UTC"], id: \.self) { zone in
                        Text(zone.split(separator: "/").last.map(String.init)?.replacingOccurrences(of: "_", with: " ") ?? zone).tag(zone)
                    }
                }.labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        if widget.kind == .clock || widget.kind == .worldClock {
            Toggle("24-hour time", isOn: Binding(get: { widget.use24Hour }, set: { value in store.updateSelected { $0.use24Hour = value } })).toggleStyle(.switch).font(.studio(12))
        }
        if widget.kind == .focus || widget.kind == .countdown {
            VStack(alignment: .leading, spacing: 10) {
                fieldLabel("Duration")
                Stepper("\(widget.durationMinutes) minutes", value: Binding(get: { widget.durationMinutes }, set: { value in store.updateSelected { $0.durationMinutes = value } }), in: 1...180).font(.studio(12.5))
            }
        }
        if widget.kind.isTimer {
            HStack(spacing: 7) {
                Button { store.timers.toggle(widget) } label: { Text(store.timers.isRunning(widget) ? "Pause" : "Start").frame(maxWidth: .infinity) }.buttonStyle(StudioButton())
                Button { store.timers.reset(widget) } label: { Image(systemName: "arrow.counterclockwise") }.buttonStyle(StudioButton()).help("Reset timer")
            }
        }
        if widget.kind == .note {
            VStack(alignment: .leading, spacing: 10) {
                fieldLabel("Your note")
                TextField("What do you want in sight?", text: Binding(get: { widget.note }, set: { text in store.updateSelected { $0.note = String(text.prefix(100)) } }), axis: .vertical)
                    .font(.studio(12.5)).textFieldStyle(.plain).lineLimit(3...5).padding(11)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                Text("\(widget.note.count)/100").font(.studio(10)).foregroundStyle(muted)
            }
        }
    }
}

private struct DockEditor: View {
    @ObservedObject var store: StudioStore
    private let finder = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your Dock").font(.studio(14, weight: .medium))
                    Text(store.widgetCount == 0 ? "Drag widgets between your pinned apps" : "\(store.widgetCount) \(store.widgetCount == 1 ? "widget" : "widgets") · \(store.totalUnits)U\(store.hasChanges ? " · Unapplied changes" : "")")
                        .font(.studio(11)).foregroundStyle(muted)
                }
                Spacer(minLength: 6)
                if store.hasChanges { Button("Revert") { store.revert() }.buttonStyle(.plain).font(.studio(12)).foregroundStyle(muted).frame(height: 40) }
                Button { store.apply() } label: {
                    HStack(spacing: 8) {
                        if store.applying { ProgressView().controlSize(.small).scaleEffect(0.8) }
                        Text(store.applying ? "Applying…" : "Apply to Dock")
                        if !store.applying { Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)) }
                    }
                }.buttonStyle(StudioButton(primary: true)).disabled((!store.hasChanges && !store.isError) || store.applying)
            }
            ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 0) {
                    Image(nsImage: finder).resizable().frame(width: 40, height: 40).frame(width: 52, height: 70).help("Finder stays first")
                    ForEach(store.draft) { entry in DockPreviewItem(entry: entry, store: store).id(entry.id) }
                    DockEndDrop(store: store)
                    Rectangle().fill(.white.opacity(0.16)).frame(width: 1, height: 32).padding(.horizontal, 10)
                    Image(systemName: "trash").font(.system(size: 27, weight: .light)).foregroundStyle(.white.opacity(0.42)).frame(width: 45, height: 70)
                }.padding(.horizontal, 10)
            }
            .frame(height: 88)
            .background(ink.opacity(0.72), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.075), lineWidth: 1))
            .onChange(of: store.selectedID) { _, id in
                if let id, store.draft.contains(where: { $0.id == id }) { withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .center) } }
            }
            }
            HStack(spacing: 6) {
                if let message = store.message {
                    Image(systemName: store.isError ? "exclamationmark.circle" : "checkmark.circle").foregroundStyle(store.isError ? WidgetAccent.amber.color : WidgetAccent.mint.color)
                    Text(message).foregroundStyle(store.isError ? WidgetAccent.amber.color : muted)
                } else {
                    Image(systemName: "info.circle").foregroundStyle(.white.opacity(0.27))
                    Text("Apply reloads the Dock once. Your other apps stay open.").foregroundStyle(.white.opacity(0.35))
                }
            }.font(.studio(10.5)).lineLimit(2).frame(minHeight: 18, alignment: .topLeading)
        }.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 17).background(ink.opacity(0.4))
    }
}

private struct DockPreviewItem: View {
    let entry: DockEntry
    @ObservedObject var store: StudioStore
    @State private var targeted = false
    var body: some View {
        ZStack(alignment: .leading) {
            Group {
                if let widget = entry.widget {
                    WidgetFace(widget: widget, telemetry: store.telemetry, timers: store.timers)
                        .frame(width: CGFloat(widget.units) * 48 - 8, height: 40)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(store.selectedID == entry.id ? accent.opacity(0.9) : .clear, lineWidth: 1.5))
                } else if let item = store.pinned.first(where: { $0.id == entry.appKey }) {
                    Image(nsImage: item.icon).resizable().frame(width: 40, height: 40).help(item.title)
                }
            }
            .frame(width: entry.widget.map { CGFloat($0.units) * 48 } ?? 48, height: 70)
            .contentShape(Rectangle()).onTapGesture { store.selectedID = entry.id }
            .onDrag { NSItemProvider(object: "entry:\(entry.id)" as NSString) }
            if targeted { RoundedRectangle(cornerRadius: 1).fill(accent).frame(width: 2, height: 46).offset(x: -1) }
        }
        .onDrop(of: [UTType.text], delegate: StudioDrop(store: store, target: entry.id, targeted: $targeted))
    }
}

private struct DockEndDrop: View {
    @ObservedObject var store: StudioStore
    @State private var targeted = false
    var body: some View {
        Image(systemName: "plus").font(.system(size: 14)).foregroundStyle(targeted ? accent : .white.opacity(0.25))
            .frame(width: 48, height: 50)
            .background(targeted ? accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(targeted ? 0.3 : 0.1), style: StrokeStyle(lineWidth: 1, dash: [3, 4])))
            .padding(.horizontal, 5)
            .onDrop(of: [UTType.text], delegate: StudioDrop(store: store, target: nil, targeted: $targeted))
            .help("Drop a widget here")
    }
}

private struct StudioDrop: DropDelegate {
    let store: StudioStore
    let target: String?
    @Binding var targeted: Bool
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [UTType.text]) }
    func dropEntered(info: DropInfo) { targeted = true }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }
    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        guard let provider = info.itemProviders(for: [UTType.text]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { item, _ in
            guard let token = item as? String else { return }
            DispatchQueue.main.async { store.acceptDrop(token, before: target) }
        }
        return true
    }
}
