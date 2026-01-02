// GDMacro.swift - Complete Geometry Dash Macro Bot for iOS
// Compile: see build.sh
import Foundation
import UIKit
import WebKit

// MARK: - GDR2 Replay Format Parser
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
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        guard data.count >= 8 else { return nil }
        let fps = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: Double.self) }
        var inputs: [GDR2Input] = []
        var offset = 8
        while offset + 6 <= data.count {
            let frame = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: Int32.self) }
            let flags = data[offset + 4]
            inputs.append(GDR2Input(frame: Int(frame), down: (flags & 0x01) != 0, player2: (flags & 0x02) != 0))
            offset += 6
        }
        let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".gdr2", with: "")
        print("[GDMacro] Parsed \(inputs.count) inputs at \(fps) FPS")
        return GDR2Replay(name: name, fps: fps, inputs: inputs)
    }
}

// MARK: - Entry Point
@_cdecl("GDMacroInit")
public func GDMacroInit() {
    print("[GDMacro] === Initializing GDMacro v1.0 ===")
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
        MacroUI.shared.inject()
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
        let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        replayPath = (documentsPath as NSString).appendingPathComponent("Flero/flero/replays")
        try? FileManager.default.createDirectory(atPath: replayPath, withIntermediateDirectories: true)
        print("[GDMacro] Replay path: \(replayPath)")
        TouchInjector.shared.hookTouchEvents()
    }
    
    func loadReplay(name: String) {
        let path = (replayPath as NSString).appendingPathComponent("\(name).gdr2")
        if let replay = GDR2Replay.parse(from: path) {
            currentReplay = replay
            resetPlayback()
            MacroUI.shared.updateStatus("Loaded: \(name)")
            print("[GDMacro] Loaded replay: \(name) with \(replay.inputs.count) inputs")
        }
    }

    func deleteReplay(name: String) {
        let path = (replayPath as NSString).appendingPathComponent("\(name).gdr2")
        try? FileManager.default.removeItem(atPath: path)
        print("[GDMacro] Deleted replay: \(name)")
        MacroUI.shared.updateReplayList()
        MacroUI.shared.updateStatus("Deleted")
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
        guard currentReplay != nil else {
            print("[GDMacro] No replay loaded")
            MacroUI.shared.updateStatus("No replay loaded")
            return
        }
        isPlaying = true
        resetPlayback()
        displayLink = CADisplayLink(target: self, selector: #selector(update))
        displayLink?.add(to: .main, forMode: .common)
        print("[GDMacro] Playback started")
    }
    
    func stopPlayback() {
        isPlaying = false
        displayLink?.invalidate()
        displayLink = nil
        print("[GDMacro] Playback stopped")
    }
    
    @objc func update() {
        guard isEnabled, let replay = currentReplay, isPlaying else { return }
        currentFrame += 1
        
        while nextInputIndex < replay.inputs.count {
            let input = replay.inputs[nextInputIndex]
            if input.frame > currentFrame { break }
            
            var shouldExecute = false
            
            if legitMode {
                let window = (input.frame - 15)...(input.frame + 5)
                if userInputs.contains(where: { window.contains($0.frame) && $0.down == input.down }) || ignoreInputs {
                    shouldExecute = true
                }
            } else {
                shouldExecute = true
            }
            
            if shouldExecute {
                TouchInjector.shared.injectTouch(down: input.down, player2: input.player2)
                inputCount += 1
                if inputCount % 50 == 0 {
                    MacroUI.shared.updateInputCount(inputCount)
                }
            }
            
            nextInputIndex += 1
        }
        
        userInputs.removeAll { $0.frame < currentFrame - 20 }
        
        // End of replay
        if nextInputIndex >= replay.inputs.count {
            stopPlayback()
            MacroUI.shared.updateStatus("Replay finished")
        }
    }
    
    func onUserInput(down: Bool) {
        if legitMode {
            userInputs.append((frame: currentFrame, down: down))
        }
    }
}

// MARK: - Fishhook Structures
struct rebinding {
    var name: UnsafePointer<CChar>
    var replacement: UnsafeMutableRawPointer
    var replaced: UnsafeMutablePointer<UnsafeMutableRawPointer?>
}

@_silgen_name("rebind_symbols")
func rebind_symbols(_ rebindings: UnsafeMutablePointer<rebinding>, _ rebindings_nel: Int) -> Int32

// MARK: - Touch Injector with Fishhook
class TouchInjector {
    static let shared = TouchInjector()
    
