//
//  DirectorServer.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import Foundation
import Network

// MARK: - Director Server

class DirectorServer {
    private var httpListener: NWListener?
    private var wsListener: NWListener?
    private var wsConnections: [NWConnection] = []
    private var authenticatedConnections: Set<ObjectIdentifier> = []
    private var broadcastTimer: Timer?

    // Connection limit to prevent resource exhaustion (CWE-400)
    private let maxConnections = 5

    // Dedicated queue for broadcasting to avoid blocking the main/UI thread
    private let broadcastQueue = DispatchQueue(label: "com.textream.director.broadcast")
    // Security: shared secret token for WebSocket authentication
    private var authToken: String = ""

    // Content state
    private var words: [String] = []
    private var totalCharCount: Int = 0
    private weak var speechRecognizer: SpeechRecognizer?
    private weak var overlayContent: OverlayContent?
    private var contentActive: Bool = false
    private var lastBroadcastState: Data?

    // Callbacks
    var onSetText: ((String) -> Void)?
    var onUpdateText: ((String, Int) -> Void)?
    var onStop: (() -> Void)?

    var httpPort: UInt16 { NotchSettings.shared.directorServerPort }
    var wsPort: UInt16 { httpPort + 1 }
    var isRunning: Bool { httpListener != nil }
    var connectedClients: Int { wsConnections.count }

    // MARK: - Lifecycle

    func start() {
        stop()
        authToken = Self.generateToken()
        startHTTPListener()
        startWSListener()
    }

    func stop() {
        broadcastTimer?.invalidate()
        broadcastTimer = nil

        httpListener?.cancel()
        httpListener = nil
        wsListener?.cancel()
        wsListener = nil

        for conn in wsConnections { conn.cancel() }
        wsConnections.removeAll()
        authenticatedConnections.removeAll()
        contentActive = false
    }

    // MARK: - Content Management

    func showContent(speechRecognizer: SpeechRecognizer, content: OverlayContent) {
        self.speechRecognizer = speechRecognizer
        self.overlayContent = content
        self.words = content.words
        self.totalCharCount = content.totalCharCount
        self.contentActive = true
        startBroadcasting()
    }

    func updateContent(words: [String], totalCharCount: Int) {
        self.words = words
        self.totalCharCount = totalCharCount
    }

    func hideContent() {
        contentActive = false
        broadcastTimer?.invalidate()
        broadcastTimer = nil
        broadcastInactive()
    }

    // MARK: - HTTP Server

