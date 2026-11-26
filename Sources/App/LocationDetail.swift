import SwiftUI

/// Network locations: pick one to switch, add or delete, and see the DNS in use.
struct LocationDetail: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var presentation: PanelPresentation
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupedPanel {
                Text("Locations")
                    .font(.system(size: 12, weight: .semibold))
                    .stagger(index: 0, generation: presentation.generation)

                if model.networkLocations.locations.isEmpty {
                    Text(model.networkLocationsLoaded ? "No locations" : "Reading locations…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 4) {
                        ForEach(Array(model.networkLocations.locations.enumerated()), id: \.element.id) { index, location in
                            LocationChoiceRow(location: location)
                                .stagger(index: 1 + index, generation: presentation.generation)
                        }
                    }
                }

                Divider()

                HStack(spacing: 6) {
                    TextField("New location", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(ModuleColor.offFill)
                        )
                        .onSubmit(add)
                        .disabled(model.locationBusy)
                    if model.locationEditBusy {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityLabel("Waiting for administrator access")
                    }
                    Button("Add", action: add)
                        .controlSize(.small)
                        .disabled(model.locationBusy || draft.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help("Copies every network service. Asks for an administrator password.")
                        .accessibilityLabel("Add location")
                }

                if let error = model.locationError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            AutoSwitchPanel()

            DNSInUsePanel(dns: model.networkLocations.dns)
        }
    }

    private func add() {
        let name = draft
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.addLocation(name) { added in
            if added, draft == name { draft = "" }
        }
    }
}

private struct LocationChoiceRow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let location: NetworkLocation
    @State private var hovering = false

    private var isCurrent: Bool { model.networkLocations.currentID == location.id }
    private var isSwitching: Bool { model.locationSwitchingID == location.id }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.switchLocation(location)
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(location.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(isSwitching ? "Switching…" : location.dnsSummary)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    if isSwitching {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityLabel("Switching to \(location.name)")
                    } else if isCurrent {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleButtonStyle(isStatic: isCurrent))
            .disabled(model.locationBusy && !isSwitching)
            .accessibilityLabel(location.name)
            .accessibilityValue(isCurrent ? "Current, \(location.dnsSummary)" : location.dnsSummary)
            .accessibilityHint(isCurrent ? "" : "Switches to this location")
            .accessibilityAddTraits(isCurrent ? .isSelected : [])

            if !isCurrent {
                Button {
                    model.deleteLocation(location)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(model.locationBusy)
                .opacity(hovering ? 1 : 0.5)
                .help("Delete \(location.name)")
                .accessibilityLabel("Delete \(location.name)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .fill(fill)
        )
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Motion.hover, value: hovering)
        .animation(reduceMotion ? nil : Motion.enter, value: isCurrent)
    }

    private var fill: Color {
        if isCurrent {
            return Color.accentColor.opacity(ModuleColor.onFill)
        }
        return hovering ? ModuleColor.offFillHover : ModuleColor.offFill
    }
}

