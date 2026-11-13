import Foundation
import Combine

@MainActor
final class PowerMonitor: ObservableObject {
    @Published private(set) var snapshot: PowerSnapshot?
    @Published private(set) var errorMessage: String?
    /// Last ~2 minutes of the headline watts, one sample per refresh.
    @Published private(set) var history: [Double] = []
    /// Charge power estimated from how fast the percentage moves. Fallback for
    /// devices where neither the IOKit registry nor the HID sensors give current.
    @Published private(set) var estimate: RateEstimate?
    /// Optimized Battery Charging / charge limit / clean energy settings from PowerUI.
    @Published private(set) var smartCharge: SmartChargeStatus?
    /// IOReturn from the last `IOPSCopyChargeStatus` call; nonzero means powerd refused.
    @Published private(set) var chargeStatusError: Int32 = 0
    /// Darwin notification state for smart-charge status changes; -1 when unavailable.
    @Published private(set) var smartChargeNotifyState: Int64 = -1
    /// Most recent observed charging hold, persisted across launches.
    @Published private(set) var lastHold: HoldObservation?

    struct HoldObservation: Codable {
        let percent: Int
        let start: Date
        var end: Date?
    }

    /// iOS's own thermal verdict. Apple describes `.serious` as high, with performance possibly
    /// affected, and `.critical` as significantly reducing performance.
    @Published private(set) var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    var isThermalStateHigh: Bool { thermalState == .serious || thermalState == .critical }

    /// Highest charger input power seen since the last reset, persisted across launches.
    @Published private(set) var peak: PeakRecord?
    /// Identity of the current charging session, persisted so a relaunch mid-session keeps the peak.
    /// A session starts at plug-in and survives reaching full and topping off; it ends at unplug.
    struct ChargingSession: Codable {
        var start: Date
        var adapterIdentity: String?
        var lastSeenPluggedIn: Bool
        var lastSeenPercent: Int?
    }
    private var session: ChargingSession?
    private var lastPluggedIn: Bool?
    private static let sessionKey = "chargingSession"

    struct PeakRecord: Codable {
        let watts: Double
        let date: Date
        let adapter: String?
        /// Which measurement this was, e.g. "from charger (USB-C)" or "into battery (MagSafe)".
        var label: String?
    }

    /// Last two headline samples, for the median-of-three glitch filter.
    private var recentSamples: [Double] = []
    private static let peakKey = "peakRecord"

    private var currentHold: HoldObservation?
    private var holdCandidateSince: Date?
    private var lastExternalConnected: Bool?
    private var externalChangedAt: Date = .distantPast
    /// A hold must persist this long before it counts; plug-in transitions look like a hold for a second or two.
    private static let holdDebounce: TimeInterval = 45
    private static let holdKey = "lastHoldObservation"

    /// Set when IQ0u and IQ0B fall in one of the onset patterns of the 18 Pro Max half reading
    /// (CLAUDE.md) while the adapter contract and VQ0u stay the same. A real
    /// load or thermal drop can look the same, so this is a suspicion only; nothing is doubled here.
    /// Kept until unplug; the half reading has not been seen to recover while plugged in.
    @Published private(set) var halfSuspicion: HalfSuspicion?

    struct HalfSuspicion {
        let date: Date
        let inputAmpsBefore: Double
        let inputAmpsAfter: Double
        let batteryAmpsBefore: Double
        let batteryAmpsAfter: Double
        let inputWattsBefore: Double
        /// Per-tick sensor and adapter fields around the drop, for the raw dump.
        var log: [String]
        var verdict: HalfVerdict = .waiting
        /// Battery energy as shown (uncorrected IQ0B × VQ0l) summed since the suspicion, in Wh.
        var shownWh: Double = 0
        var lastTick: Date?
        /// Percent changes since the suspicion with `shownWh` at that moment. Cleared when ticks are
        /// missing (app in background), since the shown energy would then be undercounted.
        var steps: [(date: Date, percent: Int, shownWh: Double)] = []
        var inputRatio: Double { inputAmpsAfter / inputAmpsBefore }
        var batteryRatio: Double { batteryAmpsAfter / batteryAmpsBefore }
    }