    private func startHTTPListener() {
        guard let port = NWEndpoint.Port(rawValue: httpPort) else { return }
        do {
            httpListener = try NWListener(using: .tcp, on: port)
        } catch { return }

        httpListener?.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.httpListener = nil }
        }
        httpListener?.newConnectionHandler = { [weak self] conn in
            self?.handleHTTPConnection(conn)
        }
        httpListener?.start(queue: .main)
    }

    private func handleHTTPConnection(_ conn: NWConnection) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self else { conn.cancel(); return }
            guard error == nil else { conn.cancel(); return }

            let response = self.buildHTTPResponse()
            conn.send(content: response, completion: .contentProcessed { _ in
                conn.cancel()
            })
        }
    }

    private func buildHTTPResponse() -> Data {
        let html = Self.generateHTML(wsPort: wsPort, authToken: authToken)
        let body = Data(html.utf8)
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        return Data(header.utf8) + body
    }

    // MARK: - WebSocket Server

    private func startWSListener() {
        guard let port = NWEndpoint.Port(rawValue: wsPort) else { return }
        let params = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        do {
            wsListener = try NWListener(using: params, on: port)
        } catch { return }

        wsListener?.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.wsListener = nil }
        }
        wsListener?.newConnectionHandler = { [weak self] conn in
            self?.handleWSConnection(conn)
        }
        wsListener?.start(queue: .main)
    }

    private func handleWSConnection(_ conn: NWConnection) {
        guard wsConnections.count < maxConnections else {
            conn.cancel()
            return
        }
        conn.start(queue: .main)
        wsConnections.append(conn)
        receiveWSMessage(conn)

        // Auto-disconnect unauthenticated connections after 5 seconds
        let connId = ObjectIdentifier(conn)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            if !self.authenticatedConnections.contains(connId) {
                conn.cancel()
            }
        }

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.wsConnections.removeAll { $0 === conn }
                self?.authenticatedConnections.remove(ObjectIdentifier(conn))
            default: break
            }
        }
    }

    private func receiveWSMessage(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            if error != nil { conn.cancel(); return }
            if let data {
                self?.handleIncomingMessage(data, from: conn)
            }
            self?.receiveWSMessage(conn)
        }
    }

    private func handleIncomingMessage(_ data: Data, from conn: NWConnection) {
        guard let command = try? JSONDecoder().decode(DirectorCommand.self, from: data) else { return }
        let connId = ObjectIdentifier(conn)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // First message must be authentication
            if !self.authenticatedConnections.contains(connId) {
                if command.type == "auth", command.text == self.authToken {
                    self.authenticatedConnections.insert(connId)
                } else {
                    conn.cancel()
                }
                return
            }

            switch command.type {
            case "setText":
                if let text = command.text {
                    self.onSetText?(text)
                }
            case "updateText":
                if let text = command.text, let readCharCount = command.readCharCount {
                    self.onUpdateText?(text, readCharCount)
                }
            case "stop":
                self.onStop?()
            default:
                break
            }
        }
    }

    // MARK: - Token Generation

    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Broadcasting

    private func startBroadcasting() {
        broadcastTimer?.invalidate()
        broadcastTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.broadcastCurrentState()
        }
    }

    private func broadcastCurrentState() {
        guard contentActive, !wsConnections.isEmpty else { return }

        words = overlayContent?.words ?? words
        totalCharCount = overlayContent?.totalCharCount ?? totalCharCount
        let charCount = overlayContent?.highlightedCharCount ?? speechRecognizer?.recognizedCharCount ?? 0
        let effective = min(charCount, totalCharCount)
        let isDone = totalCharCount > 0 && effective >= totalCharCount
        let trackingState = overlayContent?.trackingState.rawValue ?? speechRecognizer?.trackingState.rawValue ?? TrackingState.tracking.rawValue
        let confidenceLevel = overlayContent?.confidenceLevel.rawValue ?? speechRecognizer?.confidenceLevel.rawValue ?? TrackingConfidence.low.rawValue
        let expectedWord = overlayContent?.expectedWord ?? speechRecognizer?.expectedWord ?? ""
        let nextCue = overlayContent?.nextCue ?? speechRecognizer?.nextCue ?? ""
        let manualAsideActive = (overlayContent?.manualAsideMode.isActive ?? speechRecognizer?.manualAsideMode.isActive ?? false)

        let state = DirectorState(
            words: words,
            highlightedCharCount: effective,
            totalCharCount: totalCharCount,
            isActive: true,
            isDone: isDone,
            isListening: speechRecognizer?.isListening ?? false,
            fontColor: NotchSettings.shared.fontColorPreset.cssColor,
            cueColor: NotchSettings.shared.cueColorPreset.cssColor,
            lastSpokenText: speechRecognizer?.lastSpokenText ?? "",
            audioLevels: (speechRecognizer?.audioLevels ?? []).map { Double($0) },
            trackingState: trackingState,
            confidenceLevel: confidenceLevel,
            expectedWord: expectedWord,
            nextCue: nextCue,
            manualAsideActive: manualAsideActive
        )
        broadcast(state)
    }

    private func broadcastInactive() {
        let state = DirectorState(
            words: [], highlightedCharCount: 0, totalCharCount: 0,
            isActive: false, isDone: false, isListening: false,
            fontColor: "#ffffff", cueColor: "#ffffff", lastSpokenText: "",
            audioLevels: [],
            trackingState: TrackingState.tracking.rawValue,
            confidenceLevel: TrackingConfidence.low.rawValue,
            expectedWord: "",
            nextCue: "",
            manualAsideActive: false
        )
        broadcast(state)
    }

    private func broadcast(_ state: DirectorState) {
        guard !wsConnections.isEmpty, let data = try? JSONEncoder().encode(state) else { return }

        // Skip broadcast if state hasn't changed
        if let last = lastBroadcastState, last == data { return }
        lastBroadcastState = data

        let connections = wsConnections.filter { authenticatedConnections.contains(ObjectIdentifier($0)) }
        guard !connections.isEmpty else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "ws", metadata: [meta])

        broadcastQueue.async {
            for conn in connections {
                conn.send(content: data, contentContext: ctx, completion: .idempotent)
            }
        }
    }

    // MARK: - HTML Template

    static func generateHTML(wsPort: UInt16, authToken: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
        <title>Textream Director</title>
        <style>
        *{margin:0;padding:0;box-sizing:border-box}
        html,body{height:100%;overflow:hidden;background:#0a0a0a;color:#fff;
          font-family:-apple-system,BlinkMacSystemFont,'SF Pro Display','Helvetica Neue',system-ui,sans-serif}
        body{display:flex;flex-direction:column}

        /* Status bar */
        #status-bar{flex-shrink:0;padding:12px 20px;display:flex;align-items:center;gap:12px;
          border-bottom:1px solid rgba(255,255,255,0.08);background:rgba(0,0,0,0.4)}
        #status-dot{width:8px;height:8px;border-radius:50%;background:#ef4444;flex-shrink:0}
        #status-dot.connected{background:#22c55e}
        #status-dot.active{background:#facc15;animation:pulse-dot 1.5s ease-in-out infinite}
        @keyframes pulse-dot{0%,100%{opacity:1}50%{opacity:0.4}}
        #status-text{font-size:13px;color:rgba(255,255,255,0.5);flex:1}
        #progress-text{font-size:13px;font-weight:600;color:rgba(255,255,255,0.4);
          font-variant-numeric:tabular-nums}

        /* Editor area */
        #editor-wrap{flex:1;overflow:hidden;position:relative}
        #editor-container{height:100%;overflow-y:auto;padding:20px;
          -webkit-overflow-scrolling:touch}
        #editor-container::-webkit-scrollbar{display:none}

        /* Read portion (locked) */
        #read-text{color:rgba(255,255,255,0.35);font-size:18px;line-height:1.7;
          font-weight:500;white-space:pre-wrap;word-wrap:break-word;
          pointer-events:none;user-select:none}
        #read-text:empty{display:none}

        /* Editable portion */
        #edit-text{color:#fff;font-size:18px;line-height:1.7;font-weight:500;
          white-space:pre-wrap;word-wrap:break-word;outline:none;
          min-height:60vh;caret-color:#facc15}
        #edit-text:empty::before{content:attr(data-placeholder);color:rgba(255,255,255,0.2)}

        /* Divider between read and edit */
        #read-divider{height:2px;background:linear-gradient(to right,#facc15,transparent);
          margin:8px 0;border-radius:1px;display:none}
        #read-divider.visible{display:block}

        /* Bottom controls */
        #controls{flex-shrink:0;padding:16px 20px;
          border-top:1px solid rgba(255,255,255,0.08);
          display:flex;align-items:center;gap:12px;background:rgba(0,0,0,0.4)}
        .ctrl-btn{border:none;border-radius:12px;padding:12px 28px;font-size:15px;
          font-weight:600;cursor:pointer;transition:all .15s ease;
          display:flex;align-items:center;gap:8px}
        #go-btn{background:#22c55e;color:#fff}
        #go-btn:hover{background:#16a34a}
        #go-btn:active{transform:scale(0.97)}
        #go-btn.running{background:#ef4444}
        #go-btn.running:hover{background:#dc2626}
        #go-btn:disabled{opacity:0.4;cursor:not-allowed}

        /* Waveform */
        #waveform{display:flex;align-items:center;gap:1.5px;height:28px;flex:1;
          justify-content:flex-end}
        .wf{width:2.5px;background:rgba(255,255,255,.1);border-radius:1.5px;
          min-height:2px;transition:height .08s ease,background .12s ease;align-self:center}

        /* Mic indicator */
        #mic-indicator{width:32px;height:32px;border-radius:50%;
          background:rgba(255,255,255,0.08);display:flex;align-items:center;
          justify-content:center;flex-shrink:0;font-size:14px}
        #mic-indicator.on{background:rgba(250,204,21,0.2)}

        /* Done overlay */
        #done-overlay{display:none;position:fixed;inset:0;background:rgba(0,0,0,0.85);
          flex-direction:column;align-items:center;justify-content:center;gap:16px;z-index:100}
        #done-overlay.show{display:flex}
        #done-overlay .check{width:64px;height:64px;border-radius:50%;background:#22c55e;
          display:flex;align-items:center;justify-content:center;
          font-size:32px;color:#fff;animation:pop .4s ease}
        #done-overlay .label{font-size:28px;font-weight:700;animation:fadeUp .4s ease .1s both}
        #done-overlay .reset-btn{margin-top:12px;background:rgba(255,255,255,0.1);
          color:#fff;border:none;border-radius:10px;padding:10px 24px;
          font-size:14px;font-weight:600;cursor:pointer}
        @keyframes pop{0%{transform:scale(0);opacity:0}
          60%{transform:scale(1.15)}100%{transform:scale(1);opacity:1}}
        @keyframes fadeUp{0%{opacity:0;transform:translateY(8px)}
          100%{opacity:1;transform:translateY(0)}}

        @media(max-width:768px){
          #editor-container{padding:16px}
          #read-text,#edit-text{font-size:16px;line-height:1.6}
          #controls{padding:12px 16px}
          .ctrl-btn{padding:10px 20px;font-size:14px}
        }
        </style>
        </head>
        <body>

        <div id="status-bar">
          <div id="status-dot"></div>
          <div id="status-text">Connecting…</div>
          <div id="progress-text"></div>
        </div>

        <div id="editor-wrap">
          <div id="editor-container">
            <div id="read-text"></div>
            <div id="read-divider"></div>
            <div id="edit-text" contenteditable="true" data-placeholder="Type or paste your script here…" spellcheck="false"></div>
          </div>
        </div>

        <div id="controls">
          <button id="go-btn" class="ctrl-btn" onclick="toggleGo()">▶ Go</button>
          <div id="waveform"></div>
          <div id="mic-indicator">🎤</div>
        </div>

        <div id="done-overlay">
          <div class="check">✓</div>
          <div class="label">Done!</div>
          <button class="reset-btn" onclick="resetAll()">New Script</button>
        </div>

        <script>
        const WSP=\(wsPort),host=location.hostname,AUTH_TOKEN='\(authToken)';
        let ws,rt,isActive=false,isRunning=false,lastReadCount=0;

        /* ---- connection ---- */
        function connect(){
          ws=new WebSocket('ws://'+host+':'+WSP);
          ws.onopen=()=>{clearTimeout(rt);
            ws.send(JSON.stringify({type:'auth',text:AUTH_TOKEN}));
            document.getElementById('status-dot').className='connected';
            document.getElementById('status-text').textContent='Connected';};
          ws.onmessage=e=>{try{handleState(JSON.parse(e.data))}catch(x){console.error(x)}};
          ws.onclose=()=>{
            document.getElementById('status-dot').className='';
            document.getElementById('status-text').textContent='Reconnecting…';
            rt=setTimeout(connect,1500);};
          ws.onerror=()=>{ws.close()};
        }

        function send(obj){
          if(ws&&ws.readyState===1)ws.send(JSON.stringify(obj));
        }

        /* ---- state handler ---- */
        function handleState(s){
          const doneEl=document.getElementById('done-overlay');

          if(!s.isActive){
            isActive=false;
            isRunning=false;
            updateGoButton();
            document.getElementById('status-dot').className='connected';
            document.getElementById('progress-text').textContent='';
            return;
          }

          if(s.isDone){
            doneEl.classList.add('show');
            isRunning=false;
            updateGoButton();
            return;
          }
          doneEl.classList.remove('show');

          isActive=true;
          isRunning=true;
          updateGoButton();

          document.getElementById('status-dot').className='active';

          // Update progress
          const pct=s.totalCharCount>0?Math.round(s.highlightedCharCount/s.totalCharCount*100):0;
          document.getElementById('progress-text').textContent=pct+'%';

          // Update read boundary
          lastReadCount=s.highlightedCharCount;
          updateReadBoundary(s.highlightedCharCount);

          // Waveform
          const wf=document.getElementById('waveform'),
                lv=s.audioLevels||[];
          while(wf.children.length<lv.length){
            const b=document.createElement('div');b.className='wf';wf.appendChild(b)}
          for(let i=0;i<wf.children.length;i++){
            const l=i<lv.length?lv[i]:0;
            wf.children[i].style.height=Math.max(2,l*28)+'px';
            wf.children[i].style.background=l>0.05?'rgba(250,204,21,0.7)':'rgba(255,255,255,0.1)';
          }

          // Mic indicator
          document.getElementById('mic-indicator').className=s.isListening?'on':'';
        }

        /* ---- read boundary ---- */
        function getText(el){
          return (el.innerText||el.textContent||'').replace(/\\n/g,' ');
        }
        function getFullText(){
          const readEl=document.getElementById('read-text');
          const editEl=document.getElementById('edit-text');
          return getText(readEl)+getText(editEl);
        }

        function updateReadBoundary(charCount){
          if(charCount<=0)return;
          const fullText=getFullText();
          if(charCount>fullText.length)charCount=fullText.length;

          const readPart=fullText.substring(0,charCount);
          const editPart=fullText.substring(charCount);

          const readEl=document.getElementById('read-text');
          const editEl=document.getElementById('edit-text');
          const divider=document.getElementById('read-divider');

          readEl.textContent=readPart;
          divider.classList.toggle('visible',readPart.length>0);

          // Only update edit if content actually changed (preserve cursor)
          if(editEl.textContent!==editPart){
            editEl.textContent=editPart;
          }
        }

        /* ---- go/stop ---- */
        function toggleGo(){
          if(isRunning){
            send({type:'stop'});
            isRunning=false;
            updateGoButton();
          } else {
            const fullText=getFullText();
            if(!fullText.trim())return;
            send({type:'setText',text:fullText});
            isRunning=true;
            updateGoButton();
          }
        }

        function updateGoButton(){
          const btn=document.getElementById('go-btn');
          if(isRunning){
            btn.textContent='⏹ Stop';
            btn.classList.add('running');
          } else {
            btn.textContent='▶ Go';
            btn.classList.remove('running');
          }
        }

        /* ---- live edit ---- */
        let editDebounce=null;
        document.getElementById('edit-text').addEventListener('input',function(){
          if(!isRunning)return;
          clearTimeout(editDebounce);
          editDebounce=setTimeout(()=>{
            const fullText=getFullText();
            send({type:'updateText',text:fullText,readCharCount:lastReadCount});
          },300);
        });

        /* ---- reset ---- */
        function resetAll(){
          document.getElementById('done-overlay').classList.remove('show');
          document.getElementById('read-text').textContent='';
          document.getElementById('edit-text').textContent='';
          document.getElementById('read-divider').classList.remove('visible');
          document.getElementById('progress-text').textContent='';
          isRunning=false;
          isActive=false;
          lastReadCount=0;
          updateGoButton();
        }

        // Init waveform
        const wfInit=document.getElementById('waveform');
        for(let i=0;i<20;i++){const b=document.createElement('div');
          b.className='wf';b.style.height='2px';wfInit.appendChild(b)}

        connect();
        </script>
        </body>
        </html>
        """
    }
}