/// Rules that pick a location by Wi-Fi name, plus a fallback for every other Wi-Fi.
private struct AutoSwitchPanel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var presentation: PanelPresentation
    @State private var wifiDraft = ""
    @State private var locationDraft = ""
    @State private var notice: String?

    private var locations: [NetworkLocation] { model.networkLocations.locations }

    var body: some View {
        GroupedPanel {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Switch by Wi-Fi")
                        .font(.system(size: 13, weight: .semibold))
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Toggle(
                    "Switch by Wi-Fi",
                    isOn: Binding(
                        get: { model.locationAutoSwitch },
                        set: { model.setLocationAutoSwitch($0) }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }
            .stagger(index: 0, generation: presentation.generation)

            if model.wifiNameAccess != .granted {
                HStack(alignment: .center, spacing: 8) {
                    Text("macOS shows the Wi-Fi name only to apps with Location Services.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button(model.wifiNameAccess == .denied ? "Open Settings" : "Allow") {
                        model.requestWiFiNameAccess()
                    }
                    .controlSize(.small)
                }
            }

            Divider()

            if !model.locationRules.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.locationRules) { rule in
                        ruleRow(rule)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    TextField("Wi-Fi name", text: $wifiDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(ModuleColor.offFill)
                        )
                        .onSubmit(addRule)
                    if let wifi = model.currentWiFi, wifiDraft != wifi {
                        Button("Current") {
                            wifiDraft = wifi
                        }
                        .controlSize(.small)
                        .help("Use \(wifi)")
                    }
                }
                HStack(spacing: 6) {
                    Text("uses")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Picker("Location", selection: $locationDraft) {
                        ForEach(locations) { location in
                            Text(location.name).tag(location.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    Spacer(minLength: 0)
                    Button("Add Rule", action: addRule)
                        .controlSize(.small)
                        .disabled(wifiDraft.trimmingCharacters(in: .whitespaces).isEmpty || locationDraft.isEmpty)
                }
            }

            Divider()

            HStack {
                Text("Any other Wi-Fi")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Picker(
                    "Any other Wi-Fi",
                    selection: Binding(
                        get: { model.locationOtherwiseID ?? "" },
                        set: { model.setLocationOtherwise($0.isEmpty ? nil : $0) }
                    )
                ) {
                    Text("Keep current").tag("")
                    ForEach(locations) { location in
                        Text(location.name).tag(location.id)
                    }
                    if let id = model.locationOtherwiseID, !locations.contains(where: { $0.id == id }) {
                        Text("Deleted location").tag(id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
            }

            if let notice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let auto = model.locationAutoNotice {
                Text(auto)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: seedLocationDraft)
        .onChange(of: locations) { _, _ in seedLocationDraft() }
    }

    private var status: String {
        if !model.locationAutoSwitch { return "Off" }
        if model.wifiNameAccess != .granted { return "Needs Location Services" }
        if let wifi = model.currentWiFi { return "On \(wifi)" }
        return "Not on Wi-Fi"
    }

    private func ruleRow(_ rule: LocationRule) -> some View {
        let isActive = model.currentWiFi.map { $0.caseInsensitiveCompare(rule.wifi) == .orderedSame } ?? false
        return HStack(spacing: 6) {
            Text(rule.wifi)
                .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(model.locationName(id: rule.locationID, fallback: rule.locationName))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Button {
                model.removeLocationRule(rule)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove rule for \(rule.wifi)")
        }
        .accessibilityElement(children: .contain)
    }

    private func seedLocationDraft() {
        guard !locations.contains(where: { $0.id == locationDraft }) else { return }
        // Most rules point at a location with its own DNS, so offer that first.
        locationDraft = locations.first { !$0.customDNS.isEmpty }?.id ?? locations.first?.id ?? ""
    }

    private func addRule() {
        notice = model.addLocationRule(wifi: wifiDraft, locationID: locationDraft)
        if notice == nil { wifiDraft = "" }
    }
}

private struct DNSInUsePanel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var presentation: PanelPresentation
    let dns: DNSInUse?

    var body: some View {
        GroupedPanel {
            Text("DNS in use")
                .font(.system(size: 12, weight: .semibold))
                .stagger(index: 0, generation: presentation.generation)

            if let dns {
                if let via = via(dns) {
                    StatRow(label: "Service", value: via)
                        .stagger(index: 1, generation: presentation.generation)
                }
                StatRow(label: "Source", value: dns.setByLocation ? "This location" : "Network")
                    .stagger(index: 2, generation: presentation.generation)
                ValueListRow(label: "Servers", values: dns.servers.isEmpty ? ["None"] : dns.servers)
                    .stagger(index: 3, generation: presentation.generation)
                if !dns.searchDomains.isEmpty {
                    ValueListRow(label: "Search", values: dns.searchDomains)
                        .stagger(index: 4, generation: presentation.generation)
                }
                if dns.resolverDiffers {
                    Divider()
                    ValueListRow(label: "Default resolver", values: dns.resolverServers)
                        .stagger(index: 5, generation: presentation.generation)
                    Text("Queries go here first. A VPN such as Tailscale can set it.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .stagger(index: 6, generation: presentation.generation)
                }
            } else {
                Text("No connection")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer(minLength: 0)
                Button("Network Settings…") {
                    model.openNetworkSettings()
                }
                .controlSize(.small)
                .help("Change a location's DNS in System Settings")
            }
        }
    }

    private func via(_ dns: DNSInUse) -> String? {
        let parts = [dns.serviceName, dns.interface].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A label with one value per line, for DNS servers and search domains.
private struct ValueListRow: View {
    let label: String
    let values: [String]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    Text(value)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}