    // Cocos2d-x touch function signature (iOS arm64)
    // virtual void handleTouchesBegin(int num, intptr_t ids[], float xs[], float ys[]);
    typealias HandleTouchesFunc = @convention(c) (UnsafeMutableRawPointer, Int32, UnsafeMutablePointer<intptr_t>, UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>) -> Void
    
    private var originalBegan: HandleTouchesFunc?
    private var originalEnded: HandleTouchesFunc?
    private var eglViewInstance: UnsafeMutableRawPointer?
    private var hooked = false
    
    func hookTouchEvents() {
        guard !hooked else { return }
        hooked = true
        
        print("[GDMacro] Hooking Cocos2d-x touch events...")
        
        // Find CCEGLView instance
        findEGLViewInstance()
        
        // Hook handleTouchesBegin and handleTouchesEnd
        // Note: Symbol names may vary by iOS version - these are for Cocos2d-x 2.x on arm64
        var beganRebinding = rebinding(
            name: strdup("_ZN7cocos2d7CCEGLView17handleTouchesBeginEiPlPfS2_"),
            replacement: unsafeBitCast(hooked_handleTouchesBegan as HandleTouchesFunc, to: UnsafeMutableRawPointer.self),
            replaced: &originalBegan as! UnsafeMutablePointer<UnsafeMutableRawPointer?>
        )
        
        var endedRebinding = rebinding(
            name: strdup("_ZN7cocos2d7CCEGLView15handleTouchesEndEiPlPfS2_"),
            replacement: unsafeBitCast(hooked_handleTouchesEnded as HandleTouchesFunc, to: UnsafeMutableRawPointer.self),
            replaced: &originalEnded as! UnsafeMutablePointer<UnsafeMutableRawPointer?>
        )
        
        var rebindings = [beganRebinding, endedRebinding]
        let result = rebind_symbols(&rebindings, 2)
        
        if result == 0 {
            print("[GDMacro] ✓ Successfully hooked touch events")
        } else {
            print("[GDMacro] ✗ Failed to hook (error: \(result))")
            print("[GDMacro] ⚠️ Touch injection will use fallback mode")
        }
    }
    
    private func findEGLViewInstance() {
        // Try to get CCDirector singleton and extract EGLView
        // CCDirector::sharedDirector()->getOpenGLView()
        
        guard let handle = dlopen(nil, RTLD_NOW) else {
            print("[GDMacro] ✗ Failed to open main binary")
            return
        }
        
        // Try to find CCDirector::sharedDirector symbol
        // Mangled name for iOS arm64: _ZN7cocos2d10CCDirector14sharedDirectorEv
        if let directorFunc = dlsym(handle, "_ZN7cocos2d10CCDirector14sharedDirectorEv") {
            typealias DirectorFunc = @convention(c) () -> UnsafeMutableRawPointer
            let getDirector = unsafeBitCast(directorFunc, to: DirectorFunc.self)
            let director = getDirector()
            
            // Call getOpenGLView() on director instance
            // This is a C++ virtual function call - offset in vtable
            // Typically at offset +0x28 for Cocos2d-x 2.x
            let vtable = director.load(as: UnsafeMutableRawPointer.self)
            let getOpenGLViewPtr = (vtable + 0x28).load(as: UnsafeMutableRawPointer.self)
            typealias GetViewFunc = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer
            let getView = unsafeBitCast(getOpenGLViewPtr, to: GetViewFunc.self)
            eglViewInstance = getView(director)
            
            print("[GDMacro] ✓ Found CCEGLView instance: \(String(format: "%p", eglViewInstance!))")
        } else {
            print("[GDMacro] ✗ Failed to find CCDirector::sharedDirector")
        }
        
        dlclose(handle)
    }
    
    func injectTouch(down: Bool, player2: Bool) {
        guard let instance = eglViewInstance else {
            print("[GDMacro] ✗ No EGLView instance available")
            return
        }
        
        // Prepare touch data
        var touchId: intptr_t = player2 ? 1 : 0
        var x: Float = Float(UIScreen.main.bounds.width / 2)
        var y: Float = Float(UIScreen.main.bounds.height / 2)
        
        // Call the appropriate original function
        if down {
            if let began = originalBegan {
                began(instance, 1, &touchId, &x, &y)
            }
        } else {
            if let ended = originalEnded {
                ended(instance, 1, &touchId, &x, &y)
            }
        }
    }
}

// MARK: - Hooked Touch Functions
private func hooked_handleTouchesBegan(
    instance: UnsafeMutableRawPointer,
    num: Int32,
    ids: UnsafeMutablePointer<intptr_t>,
    xs: UnsafeMutablePointer<Float>,
    ys: UnsafeMutablePointer<Float>
) {
    // Track user input for legit mode
    MacroManager.shared.onUserInput(down: true)
    
    // Call original function
    if let original = TouchInjector.shared.originalBegan {
        original(instance, num, ids, xs, ys)
    }
}

