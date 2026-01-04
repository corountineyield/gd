// GDMacro.swift - Complete & Fixed Geometry Dash Macro Bot for iOS
// Compilation: requires -lsubstrate or fishhook.c compiled alongside
import Foundation
import UIKit
import WebKit
import Darwin

// MARK: - Fishhook / C-Interop
// We define the C structure for fishhook here so Swift can use it.
struct rebinding {
    var name: UnsafePointer<CChar>
    var replacement: UnsafeMutableRawPointer
    var replaced: UnsafeMutablePointer<UnsafeMutableRawPointer?>
}

@_silgen_name("rebind_symbols")
func rebind_symbols(_ rebindings: UnsafeMutablePointer<rebinding>, _ rebindings_nel: Int) -> Int32

// MARK: - Global Hook Functions (MUST BE GLOBAL TO PREVENT CRASHES)
// These sit outside any class to ensure they have the correct C-calling convention.

func hook_began(
    instance: UnsafeMutableRawPointer,
    num: Int32,
    ids: UnsafeMutablePointer<Int>,
    xs: UnsafeMutablePointer<Float>,
    ys: UnsafeMutablePointer<Float>
) {
    // 1. Record that the user touched the screen (for Legit Mode)
    MacroManager.shared.onUserInput(down: true)
    
    // 2. Call the original game function
    TouchInjector.shared.originalBegan?(instance, num, ids, xs, ys)
}

func hook_ended(
    instance: UnsafeMutableRawPointer,
    num: Int32,
    ids: UnsafeMutablePointer<Int>,
    xs: UnsafeMutablePointer<Float>,
    ys: UnsafeMutablePointer<Float>
) {
    MacroManager.shared.onUserInput(down: false)
    TouchInjector.shared.originalEnded?(instance, num, ids, xs, ys)
}

// MARK: - GDR2 Replay Parser
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
        
        // Safe loading of bytes
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

// MARK: - Entry Point
@_cdecl("GDMacroInit")
public func GDMacroInit() {
    print("[GDMacro] === Initializing Safe Mode v2.0 ===")
    
    // Initialize logic on Main Thread to prevent threading crashes
    DispatchQueue.main.async {
        _ = MacroManager.shared
        // Delay UI injection slightly to let the game window settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            MacroUI.shared.inject()
        }
    }
}

// MARK: - Macro Manager
class MacroManager {
    static let shared = MacroManager()
    
    // Settings
    var isEnabled = false
    var practiceFix = false
    var legitMode = false
    var ignoreInputs = false
    
    // State
    var currentReplay: GDR2Replay?
    var isPlaying = false
    var currentFrame = 0
    var nextInputIndex = 0
    var inputCount = 0
    var userInputs: [(frame: Int, down: Bool)] = []
    
    // Paths
    let replayPath: String
    private var displayLink: CADisplayLink?
    
    private init() {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        replayPath = (docs as NSString).appendingPathComponent("Flero/flero/replays")
        try? FileManager.default.createDirectory(atPath: replayPath, withIntermediateDirectories: true)
        
        // Start the hooking process
        TouchInjector.shared.hookTouchEvents()
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
        let path = (replayPath as NSString).appendingPathComponent("\(name).gdr2")
        try? FileManager.default.removeItem(atPath: path)
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
            
            // Inject the touch
            TouchInjector.shared.injectTouch(down: input.down, player2: input.player2)
            
            inputCount += 1
            if inputCount % 30 == 0 { // Update UI less often for performance
                MacroUI.shared.updateInputCount(inputCount)
            }
            nextInputIndex += 1
        }
        
        // Cleanup old user inputs to save memory
        if userInputs.count > 100 { userInputs.removeFirst(50) }
        
        if nextInputIndex >= replay.inputs.count {
            stopPlayback()
            MacroUI.shared.updateStatus("Finished")
        }
    }
    
    func onUserInput(down: Bool) {
        if legitMode {
            userInputs.append((frame: currentFrame, down: down))
        }
    }
}

// MARK: - Touch Injector
class TouchInjector {
    static let shared = TouchInjector()
    
    // Correct C Function Signature
    typealias TouchFunc = @convention(c) (UnsafeMutableRawPointer, Int32, UnsafeMutablePointer<Int>, UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>) -> Void
    
    var originalBegan: TouchFunc?
    var originalEnded: TouchFunc?
    private var eglViewInstance: UnsafeMutableRawPointer?
    private var hooked = false
    