    /// Result of comparing the battery % rate with the shown battery watts after a suspicion.
    enum HalfVerdict {
        case waiting
        /// % rate within 1.6–2.6 × shown: the readings are doubled from then on.
        case confirmed(rateWatts: Double, shownWatts: Double)
        /// % rate within 1.3 × shown: the drop was real (load, heat, taper), not the half reading.
        case rejected(rateWatts: Double, shownWatts: Double)
        /// In between; waiting for more steps.
        case unclear(rateWatts: Double, shownWatts: Double)

        var isConfirmed: Bool { if case .confirmed = self { return true } else { return false } }
    }
    private static let halfConfirmRange = 1.6...2.6
    private static let halfRejectBelow = 1.3

    private struct HalfSample {
        let date: Date
        let inputVolts: Double
        let inputAmps: Double
        let batteryAmps: Double
        /// Negotiated profile and active PD index; must not change across a drop.
        let contract: String
        let line: String
    }
    private var halfSamples: [HalfSample] = []
    /// Ticks still to append to `halfSuspicion.log` after the drop.
    private var halfLogTicksLeft = 0
    /// Ticks before the drop compared with the last few after it. The onset seen on 2026-10-18 had
    /// one 8 W tick between the full and the half level, so the windows leave a gap for it.
    private static let halfBeforeTicks = 5
    private static let halfGapTicks = 2
    private static let halfAfterTicks = 3

    struct RateEstimate {
        let watts: Double
        let steps: Int
        let window: TimeInterval
    }

    /// Rated battery energy used to convert %/h into watts, by model identifier. Rated, not
    /// measured: a worn battery holds less, so the % rate reads high on an older phone.
    /// iPhone 17 Pro Max: 19.7 Wh (5,088 mAh × 3.87 V; capacity not checked against a source).
    /// iPhone 18 Pro Max: 21.75 Wh (5,567 mAh eSIM model, iFixit teardown).
    /// Other models use the 17 Pro Max value.
    let batteryWattHours: Double = {
        switch PowerSnapshot.modelIdentifier {
        case "iPhone19,3", "iPhone19,7": return 21.75
        default: return 19.7
        }
    }()