private func hooked_handleTouchesEnded(
    instance: UnsafeMutableRawPointer,
    num: Int32,
    ids: UnsafeMutablePointer<intptr_t>,
    xs: UnsafeMutablePointer<Float>,
    ys: UnsafeMutablePointer<Float>
) {
    // Track user input for legit mode
    MacroManager.shared.onUserInput(down: false)
    
    // Call original function
    if let original = TouchInjector.shared.originalEnded {
        original(instance, num, ids, xs, ys)
    }
}

// MARK: - UI Overlay
class MacroUI: NSObject, WKScriptMessageHandler {
    static let shared = MacroUI()
    var webView: WKWebView?
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        switch message.name {
        case "settings":
            MacroManager.shared.isEnabled = body["enabled"] as? Bool ?? false
            MacroManager.shared.practiceFix = body["practiceFix"] as? Bool ?? false
            MacroManager.shared.legitMode = body["legitMode"] as? Bool ?? false
            MacroManager.shared.ignoreInputs = body["ignoreInputs"] as? Bool ?? false
            print("[GDMacro] Settings updated - Enabled: \(MacroManager.shared.isEnabled)")
        case "playback":
            if let play = body["play"] as? Bool {
                if play { MacroManager.shared.startPlayback() }
                else { MacroManager.shared.stopPlayback() }
            }
        case "loadReplay":
            if let name = body["name"] as? String {
                MacroManager.shared.loadReplay(name: name)
            }
        case "deleteReplay":
            if let name = body["name"] as? String {
                MacroManager.shared.deleteReplay(name: name)
            }
        case "refresh":
            updateReplayList()
        default: break
        }
    }
    
    func inject() {
        DispatchQueue.main.async {
            guard let keyWindow = UIApplication.shared.windows.first(where: \.isKeyWindow) else {
                print("[GDMacro] ✗ No key window found")
                return
            }
            
            let config = WKWebViewConfiguration()
            config.userContentController.add(self, name: "settings")
            config.userContentController.add(self, name: "playback")
            config.userContentController.add(self, name: "loadReplay")
            config.userContentController.add(self, name: "deleteReplay")
            config.userContentController.add(self, name: "refresh")
            
            let webView = WKWebView(frame: CGRect(x: 20, y: 100, width: 340, height: 520), configuration: config)
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.layer.cornerRadius = 20
            webView.clipsToBounds = true
            
            // Add pan gesture for dragging
            let pan = UIPanGestureRecognizer(target: self, action: #selector(self.handlePan(_:)))
            webView.addGestureRecognizer(pan)
            
            keyWindow.addSubview(webView)
            self.webView = webView
            
            webView.loadHTMLString(self.getEmbeddedHTML(), baseURL: nil)
            
            print("[GDMacro] ✓ UI injected successfully")
            
            // Auto-refresh replay list
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.updateReplayList()
            }
        }
    }
    
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view = gesture.view else { return }
        let translation = gesture.translation(in: view.superview)
        view.center = CGPoint(x: view.center.x + translation.x, y: view.center.y + translation.y)
        gesture.setTranslation(.zero, in: view.superview)
    }
    
    func updateReplayList() {
        let replays = MacroManager.shared.getReplayList()
        print("[GDMacro] Found \(replays.count) replays")
        if let json = try? JSONSerialization.data(withJSONObject: replays),
           let jsonString = String(data: json, encoding: .utf8) {
            webView?.evaluateJavaScript("window.setReplayList(\(jsonString))")
        }
    }

    func updateInputCount(_ count: Int) {
        webView?.evaluateJavaScript("document.getElementById('inputs').textContent = '\(count)'")
    }

    func updateStatus(_ status: String) {
        let escaped = status.replacingOccurrences(of: "'", with: "\\'")
        webView?.evaluateJavaScript("document.getElementById('bot-status').textContent = '\(escaped)'")
    }
    
    private func getEmbeddedHTML() -> String {
        return """
        <!DOCTYPE html><html><head><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no"><style>:root{--bg:rgba(20,20,25,0.95);--accent:#007aff;--text:#fff;--text-dim:#a0a0a0;--border:rgba(255,255,255,0.1)}body{font-family:-apple-system,sans-serif;background:transparent;color:var(--text);margin:0;padding:15px;user-select:none}.container{background:var(--bg);backdrop-filter:blur(30px);-webkit-backdrop-filter:blur(30px);border:1px solid var(--border);border-radius:20px;padding:20px;box-shadow:0 10px 50px rgba(0,0,0,0.6)}.header{display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:20px}.title-group h1{font-size:20px;margin:0;font-weight:700}.stats{font-size:13px;color:var(--text-dim);margin-top:4px}.replay-tag{font-size:13px;color:var(--text-dim)}.section-label{font-size:11px;color:var(--text-dim);text-transform:uppercase;letter-spacing:0.5px;margin:15px 0 8px 5px}.controls-grid{background:rgba(255,255,255,0.05);border-radius:12px;overflow:hidden}.row{display:flex;align-items:center;padding:12px 15px;border-bottom:1px solid var(--border)}.row:last-child{border-bottom:none}.row span{flex:1;font-size:15px}input[type="checkbox"]{width:20px;height:20px;accent-color:var(--accent)}.file-browser{background:rgba(255,255,255,0.05);border-radius:12px;max-height:180px;overflow-y:auto;margin:10px 0}.file-item{padding:12px 15px;font-size:14px;border-bottom:1px solid var(--border);display:flex;justify-content:space-between;align-items:center;transition:0.2s}.file-item:active{background:rgba(255,255,255,0.1)}.file-item.active{color:var(--accent);font-weight:600}.delete-btn{color:#ff3b30;font-size:11px;padding:4px 8px;background:rgba(255,59,48,0.15);border-radius:6px;cursor:pointer}.bottom-actions{display:flex;gap:10px;margin-top:20px}.btn{flex:1;padding:14px;border:none;border-radius:12px;font-weight:600;font-size:15px;cursor:pointer;transition:0.2s}.btn-gray{background:#3a3a3c;color:white}.btn-blue{background:var(--accent);color:white}.btn:active{transform:scale(0.96);opacity:0.8}.status-indicator{text-align:center;font-size:12px;color:var(--text-dim);margin-top:15px}#bot-status{color:var(--accent);font-weight:700}</style></head><body><div class="container"><div class="header"><div class="title-group"><h1>Flero Macro</h1><div class="stats">Inputs: <span id="inputs">0</span></div></div><div class="replay-tag" id="replay-name">.gdr2</div></div><div class="section-label">Settings</div><div class="controls-grid"><div class="row"><span>Enabled</span><input type="checkbox" id="enabled"></div><div class="row"><span>Practice Fix</span><input type="checkbox" id="practiceFix"></div><div class="row"><span>Legit Mode</span><input type="checkbox" id="legitMode"></div><div class="row"><span>Ignore Inputs</span><input type="checkbox" id="ignoreInputs"></div></div><div class="section-label">Replays</div><div class="file-browser" id="replay-list"><div class="file-item">Tap Refresh...</div></div><div class="bottom-actions"><button class="btn btn-gray" onclick="window.webkit.messageHandlers.refresh.postMessage({})">Refresh</button><button class="btn btn-blue" id="play-btn" onclick="togglePlay()">Play</button></div><div class="status-indicator">Bot: <span id="bot-status">Stopped</span></div></div><script>function togglePlay(){const btn=document.getElementById('play-btn');const status=document.getElementById('bot-status');const isPlaying=btn.textContent==='Stop';window.webkit.messageHandlers.playback.postMessage({play:!isPlaying});btn.textContent=isPlaying?'Play':'Stop';status.textContent=isPlaying?'Stopped':'Playback'}function loadFile(name){window.webkit.messageHandlers.loadReplay.postMessage({name:name});document.getElementById('replay-name').textContent=name+'.gdr2';document.querySelectorAll('.file-item').forEach(el=>el.classList.toggle('active',el.getAttribute('data-name')===name))}function deleteFile(event,name){event.stopPropagation();if(confirm('Delete '+name+'?'))window.webkit.messageHandlers.deleteReplay.postMessage({name:name})}window.setReplayList=function(list){const container=document.getElementById('replay-list');container.innerHTML=list.map(name=>`<div class="file-item" data-name="${name}" onclick="loadFile('${name}')"><span>${name}</span><span class="delete-btn" onclick="deleteFile(event,'${name}')">Delete</span></div>`).join('')};document.querySelectorAll('input').forEach(input=>{input.addEventListener('change',()=>{window.webkit.messageHandlers.settings.postMessage({enabled:document.getElementById('enabled').checked,practiceFix:document.getElementById('practiceFix').checked,legitMode:document.getElementById('legitMode').checked,ignoreInputs:document.getElementById('ignoreInputs').checked})})})</script></body></html>
        """
    }
}
