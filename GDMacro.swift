// GDMacro.swift - Geode-Safe Geometry Dash Macro Bot (iOS 2.206+)
// Compile with your standard Swift setup
import Foundation
import UIKit
import WebKit
import ObjectiveC
import Darwin

// MARK: - Entry Point
@_cdecl("GDMacroInit")
public func GDMacroInit() {
    print("[GDMacro] === Initializing Geode-Safe Mode ===")
    // Initialize on Main Thread
    DispatchQueue.main.async {
        _ = MacroManager.shared
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            MacroUI.shared.inject()
        }
    }
}

// MARK: - GDR2 Replay Format
struct GDR2Input {
    let frame: Int
    let down: Bool
    let player2: Bool
}

struct GDR2Replay {
    let name: String
    let fps: Double
    let inputs: [GDR2Input]
    
    static func parse(from path: String) -> GDR2Replay? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count >= 8 else { return nil }
        let fps = data.withUnsafeBytes { $0.load(as: Double.self) }
        var inputs: [GDR2Input] = []
        var offset = 8
        while offset + 6 <= data.count {
            let frame = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: Int32.self) }
            let flags = data[offset + 4]
            inputs.append(GDR2Input(frame: Int(frame), down: (flags & 0x01) != 0, player2: (flags & 0x02) != 0))
            offset += 6
        }
        let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".gdr2", with: "")
        return GDR2Replay(name: name, fps: fps, inputs: inputs)
    }
}

// MARK: - Macro Manager
class MacroManager {
    static let shared = MacroManager()
    
    var isEnabled = false
    var practiceFix = false
    var legitMode = false
    var ignoreInputs = false // If true, bot clicks even if you click
    
    var currentReplay: GDR2Replay?
    var isPlaying = false
    var currentFrame = 0
    var nextInputIndex = 0
    var inputCount = 0
    var userInputs: [(frame: Int, down: Bool)] = []
    
    let replayPath: String
    private var displayLink: CADisplayLink?
    
    private init() {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        replayPath = (docs as NSString).appendingPathComponent("Flero/flero/replays")
        try? FileManager.default.createDirectory(atPath: replayPath, withIntermediateDirectories: true)
        
        // Setup Touch System
        TouchInjector.shared.setup()
    }
    
    func loadReplay(name: String) {
        let path = (replayPath as NSString).appendingPathComponent("\(name).gdr2")
        if let replay = GDR2Replay.parse(from: path) {
            currentReplay = replay
            resetPlayback()
            MacroUI.shared.updateStatus("Loaded: \(name)")
        }
    }
    
    func deleteReplay(name: String) {
        try? FileManager.default.removeItem(atPath: (replayPath as NSString).appendingPathComponent("\(name).gdr2"))
        MacroUI.shared.updateReplayList()
    }
    
    func getReplayList() -> [String] {
        return (try? FileManager.default.contentsOfDirectory(atPath: replayPath))?
            .filter { $0.hasSuffix(".gdr2") }
            .map { ($0 as NSString).deletingPathExtension }
            .sorted() ?? []
    }
    
    func resetPlayback() {
        currentFrame = 0
        nextInputIndex = 0
        inputCount = 0
        userInputs.removeAll()
        MacroUI.shared.updateInputCount(0)
    }
    
    func startPlayback() {
        guard currentReplay != nil else { return }
        isPlaying = true
        resetPlayback()
        displayLink?.invalidate()
        displayLink = CADisplayLink(target: self, selector: #selector(update))
        displayLink?.add(to: .main, forMode: .common)
        MacroUI.shared.updateStatus("Playing...")
    }
    
    func stopPlayback() {
        isPlaying = false
        displayLink?.invalidate()
        displayLink = nil
        MacroUI.shared.updateStatus("Stopped")
    }
    
    @objc func update() {
        guard isEnabled, let replay = currentReplay, isPlaying else { return }
        currentFrame += 1
        
        while nextInputIndex < replay.inputs.count {
            let input = replay.inputs[nextInputIndex]
            if input.frame > currentFrame { break }
            
            // Legit Mode Logic
            var shouldExecute = true
            if legitMode && !ignoreInputs {
                // Check if user clicked recently (window of 10 frames)
                let frameWindow = (currentFrame - 10)...(currentFrame + 10)
                let userClicked = userInputs.contains { frameWindow.contains($0.frame) && $0.down == input.down }
                if !userClicked { shouldExecute = false }
            }
            
            if shouldExecute {
                TouchInjector.shared.playTouch(down: input.down, player2: input.player2)
                inputCount += 1
                if inputCount % 60 == 0 { MacroUI.shared.updateInputCount(inputCount) }
            }
            nextInputIndex += 1
        }
        
        userInputs.removeAll { $0.frame < currentFrame - 60 } // Cleanup
        
        if nextInputIndex >= replay.inputs.count {
            stopPlayback()
            MacroUI.shared.updateStatus("Finished")
        }
    }
    
    func recordUserInput(down: Bool) {
        if legitMode {
            userInputs.append((frame: currentFrame, down: down))
        }
    }
}

// MARK: - Touch Injector (The Fix)
class TouchInjector {
    static let shared = TouchInjector()
    