    func hookTouchEvents() {
        guard !hooked else { return }
        hooked = true
        
        print("[GDMacro] Finding EGLView...")
        findEGLViewInstance()
        
        // Symbol names for GD 2.2 / Cocos2d-x (These may vary by version!)
        let beganSym = "_ZN7cocos2d7CCEGLView17handleTouchesBeginEiPlPfS2_"
        let endedSym = "_ZN7cocos2d7CCEGLView15handleTouchesEndEiPlPfS2_"
        
        var rebindings: [rebinding] = [
            rebinding(
                name: (beganSym as NSString).utf8String!,
                replacement: unsafeBitCast(hook_began as TouchFunc, to: UnsafeMutableRawPointer.self),
                replaced: withUnsafeMutablePointer(to: &originalBegan) {
                    $0.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: 1) { $0 }
                }
            ),
            rebinding(
                name: (endedSym as NSString).utf8String!,
                replacement: unsafeBitCast(hook_ended as TouchFunc, to: UnsafeMutableRawPointer.self),
                replaced: withUnsafeMutablePointer(to: &originalEnded) {
                    $0.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: 1) { $0 }
                }
            )
        ]
        
        // Attempt to hook
        let ret = rebind_symbols(&rebindings, 2)
        print("[GDMacro] Hook result: \(ret) (0 is success)")
    }
    
    private func findEGLViewInstance() {
        // 1. Open main binary
        guard let handle = dlopen(nil, RTLD_NOW) else { return }
        
        // 2. Find CCDirector::sharedDirector
        if let sym = dlsym(handle, "_ZN7cocos2d10CCDirector14sharedDirectorEv") {
            typealias DirectorFunc = @convention(c) () -> UnsafeMutableRawPointer
            let getDirector = unsafeBitCast(sym, to: DirectorFunc.self)
            let director = getDirector()
            
            // 3. Get OpenGLView from vtable (Offset 0x28 is standard for ARM64 Cocos2dx)
            // We use 'advanced' to safely calculate pointer arithmetic
            let vtable = director.load(as: UnsafeMutableRawPointer.self)
            let methodPtr = vtable.advanced(by: 0x28).load(as: UnsafeMutableRawPointer.self)
            
            typealias GetViewFunc = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer
            let getView = unsafeBitCast(methodPtr, to: GetViewFunc.self)
            
            self.eglViewInstance = getView(director)
            print("[GDMacro] EGLView Instance found: \(self.eglViewInstance != nil)")
        } else {
            print("[GDMacro] Failed to find Director symbol")
        }
        
        dlclose(handle)
    }
    
    func injectTouch(down: Bool, player2: Bool) {
        guard let instance = eglViewInstance else { return }
        
        // Prepare arguments
        var id = player2 ? 1 : 0
        var x = Float(UIScreen.main.bounds.midX) // Click center of screen
        var y = Float(UIScreen.main.bounds.midY)
        
        if down {
            originalBegan?(instance, 1, &id, &x, &y)
        } else {
            originalEnded?(instance, 1, &id, &x, &y)
        }
    }
}

// MARK: - UI Overlay
class MacroUI: NSObject, WKScriptMessageHandler {
    static let shared = MacroUI()
    var webView: WKWebView?
    
    func inject() {
        DispatchQueue.main.async {
            // Find the main window safely
            guard let window = UIApplication.shared.windows.first(where: \.isKeyWindow) else {
                print("[GDMacro] No key window found")
                return
            }
            
            // Setup Webview communication
            let config = WKWebViewConfiguration()
            let handlers = ["settings", "playback", "loadReplay", "deleteReplay", "refresh"]
            handlers.forEach { config.userContentController.add(self, name: $0) }
            
            // Create WebView (Floating Window)
            let wv = WKWebView(frame: CGRect(x: 20, y: 100, width: 340, height: 500), configuration: config)
            wv.isOpaque = false
            wv.backgroundColor = .clear
            wv.scrollView.backgroundColor = .clear
            wv.layer.cornerRadius = 15
            wv.clipsToBounds = true
            
            // Add Dragging Support
            let pan = UIPanGestureRecognizer(target: self, action: #selector(self.handlePan(_:)))
            wv.addGestureRecognizer(pan)
            
            window.addSubview(wv)
            self.webView = wv
            
            // Load the Interface
            wv.loadHTMLString(self.getHTML(), baseURL: nil)
            
            // Initial Data Load
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.updateReplayList()
            }
        }
    }
    
