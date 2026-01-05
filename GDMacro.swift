// GDMacro.swift - Geode-Safe Geometry Dash Macro Bot (Swipe UI)
import Foundation
import UIKit
import WebKit
import ObjectiveC
import Darwin

// MARK: - Entry Point
@_cdecl("GDMacroInit")
public func GDMacroInit() {
    print("[GDMacro] === Initializing Geode-Safe Mode (Swipe UI) ===")
    DispatchQueue.main.async {
        _ = MacroManager.shared
        // Delay UI injection slightly to ensure Window is ready
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
    var ignoreInputs = false
    
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
            
            var shouldExecute = true
            if legitMode && !ignoreInputs {
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
        
        userInputs.removeAll { $0.frame < currentFrame - 60 }
        
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

// MARK: - Touch Injector (Geode Safe)
class TouchInjector {
    static let shared = TouchInjector()
    
    typealias TouchFunc = @convention(c) (UnsafeMutableRawPointer, Int32, UnsafeMutablePointer<Int>, UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>) -> Void
    typealias GetViewFunc = @convention(c) () -> UnsafeMutableRawPointer
    
    private var handleTouchesBegin: TouchFunc?
    private var handleTouchesEnd: TouchFunc?
    private var eglViewInstance: UnsafeMutableRawPointer?
    
    func setup() {
        if let handle = dlopen(nil, RTLD_NOW) {
            if let viewSym = dlsym(handle, "_ZN7cocos2d7CCEGLView15sharedOpenGLViewEv") {
                let getView = unsafeBitCast(viewSym, to: GetViewFunc.self)
                self.eglViewInstance = getView()
            }
            if let beginSym = dlsym(handle, "_ZN7cocos2d7CCEGLView17handleTouchesBeginEiPlPfS2_") {
                self.handleTouchesBegin = unsafeBitCast(beginSym, to: TouchFunc.self)
            }
            if let endSym = dlsym(handle, "_ZN7cocos2d7CCEGLView15handleTouchesEndEiPlPfS2_") {
                self.handleTouchesEnd = unsafeBitCast(endSym, to: TouchFunc.self)
            }
            dlclose(handle)
        }
        Swizzler.swizzleEAGL()
    }
    
    func playTouch(down: Bool, player2: Bool) {
        guard let instance = eglViewInstance else { return }
        var id = player2 ? 1 : 0
        var x = Float(UIScreen.main.bounds.midX)
        var y = Float(UIScreen.main.bounds.midY)
        if down { handleTouchesBegin?(instance, 1, &id, &x, &y) }
        else { handleTouchesEnd?(instance, 1, &id, &x, &y) }
    }
}

// MARK: - Swizzler
class Swizzler: NSObject {
    static func swizzleEAGL() {
        guard let cls = NSClassFromString("EAGLView") else { return }
        let originalBegan = class_getInstanceMethod(cls, #selector(UIView.touchesBegan(_:with:)))
        let swizzledBegan = class_getInstanceMethod(Swizzler.self, #selector(Swizzler.hook_touchesBegan(_:with:)))
        method_exchangeImplementations(originalBegan!, swizzledBegan!)
        
        let originalEnded = class_getInstanceMethod(cls, #selector(UIView.touchesEnded(_:with:)))
        let swizzledEnded = class_getInstanceMethod(Swizzler.self, #selector(Swizzler.hook_touchesEnded(_:with:)))
        method_exchangeImplementations(originalEnded!, swizzledEnded!)
    }
    
    @objc func hook_touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        MacroManager.shared.recordUserInput(down: true)
        self.hook_touchesBegan(touches, with: event)
    }
    
    @objc func hook_touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        MacroManager.shared.recordUserInput(down: false)
        self.hook_touchesEnded(touches, with: event)
    }
}

// MARK: - Macro UI (Updated with Gestures)
class MacroUI: NSObject, WKScriptMessageHandler {
    static let shared = MacroUI()
    var webView: WKWebView?
    var isVisible = false
    
    func inject() {
        DispatchQueue.main.async {
            guard let window = UIApplication.shared.windows.first(where: \.isKeyWindow) else { return }
            
            // 1. Setup Gestures (Swipe Left to Open, Right to Close)
            let openSwipe = UISwipeGestureRecognizer(target: self, action: #selector(self.handleOpenSwipe))
            openSwipe.direction = .left
            openSwipe.numberOfTouchesRequired = 2 // 2 Fingers to prevent accidental opening
            window.addGestureRecognizer(openSwipe)
            
            let closeSwipe = UISwipeGestureRecognizer(target: self, action: #selector(self.handleCloseSwipe))
            closeSwipe.direction = .right
            closeSwipe.numberOfTouchesRequired = 2
            window.addGestureRecognizer(closeSwipe)
            
            // 2. Setup WebView
            let config = WKWebViewConfiguration()
            ["settings","playback","loadReplay","deleteReplay","refresh"].forEach {
                config.userContentController.add(self, name: $0)
            }
            
            let wv = WKWebView(frame: CGRect(x: 20, y: 80, width: 320, height: 480), configuration: config)
            wv.isOpaque = false; wv.backgroundColor = .clear; wv.scrollView.backgroundColor = .clear
            wv.layer.cornerRadius = 16; wv.clipsToBounds = true
            
            // Hidden by default
            wv.alpha = 0
            wv.isHidden = true
            
            // Drag support
            let pan = UIPanGestureRecognizer(target: self, action: #selector(self.p(_:)))
            wv.addGestureRecognizer(pan)
            
            window.addSubview(wv)
            self.webView = wv
            
            wv.loadHTMLString(self.html, baseURL: nil)
            print("[GDMacro] UI Injected (Hidden). Swipe LEFT with 2 Fingers to open.")
        }
    }
    
    @objc func handleOpenSwipe() {
        guard let wv = webView, !isVisible else { return }
        isVisible = true
        wv.isHidden = false
        UIView.animate(withDuration: 0.3) { wv.alpha = 1.0 }
    }
    
    @objc func handleCloseSwipe() {
        guard let wv = webView, isVisible else { return }
        isVisible = false
        UIView.animate(withDuration: 0.3, animations: {
            wv.alpha = 0.0
        }) { _ in
            wv.isHidden = true
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
    body{font-family:system-ui;background:rgba(15,15,20,0.95);color:#fff;padding:15px;user-select:none;font-size:13px}
    .box{border:1px solid rgba(255,255,255,0.15);border-radius:14px;padding:15px}
    h3{margin:0 0 10px 0;display:flex;justify-content:space-between}
    .row{display:flex;justify-content:space-between;padding:10px 0;border-bottom:1px solid rgba(255,255,255,0.08)}
    .btn{background:#0a84ff;color:#fff;border:0;padding:12px;border-radius:10px;width:100%;font-weight:600;margin-top:10px}
    .list{height:200px;overflow-y:auto;background:rgba(0,0,0,0.3);border-radius:8px;margin:10px 0}
    .item{padding:10px;border-bottom:1px solid rgba(255,255,255,0.05);transition:0.2s}
    .item:active{background:rgba(255,255,255,0.15)}
    </style></head><body>
    <div class="box">
        <h3>Flero <span id="st" style="font-weight:400;color:#888">Idle</span></h3>
        <div class="row">Inputs: <span id="inputs">0</span></div>
        <div class="row"><span>Enabled</span><input type="checkbox" id="enabled"></div>
        <div class="row"><span>Legit Mode</span><input type="checkbox" id="legitMode"></div>
        <div class="list" id="list"><div>Loading...</div></div>
        <div style="display:flex;gap:8px">
            <button class="btn" style="background:#333" onclick="window.webkit.messageHandlers.refresh.postMessage({})">Refresh</button>
            <button class="btn" id="pBtn" onclick="toggle()">Play</button>
        </div>
        <div style="text-align:center;color:#666;font-size:10px;margin-top:10px">Swipe Right (2 Fingers) to Close</div>
    </div>
    <script>
    function toggle(){
        const b=document.getElementById('pBtn');
        const p=b.innerText==='Play';
        b.innerText=p?'Stop':'Play';
        b.style.background=p?'#ff453a':'#0a84ff';
        window.webkit.messageHandlers.playback.postMessage({play:p});
    }
    window.setReplayList=l=>{document.getElementById('list').innerHTML=l.map(n=>`<div class="item" onclick="window.webkit.messageHandlers.loadReplay.postMessage({name:'${n}'})">${n}</div>`).join('')};
    document.querySelectorAll('input').forEach(i=>i.onchange=()=>window.webkit.messageHandlers.settings.postMessage({enabled:document.getElementById('enabled').checked,legitMode:document.getElementById('legitMode').checked}));
    </script></body></html>
    """}
}