    // C Function Pointers for GD 2.2
    // CCEGLView::handleTouchesBegin(int, intptr_t*, float*, float*)
    typealias TouchFunc = @convention(c) (UnsafeMutableRawPointer, Int32, UnsafeMutablePointer<Int>, UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>) -> Void
    typealias GetViewFunc = @convention(c) () -> UnsafeMutableRawPointer
    
    private var handleTouchesBegin: TouchFunc?
    private var handleTouchesEnd: TouchFunc?
    private var eglViewInstance: UnsafeMutableRawPointer?
    
    func setup() {
        print("[GDMacro] Setting up Touch System...")
        
        // 1. Find C++ Functions for Playback (Using dlsym)
        if let handle = dlopen(nil, RTLD_NOW) {
            
            // CCEGLView::sharedOpenGLView() - Safer than Director Offset
            if let viewSym = dlsym(handle, "_ZN7cocos2d7CCEGLView15sharedOpenGLViewEv") {
                let getView = unsafeBitCast(viewSym, to: GetViewFunc.self)
                self.eglViewInstance = getView()
                print("[GDMacro] Found OpenGLView Instance")
            }
            
            // Touch Begin
            if let beginSym = dlsym(handle, "_ZN7cocos2d7CCEGLView17handleTouchesBeginEiPlPfS2_") {
                self.handleTouchesBegin = unsafeBitCast(beginSym, to: TouchFunc.self)
            }
            
            // Touch End
            if let endSym = dlsym(handle, "_ZN7cocos2d7CCEGLView15handleTouchesEndEiPlPfS2_") {
                self.handleTouchesEnd = unsafeBitCast(endSym, to: TouchFunc.self)
            }
            
            dlclose(handle)
        }
        
        // 2. Swizzle EAGLView for Recording (Native iOS Hook)
        // This hooks the raw iOS touch events before they reach C++
        Swizzler.swizzleEAGL()
    }
    