    private let reader = IOKitBattery()
    private let sensors = HIDSensors()
    private let smartChargeReader = SmartChargeReader()
    private var smartChargeInFlight = false
    private var task: Task<Void, Never>?
    private let interval: Duration = .seconds(1)
    private let historyLimit = 120
    private var refreshCount = 0
    private var percentLog: [(date: Date, percent: Int)] = []
    private var lastCharging: Bool?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.holdKey),
           let hold = try? JSONDecoder().decode(HoldObservation.self, from: data) {
            // Drop blips recorded before debouncing existed.
            if let end = hold.end, end.timeIntervalSince(hold.start) < Self.holdDebounce {
                UserDefaults.standard.removeObject(forKey: Self.holdKey)
            } else {
                lastHold = hold
            }
        }
        if let data = UserDefaults.standard.data(forKey: Self.peakKey),
           let record = try? JSONDecoder().decode(PeakRecord.self, from: data) {
            peak = record
        }
        if let data = UserDefaults.standard.data(forKey: Self.sessionKey),
           let saved = try? JSONDecoder().decode(ChargingSession.self, from: data) {
            session = saved
        }
    }

    func resetPeak() {
        peak = nil
        recentSamples.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.peakKey)
    }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: self?.interval ?? .seconds(1))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func refresh() {
        guard let reader else {
            errorMessage = "IOKit could not be loaded on this device."
            return
        }
        guard let props = reader.readProperties() else {
            errorMessage = "No IOPMPowerSource service found."
            return
        }
        errorMessage = nil
        refreshCount += 1

        let sources = reader.readPowerSources()
        let internalBattery = sources.first { ($0["Type"] as? String) == "InternalBattery" } ?? sources.first
        if refreshCount % 30 == 1 { sensors?.rescan() }
        var snap = PowerSnapshot(date: .now,
                                 raw: props,
                                 powerSource: internalBattery,
                                 adapterDetails: reader.readAdapterDetails(),
                                 sensors: sensors?.read() ?? [],
                                 chargeStatus: reader.readChargeStatus())
        chargeStatusError = reader.chargeStatusError
        if snap.externalConnected, halfSuspicion?.verdict.isConfirmed == true { snap.halfCorrection = 2 }
        snapshot = snap
        updateEstimate(snap)
        updateHold(snap)
        updateSession(snap)
        updatePeak(snap)
        updateHalfDetection(snap)
        updateHalfCheck(snap)
        let state = ProcessInfo.processInfo.thermalState
        if state != thermalState { thermalState = state }
        let notifyState = SmartChargeNotificationState()
        if notifyState != smartChargeNotifyState {
            #if DEBUG
            print("SMARTCHARGE notify state \(smartChargeNotifyState) -> \(notifyState)")
            #endif
            smartChargeNotifyState = notifyState
        }
        if refreshCount % 10 == 1 { refreshSmartCharge() }

        let sample = snap.primaryWatts?.value ?? estimate?.watts
        if let sample {
            history.append(sample)
            if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
        }

        #if DEBUG
        if refreshCount == 1 || refreshCount % 15 == 0 {
            let readings = snap.sensors.map { "\($0.name)=\($0.formatted)" }.joined(separator: ", ")
            print("CHARGESTATUS kr=0x\(String(UInt32(bitPattern: reader.chargeStatusError), radix: 16)) dict=\(String(describing: snap.chargeStatus))")
            print("TICK \(refreshCount) status=\(snap.statusText) primary=\(String(describing: snap.primaryWatts)) battery=\(String(describing: snap.batteryWatts)) sensors=[\(readings)]")
        }
        #endif
    }

    /// PowerUI calls go over XPC synchronously, so they run off the main actor.
    private func refreshSmartCharge() {
        guard let reader = smartChargeReader, !smartChargeInFlight else {
            if smartChargeReader == nil, smartCharge == nil {
                let status = SmartChargeStatus()
                status.available = false
                status.errorMessage = "PowerUI framework unavailable"
                smartCharge = status
            }
            return
        }
        smartChargeInFlight = true
        Task.detached(priority: .utility) { [weak self] in
            let status = reader.read()
            await MainActor.run {
                guard let self else { return }
                self.smartCharge = status
                self.smartChargeInFlight = false
                #if DEBUG
                if self.refreshCount <= 1 {
                    print("SMARTCHARGE available=\(status.available) obc=\(status.obcEnabled) mcl=\(status.mclEnabled) limit=\(status.mclLimit) deoc=\(status.deocEnabled) current=\(status.currentChargeLimit) recommended=\(status.recommendedChargeLimit) engaged=\(status.obcEngaged) engagedLimit=\(status.engagedChargeLimit) override=\(status.chargingOverrideAllowed) ui=\(status.uiState) supported=\(status.obcSupported)/\(status.mclSupported)/\(status.deocSupported) deadline=\(String(describing: status.fullChargeDeadline)) errors=\(status.callErrors)")
                    print("SMARTCHARGE status=\(String(describing: status.rawStatus))")
                }
                #endif
            }
        }
    }

    func rawDump() -> String {
        guard let snap = snapshot else { return "" }
        var text = "IOPMPowerSource:\n" + dump(snap.raw)
        if let cs = snap.chargeStatus { text += "\n\nChargeStatus:\n" + dump(cs) }
        if let sc = smartCharge {
            text += "\n\nSmartCharge: obc=\(sc.obcEnabled) mcl=\(sc.mclEnabled) limit=\(sc.mclLimit) deoc=\(sc.deocEnabled) engaged=\(sc.obcEngaged) engagedLimit=\(sc.engagedChargeLimit) ui=\(sc.uiState) errors=\(sc.callErrors)"
            if let raw = sc.rawStatus as? [String: Any] { text += "\n" + dump(raw) }
        }
        if let s = halfSuspicion {
            text += "\n\nHalf-reading suspicion at \(s.date): "
                + String(format: "IQ0u %.3f → %.3f A (×%.2f), IQ0B %.3f → %.3f A (×%.2f), input before %.1f W",
                         s.inputAmpsBefore, s.inputAmpsAfter, s.inputRatio,
                         s.batteryAmpsBefore, s.batteryAmpsAfter, s.batteryRatio, s.inputWattsBefore)
                + "\nVerdict: \(s.verdict)"
            text += "\n" + s.log.joined(separator: "\n")
        }
        if let ps = snap.powerSource { text += "\n\nIOPS:\n" + dump(ps) }
        if let ad = snap.adapterDetails { text += "\n\nAdapter:\n" + dump(ad) }
        if !snap.sensors.isEmpty {
            text += "\n\nSensors:\n" + snap.sensors.map { "\($0.name) = \($0.formatted)" }.joined(separator: "\n")
        }
        return text
    }

    private func dump(_ dict: [String: Any]) -> String {
        dict.keys.sorted().map { "\($0) = \(String(describing: dict[$0]!))" }.joined(separator: "\n")
    }

    /// Records when the phone sits on a charging hold and at what level, so the limit
    /// (80/85/90/95 % or Optimized Battery Charging's 80 %) can be read off later.
    private func updateHold(_ snap: PowerSnapshot) {
        if lastExternalConnected != snap.externalConnected {
            lastExternalConnected = snap.externalConnected
            externalChangedAt = snap.date
        }
        let settled = snap.date.timeIntervalSince(externalChangedAt) >= Self.holdDebounce
        if snap.isChargingOnHold, settled, let p = snap.percent {
            if holdCandidateSince == nil { holdCandidateSince = snap.date }
            if currentHold == nil, let since = holdCandidateSince,
               snap.date.timeIntervalSince(since) >= Self.holdDebounce {
                currentHold = HoldObservation(percent: p, start: since, end: nil)
                lastHold = currentHold
                persistHold()
            }
        } else {
            holdCandidateSince = nil
            if currentHold != nil {
                currentHold?.end = snap.date
                lastHold = currentHold
                persistHold()
                currentHold = nil
            }
        }
    }

    /// Adapter serial where available, otherwise a composite of the adapter's static fields.
    private func adapterIdentity(_ snap: PowerSnapshot) -> String? {
        guard let a = snap.adapter else { return nil }
        if let serial = a["SerialString"] as? String, !serial.isEmpty { return serial }
        return ["Name", "Description", "Model", "AdapterID"].compactMap { a[$0].map { String(describing: $0) } }.joined(separator: "|")
    }

    /// Detects plug-in events and resets the peak at the start of each charging session.
    /// While running, any unplugged → plugged transition is a new session. On the first tick after
    /// launch, the persisted session is continued only if the phone was still plugged in when last
    /// seen, the adapter is the same, and the level has not dropped (i.e. no unplug happened while
    /// the app was closed).
    private func updateSession(_ snap: PowerSnapshot) {
        let pluggedIn = snap.externalConnected
        defer { lastPluggedIn = pluggedIn }

        if pluggedIn {
            var isNew = false
            if lastPluggedIn == false {
                isNew = true
            } else if lastPluggedIn == nil {
                if let saved = session, saved.lastSeenPluggedIn,
                   saved.adapterIdentity == adapterIdentity(snap),
                   (snap.percent ?? 0) >= (saved.lastSeenPercent ?? 0) - 1 {
                    isNew = false
                } else {
                    isNew = true
                }
            }
            if isNew {
                peak = nil
                recentSamples.removeAll()
                history.removeAll()
                UserDefaults.standard.removeObject(forKey: Self.peakKey)
                session = ChargingSession(start: snap.date, adapterIdentity: adapterIdentity(snap),
                                          lastSeenPluggedIn: true, lastSeenPercent: snap.percent)
                persistSession()
            } else if var current = session {
                if current.adapterIdentity == nil { current.adapterIdentity = adapterIdentity(snap) }
                if !current.lastSeenPluggedIn || current.lastSeenPercent != snap.percent {
                    current.lastSeenPluggedIn = true
                    current.lastSeenPercent = snap.percent
                    session = current
                    persistSession()
                } else {
                    session = current
                }
            } else {
                session = ChargingSession(start: snap.date, adapterIdentity: adapterIdentity(snap),
                                          lastSeenPluggedIn: true, lastSeenPercent: snap.percent)
                persistSession()
            }
        } else if var current = session, current.lastSeenPluggedIn {
            current.lastSeenPluggedIn = false
            current.lastSeenPercent = snap.percent
            session = current
            persistSession()
        }
    }

    private func persistSession() {
        if let session, let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: Self.sessionKey)
        }
    }

    /// Records the peak of the headline number (charger input on USB-C, battery input on
    /// MagSafe where no input current sensor exists) for the current charging session. Uses the
    /// median of the last three samples so a single glitchy reading cannot set it.
    private func updatePeak(_ snap: PowerSnapshot) {
        guard snap.externalConnected, let primary = snap.primaryWatts, primary.value > 0 else {
            recentSamples.removeAll()
            return
        }
        recentSamples.append(primary.value)
        if recentSamples.count > 3 { recentSamples.removeFirst(recentSamples.count - 3) }
        guard recentSamples.count == 3 else { return }
        let candidate = recentSamples.sorted()[1]
        if candidate > (peak?.watts ?? 0) {
            peak = PeakRecord(watts: candidate, date: snap.date,
                              adapter: snap.adapterName ?? snap.adapterDescription,
                              label: primary.label)
            if let data = try? JSONEncoder().encode(peak) {
                UserDefaults.standard.set(data, forKey: Self.peakKey)
            }
        }
    }

    private func persistHold() {
        if let hold = lastHold, let data = try? JSONEncoder().encode(hold) {
            UserDefaults.standard.set(data, forKey: Self.holdKey)
        }
    }

    /// Looks for the half-reading onset (pattern A or B below) over the last ten ticks, with the
    /// same adapter contract and VQ0u throughout. Both compare against an earlier reading, not
    /// against contract/2, so the ~7 s pause at 1.5 A during the ramp (a rise, not a fall) does not
    /// trigger it; that pause is what sank the earlier detector.
    private func updateHalfDetection(_ snap: PowerSnapshot) {
        guard snap.mayReadHalf, let vIn = snap.usbInputVoltage, let iIn = snap.usbInputCurrent,
              let iBat = snap.sensorBatteryCurrent else {
            if !snap.externalConnected { halfSuspicion = nil; halfLogTicksLeft = 0 }
            halfSamples.removeAll()
            return
        }
        // The adapter side only. PMUConfiguration is the phone's own setting and may be what changes
        // at the split, so it is logged but not required to stay the same.
        let contract = [
            snap.adapterNegotiated.map { "\($0.voltage_mV)mV×\($0.current_mA)mA" } ?? "-",
            snap.adapterActiveProfile.map { "idx\($0)" } ?? "idx-",
        ].joined(separator: " ")
        let pmu = snap.adapter?["PMUConfiguration"].map { String(describing: $0) } ?? "-"
        let line = String(format: "%@ VQ0u %.3f V IQ0u %.3f A IQ0B %.3f A VQ0l %@ | %@ pmu %@",
                          ISO8601DateFormatter.string(from: snap.date, timeZone: .current,
                                                      formatOptions: [.withTime, .withColonSeparatorInTime]),
                          vIn, iIn, iBat,
                          snap.sensorBatteryVoltage.map { String(format: "%.3f V", $0) } ?? "-",
                          contract, pmu)
        halfSamples.append(HalfSample(date: snap.date, inputVolts: vIn, inputAmps: iIn,
                                      batteryAmps: iBat, contract: contract, line: line))
        let needed = Self.halfBeforeTicks + Self.halfGapTicks + Self.halfAfterTicks
        if halfSamples.count > needed { halfSamples.removeFirst(halfSamples.count - needed) }

        if halfSuspicion != nil {
            if halfLogTicksLeft > 0 {
                halfSuspicion?.log.append(line)
                halfLogTicksLeft -= 1
            }
            return
        }
        guard halfSamples.count == needed,
              Set(halfSamples.map(\.contract)).count == 1 else { return }
        guard let found = stepToHalf() ?? dropoutThenLower() else { return }
        let (before, after) = found
        let inBefore = median(before.map(\.inputAmps)), inAfter = median(after.map(\.inputAmps))
        let batBefore = median(before.map(\.batteryAmps)), batAfter = median(after.map(\.batteryAmps))
        let vBefore = median(before.map(\.inputVolts))
        halfSuspicion = HalfSuspicion(date: snap.date,
                                      inputAmpsBefore: inBefore, inputAmpsAfter: inAfter,
                                      batteryAmpsBefore: batBefore, batteryAmpsAfter: batAfter,
                                      inputWattsBefore: vBefore * inBefore,
                                      log: halfSamples.map(\.line))
        halfLogTicksLeft = 10
        #if DEBUG
        print("HALF suspicion IQ0u \(inBefore) → \(inAfter) A, IQ0B \(batBefore) → \(batAfter) A\n"
              + halfSamples.map(\.line).joined(separator: "\n"))
        #endif
    }

    /// Pattern A (MiniWatts reports, power steady across the split): IQ0u and IQ0B medians step to
    /// 40–60 % of the level five ticks earlier, from at least 20 W, VQ0u unchanged.
    private func stepToHalf() -> (before: [HalfSample], after: [HalfSample])? {
        let before = Array(halfSamples.prefix(Self.halfBeforeTicks))
        let after = Array(halfSamples.suffix(Self.halfAfterTicks))
        guard levelsComparable(before, after, minWatts: 20) else { return nil }
        let inRatio = median(after.map(\.inputAmps)) / median(before.map(\.inputAmps))
        let batRatio = median(after.map(\.batteryAmps)) / median(before.map(\.batteryAmps))
        guard (0.40...0.60).contains(inRatio), (0.35...0.65).contains(batRatio) else { return nil }
        return (before, after)
    }

    /// Pattern B (measured here 2026-10-18, power still rising across the split): one or two ticks
    /// of input below half the level just before them (the 8 W tick), then three ticks back above
    /// 30 % of that level but below 85 % of it. The reading falls only to ~0.75 there because the
    /// real power rose at the same time, so pattern A alone misses it. A plain hiccup that recovers
    /// to the previous level is above 85 % and does not count.
    private func dropoutThenLower() -> (before: [HalfSample], after: [HalfSample])? {
        let after = Array(halfSamples.suffix(Self.halfAfterTicks))
        let rest = Array(halfSamples.dropLast(Self.halfAfterTicks))
        // Dropout ticks sit just before `after`; the reference is the two ticks before the dropout.
        for dropoutLength in 1...2 {
            let dropout = rest.suffix(dropoutLength)
            let reference = Array(rest.dropLast(dropoutLength).suffix(2))
            guard reference.count == 2, levelsComparable(reference, after, minWatts: 20) else { continue }
            let refWatts = reference.map { $0.inputVolts * $0.inputAmps }.reduce(0, +) / 2
            guard dropout.allSatisfy({ $0.inputVolts * $0.inputAmps < 0.5 * refWatts }) else { continue }
            let afterWatts = after.map { $0.inputVolts * $0.inputAmps }
            guard afterWatts.allSatisfy({ $0 > 0.3 * refWatts }),
                  (0.35...0.85).contains(median(afterWatts) / refWatts) else { continue }
            let batRatio = median(after.map(\.batteryAmps)) / median(reference.map(\.batteryAmps))
            guard batRatio < 0.9 else { continue }
            return (reference, after)
        }
        return nil
    }

    /// Same VQ0u (±5 %) on both sides, charging into the battery, and a starting level near where
    /// the split has been seen (30 W; ~23 W during the ramp).
    private func levelsComparable(_ before: [HalfSample], _ after: [HalfSample], minWatts: Double) -> Bool {
        let vBefore = median(before.map(\.inputVolts)), vAfter = median(after.map(\.inputVolts))
        let iBefore = median(before.map(\.inputAmps))
        return vBefore > 0 && abs(vAfter - vBefore) / vBefore < 0.05
            && vBefore * iBefore >= minWatts
            && median(before.map(\.batteryAmps)) > 0.2
    }

    /// After a suspicion, compares the battery % rate with the shown battery watts over the same
    /// whole % steps. The % rate is the only reading independent of IQ0B. On the 18 Pro Max the
    /// percent moves in 5 % steps (~1.1 Wh of 21.75 Wh), so a verdict needs two steps after the
    /// suspicion: about 3 minutes at 40 W into the battery. Rated capacity is used, so a worn
    /// battery makes the % rate read high; the 1.6–2.6 band allows for that.
    /// Once confirmed the verdict is kept until unplug; a rejected or unclear one keeps being
    /// re-evaluated as more steps arrive.
    private func updateHalfCheck(_ snap: PowerSnapshot) {
        guard var s = halfSuspicion, !s.verdict.isConfirmed else { return }
        defer { halfSuspicion = s }
        guard snap.isCharging, let percent = snap.percent,
              let shown = snap.sensorBatteryWatts.map({ $0 / snap.halfCorrection }) else {
            s.steps.removeAll(); s.lastTick = nil
            return
        }
        if let last = s.lastTick {
            let dt = snap.date.timeIntervalSince(last)
            if dt > 5 {
                s.steps.removeAll()   // missed ticks: the shown energy since the last step is incomplete
            } else {
                s.shownWh += shown * dt / 3600
            }
        }
        s.lastTick = snap.date
        if s.steps.last?.percent != percent {
            // The first entry after a suspicion or a gap is mid-step; only changes count as step edges.
            s.steps.append((snap.date, percent, s.shownWh))
            if s.steps.count > 4 { s.steps.removeFirst(s.steps.count - 4) }
        }
        let edges = s.steps.dropFirst()
        guard edges.count >= 2, let first = edges.first, let last = edges.last else { return }
        let hours = last.date.timeIntervalSince(first.date) / 3600
        let deltaPercent = Double(last.percent - first.percent)
        // At least a minute, in case a device reports 1 % steps (seconds apart at 40 W).
        guard hours * 3600 >= 60, deltaPercent >= 1 else { return }
        let rateWatts = deltaPercent / 100 * batteryWattHours / hours
        let shownWatts = (last.shownWh - first.shownWh) / hours
        guard shownWatts > 0.5 else { return }
        let ratio = rateWatts / shownWatts
        if Self.halfConfirmRange.contains(ratio) {
            s.verdict = .confirmed(rateWatts: rateWatts, shownWatts: shownWatts)
        } else if ratio < Self.halfRejectBelow {
            s.verdict = .rejected(rateWatts: rateWatts, shownWatts: shownWatts)
        } else {
            s.verdict = .unclear(rateWatts: rateWatts, shownWatts: shownWatts)
        }
        #if DEBUG
        print("HALF check rate \(rateWatts) W shown \(shownWatts) W ratio \(ratio) → \(s.verdict)")
        #endif
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// Tracks percent transitions and converts the slope into watts. powerd's percent has only
    /// been seen in 5 % steps on the 18 Pro Max / iOS 27, so one step there is 5 %.
    /// The first logged sample is mid-percent, so at least two transitions are needed.
    private func updateEstimate(_ snap: PowerSnapshot) {
        guard let percent = snap.percent else { estimate = nil; return }
        if lastCharging != snap.isCharging {
            lastCharging = snap.isCharging
            percentLog.removeAll()
            estimate = nil
        }
        if percentLog.last?.percent != percent {
            percentLog.append((snap.date, percent))
            if percentLog.count > 7 { percentLog.removeFirst(percentLog.count - 7) }
        }
        let transitions = percentLog.dropFirst()
        guard transitions.count >= 2, let first = transitions.first, let last = transitions.last else { return }
        let hours = last.date.timeIntervalSince(first.date) / 3600
        guard hours > 0 else { return }
        let deltaPercent = Double(last.percent - first.percent)
        estimate = RateEstimate(watts: deltaPercent / 100 * batteryWattHours / hours,
                                steps: transitions.count - 1,
                                window: last.date.timeIntervalSince(first.date))
    }
}
