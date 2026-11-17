import AppKit
import IOKit.hid
import SwiftUI

struct KeySignal: Hashable {
    let page: UInt32
    let usage: UInt32
}

@MainActor
final class KeyInput {
    private var manager: IOHIDManager?
    private var receive: ((KeySignal, Bool) -> Void)?

    static var hasAccess: Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }

    func start(receive: @escaping (KeySignal, Bool) -> Void) -> Bool {
        stop()
        guard Self.hasAccess || IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) else { return false }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        let products = [0x4015, 0x4012, 0x4013, 0x4011]
        let devices = products.map { [kIOHIDVendorIDKey: 0x3151, kIOHIDProductIDKey: $0] }
        IOHIDManagerSetDeviceMatchingMultiple(manager, devices as CFArray)
        IOHIDManagerRegisterInputValueCallback(manager, { context, result, _, value in
            guard let context, result == kIOReturnSuccess else { return }
            let element = IOHIDValueGetElement(value)
            let page = IOHIDElementGetUsagePage(element)
            let usage = IOHIDElementGetUsage(element)
            guard (page == 7 && (4...231).contains(usage)) || (page == 12 && usage > 0) else { return }
            let down = IOHIDValueGetIntegerValue(value) != 0
            // IOKit delivers these values on the main run loop below.
            MainActor.assumeIsolated {
                let reader = Unmanaged<KeyInput>.fromOpaque(context).takeUnretainedValue()
                reader.receive?(KeySignal(page: page, usage: usage), down)
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        guard let loop = CFRunLoopGetMain() else { return false }
        IOHIDManagerScheduleWithRunLoop(manager, loop, CFRunLoopMode.commonModes.rawValue)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(manager, loop, CFRunLoopMode.commonModes.rawValue)
            return false
        }
        self.manager = manager
        self.receive = receive
        return true
    }

    func stop() {
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        receive = nil
    }
}

struct MacroCapture {
    static let durationLimit = Int(UInt16.max)
    private(set) var strokes: [Macro.Stroke] = []
    private(set) var held: Set<UInt8> = []
    private var last: Double?

    mutating func add(_ key: UInt8, down: Bool, time: Double, timing: Bool) {
        guard held.contains(key) != down else { return }
        if timing, let last, !strokes.isEmpty {
            let delay = ((time - last) * 1000).rounded()
            strokes[strokes.count - 1].delay = UInt16(min(Double(Self.durationLimit), max(1, delay)))
        }
        last = time
        if down { held.insert(key) } else { held.remove(key) }
        strokes.append(.init(key: key, down: down, delay: 40))
    }

    var balanced: [Macro.Stroke] {
        strokes + held.sorted().map { .init(key: $0, down: false, delay: 40) }
    }
}

struct MacroRecorder: View {
    @Environment(\.appLanguage) private var l
    let accept: ([Macro.Stroke]) -> Void
    let cancel: () -> Void
    @State private var capture = MacroCapture()
    @State private var reader = KeyInput()
    @State private var recording = false
    @State private var timing = true
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l("Makro kaydet")).font(.title2.bold())
            Text(l("TOP75’te istediğin tuşlara bas. Kayıt sırasında tuşları bu pencere alır."))
                .foregroundStyle(.secondary)
            Toggle(l("Gerçek gecikmeleri kullan"), isOn: $timing).disabled(recording)
            KeyboardLayout(selected: Set(capture.held))
            LabeledContent(l("Kayıt kapasitesi"), value: l.format("%@ / %@ bayt", String(Macro.requiredBytes(capture.balanced)), String(Macro.writableBytes)))
            if !status.isEmpty { Text(l(status)).foregroundStyle(.secondary) }
            HStack {
                Button(l("Vazgeç"), role: .cancel) { stop(); cancel() }
                Spacer()
                if recording {
                    Button(l("Durdur"), systemImage: "stop.fill", action: stop)
                } else {
                    Button(l("Kaydı başlat"), systemImage: "record.circle", action: start)
                    Button(l("Taslağı değiştir")) { accept(capture.balanced) }
                        .buttonStyle(.borderedProminent)
                        .disabled(capture.strokes.isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 630)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stop() }
        .onDisappear(perform: stop)
        .background {
            CaptureEventGuard(active: recording)
        }
    }

    private func start() {
        status = ""
        let started = reader.start { signal, down in
            guard recording, NSApp.isActive else { return }
            guard signal.page == 7, let key = UInt8(exactly: signal.usage) else {
                if down { status = "Makro kaydı standart klavye tuşlarını destekler." }
                return
            }
            var next = capture
            next.add(key, down: down, time: ProcessInfo.processInfo.systemUptime, timing: timing)
            guard Macro.requiredBytes(next.balanced) <= Macro.writableBytes else {
                status = "Makro yuvası doldu. Kaydedilen tuşları düzenleyebilirsin."
                stop()
                return
            }
            capture = next
        }
        if started { capture = MacroCapture(); recording = true }
        else { status = "Tuşları okumak için TOP75’e Giriş İzleme izni ver ve uygulamayı yeniden aç." }
    }

    private func stop() {
        reader.stop()
        recording = false
    }
}

private struct CaptureEventGuard: NSViewRepresentable {
    let active: Bool

    func makeNSView(context: Context) -> NSView { NSView() }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.setActive(active, view: view)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.setActive(false, view: view)
    }

    @MainActor
    final class Coordinator {
        private var monitor: Any?

        func setActive(_ active: Bool, view: NSView) {
            if !active, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            } else if active, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .systemDefined]) { [weak view] event in
                    guard let window = view?.window, window.isKeyWindow else { return event }
                    return nil
                }
            }
        }
    }
}