    func playTouch(down: Bool, player2: Bool) {
        guard let instance = eglViewInstance else { return }
        
        var id = player2 ? 1 : 0
        var x = Float(UIScreen.main.bounds.midX)
        var y = Float(UIScreen.main.bounds.midY)
        
        if down {
            handleTouchesBegin?(instance, 1, &id, &x, &y)
        } else {
            handleTouchesEnd?(instance, 1, &id, &x, &y)
        }
    }
}

// MARK: - Swizzler (Recording)
class Swizzler: NSObject {
    static func swizzleEAGL() {
        // GD uses EAGLView (subclass of UIView) on iOS
        guard let cls = NSClassFromString("EAGLView") else {
            print("[GDMacro] EAGLView not found")
            return
        }
        
        let originalBegan = class_getInstanceMethod(cls, #selector(UIView.touchesBegan(_:with:)))
        let swizzledBegan = class_getInstanceMethod(Swizzler.self, #selector(Swizzler.hook_touchesBegan(_:with:)))
        method_exchangeImplementations(originalBegan!, swizzledBegan!)
        
        let originalEnded = class_getInstanceMethod(cls, #selector(UIView.touchesEnded(_:with:)))
        let swizzledEnded = class_getInstanceMethod(Swizzler.self, #selector(Swizzler.hook_touchesEnded(_:with:)))
        method_exchangeImplementations(originalEnded!, swizzledEnded!)
        
        print("[GDMacro] Swizzled EAGLView for recording")
    }
    
    @objc func hook_touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        MacroManager.shared.recordUserInput(down: true)
        // Call original (which is now stored in this selector)
        self.hook_touchesBegan(touches, with: event)
    }
    
    @objc func hook_touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        MacroManager.shared.recordUserInput(down: false)
        self.hook_touchesEnded(touches, with: event)
    }
}

// MARK: - UI Overlay
class MacroUI: NSObject, WKScriptMessageHandler {
    static let shared = MacroUI()
    var webView: WKWebView?
    
    func inject() {
        DispatchQueue.main.async {
            guard let window = UIApplication.shared.windows.first(where: \.isKeyWindow) else { return }
            
            let config = WKWebViewConfiguration()
            ["settings","playback","loadReplay","deleteReplay","refresh"].forEach {
                config.userContentController.add(self, name: $0)
            }
            
            let wv = WKWebView(frame: CGRect(x: 20, y: 100, width: 340, height: 500), configuration: config)
            wv.isOpaque = false; wv.backgroundColor = .clear; wv.scrollView.backgroundColor = .clear
            wv.layer.cornerRadius = 15; wv.clipsToBounds = true
            
            let pan = UIPanGestureRecognizer(target: self, action: #selector(self.p(_:)))
            wv.addGestureRecognizer(pan)
            window.addSubview(wv)
            self.webView = wv
            
            wv.loadHTMLString(self.html, baseURL: nil)
        }
    }
    
    @objc func p(_ g: UIPanGestureRecognizer) {
        guard let v = g.view else { return }
        let t = g.translation(in: v.superview)
        v.center = CGPoint(x: v.center.x + t.x, y: v.center.y + t.y)
        g.setTranslation(.zero, in: v.superview)
    }
    
    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let b = m.body as? [String: Any] else { return }
        switch m.name {
        case "playback":
            if let p = b["play"] as? Bool { p ? MacroManager.shared.startPlayback() : MacroManager.shared.stopPlayback() }
        case "loadReplay":
            if let n = b["name"] as? String { MacroManager.shared.loadReplay(name: n) }
        case "refresh":
            updateReplayList()
        case "settings":
            MacroManager.shared.isEnabled = b["enabled"] as? Bool ?? false
            MacroManager.shared.legitMode = b["legitMode"] as? Bool ?? false
        default: break
        }
    }
    
    func updateReplayList() {
        let l = MacroManager.shared.getReplayList()
        if let d = try? JSONSerialization.data(withJSONObject: l), let s = String(data: d, encoding: .utf8) {
            webView?.evaluateJavaScript("window.setReplayList(\(s))")
        }
    }
    
    func updateInputCount(_ c: Int) { webView?.evaluateJavaScript("document.getElementById('inputs').textContent = '\(c)'") }
    func updateStatus(_ s: String) { webView?.evaluateJavaScript("document.getElementById('st').textContent = '\(s)'") }
    
    var html: String { return """
    <!DOCTYPE html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>
    body{font-family:system-ui;background:rgba(20,20,25,0.95);color:#fff;padding:15px;user-select:none;font-size:14px}
    .box{border:1px solid rgba(255,255,255,0.1);border-radius:12px;padding:15px}
    .row{display:flex;justify-content:space-between;padding:8px 0;border-bottom:1px solid rgba(255,255,255,0.05)}
    .btn{background:#007aff;color:#fff;border:0;padding:12px;border-radius:8px;width:100%;font-weight:600;margin-top:10px}
    .list{height:180px;overflow-y:auto;background:rgba(0,0,0,0.3);border-radius:8px;margin:10px 0}
    .item{padding:10px;border-bottom:1px solid rgba(255,255,255,0.05)}
    .item:active{background:rgba(255,255,255,0.1)}
    </style></head><body>
    <div class="box">
        <h3>Flero Macro <span id="st" style="font-size:12px;color:#888;font-weight:400">Idle</span></h3>
        <div class="row">Inputs: <span id="inputs">0</span></div>
        <div class="row"><span>Enabled</span><input type="checkbox" id="enabled"></div>
        <div class="row"><span>Legit Mode</span><input type="checkbox" id="legitMode"></div>
        <div class="list" id="list"><div>Loading...</div></div>
        <div style="display:flex;gap:10px">
            <button class="btn" style="background:#333" onclick="window.webkit.messageHandlers.refresh.postMessage({})">Refresh</button>
            <button class="btn" id="pBtn" onclick="toggle()">Play</button>
        </div>
    </div>
    <script>
    function toggle(){
        const b=document.getElementById('pBtn');
        const p=b.innerText==='Play';
        b.innerText=p?'Stop':'Play';
        b.style.background=p?'#ff3b30':'#007aff';
        window.webkit.messageHandlers.playback.postMessage({play:p});
    }
    window.setReplayList=l=>{document.getElementById('list').innerHTML=l.map(n=>`<div class="item" onclick="window.webkit.messageHandlers.loadReplay.postMessage({name:'${n}'})">${n}</div>`).join('')};
    document.querySelectorAll('input').forEach(i=>i.onchange=()=>window.webkit.messageHandlers.settings.postMessage({enabled:document.getElementById('enabled').checked,legitMode:document.getElementById('legitMode').checked}));
    </script></body></html>
    """}
}