    @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view = gesture.view else { return }
        let translation = gesture.translation(in: view.superview)
        view.center = CGPoint(x: view.center.x + translation.x, y: view.center.y + translation.y)
        gesture.setTranslation(.zero, in: view.superview)
    }
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        
        switch message.name {
        case "settings":
            MacroManager.shared.isEnabled = body["enabled"] as? Bool ?? false
            MacroManager.shared.practiceFix = body["practiceFix"] as? Bool ?? false
            MacroManager.shared.legitMode = body["legitMode"] as? Bool ?? false
            MacroManager.shared.ignoreInputs = body["ignoreInputs"] as? Bool ?? false
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
    
    func updateReplayList() {
        let list = MacroManager.shared.getReplayList()
        if let data = try? JSONSerialization.data(withJSONObject: list),
           let json = String(data: data, encoding: .utf8) {
            webView?.evaluateJavaScript("window.setReplayList(\(json))")
        }
    }
    
    func updateInputCount(_ count: Int) {
        webView?.evaluateJavaScript("document.getElementById('inputs').textContent = '\(count)'")
    }

    func updateStatus(_ status: String) {
        let safeStatus = status.replacingOccurrences(of: "'", with: "")
        webView?.evaluateJavaScript("document.getElementById('bot-status').textContent = '\(safeStatus)'")
    }
    
    // This is the Embedded HTML - No external file needed!
    private func getHTML() -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
            <style>
                :root { --bg: rgba(20, 20, 25, 0.95); --acc: #007aff; --txt: #fff; }
                body { font-family: -apple-system, sans-serif; background: transparent; color: var(--txt); margin: 0; padding: 15px; user-select: none; }
                .box { background: var(--bg); border-radius: 16px; padding: 15px; box-shadow: 0 4px 30px rgba(0,0,0,0.5); border: 1px solid rgba(255,255,255,0.1); }
                h2 { margin: 0 0 10px 0; font-size: 18px; display: flex; justify-content: space-between; }
                .status { font-size: 12px; color: #888; font-weight: normal; }
                .row { display: flex; justify-content: space-between; padding: 8px 0; border-bottom: 1px solid rgba(255,255,255,0.05); }
                input[type=checkbox] { width: 20px; height: 20px; }
                .list { height: 200px; overflow-y: auto; background: rgba(0,0,0,0.2); border-radius: 8px; margin: 10px 0; }
                .item { padding: 10px; border-bottom: 1px solid rgba(255,255,255,0.05); display: flex; justify-content: space-between; }
                .item:active { background: rgba(255,255,255,0.1); }
                .del { color: #ff3b30; font-weight: bold; padding: 0 10px; }
                .btns { display: flex; gap: 10px; margin-top: 10px; }
                button { flex: 1; padding: 12px; border: none; border-radius: 8px; font-weight: 600; background: #333; color: white; }
                button.primary { background: var(--acc); }
            </style>
        </head>
        <body>
            <div class="box">
                <h2>Flero <span class="status" id="bot-status">Idle</span></h2>
                <div class="row">Inputs: <span id="inputs">0</span></div>
                
                <div class="row"><span>Enabled</span><input type="checkbox" id="enabled"></div>
                <div class="row"><span>Speedhack Fix</span><input type="checkbox" id="practiceFix"></div>
                <div class="row"><span>Legit Mode</span><input type="checkbox" id="legitMode"></div>
                
                <div class="list" id="list"><div>Loading...</div></div>
                
                <div class="btns">
                    <button onclick="msg('refresh')">Refresh</button>
                    <button class="primary" id="playBtn" onclick="toggle()">Play</button>
                </div>
            </div>
            <script>
                const msg = (n, b={}) => window.webkit.messageHandlers[n].postMessage(b);
                
                function toggle() {
                    const btn = document.getElementById('playBtn');
                    const play = btn.innerText === 'Play';
                    btn.innerText = play ? 'Stop' : 'Play';
                    btn.style.background = play ? '#ff3b30' : '#007aff';
                    msg('playback', {play: play});
                }
                
                function load(n) { msg('loadReplay', {name: n}); }
                function del(e, n) { e.stopPropagation(); if(confirm('Del?')) msg('deleteReplay', {name: n}); }
                
                window.setReplayList = list => {
                    document.getElementById('list').innerHTML = list.map(n => 
                        `<div class="item" onclick="load('${n}')">
                            ${n} <span class="del" onclick="del(event, '${n}')">✕</span>
                        </div>`
                    ).join('');
                };
                
                document.querySelectorAll('input').forEach(i => i.onchange = () => {
                    msg('settings', {
                        enabled: document.getElementById('enabled').checked,
                        practiceFix: document.getElementById('practiceFix').checked,
                        legitMode: document.getElementById('legitMode').checked
                    });
                });
            </script>
        </body>
        </html>
        """
    }
}
