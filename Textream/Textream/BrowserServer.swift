//
//  BrowserServer.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import Foundation
import Network

// MARK: - Browser Server

class BrowserServer {
    private var httpListener: NWListener?
    private var wsListener: NWListener?
    private var wsConnections: [NWConnection] = []
    private var broadcastTimer: Timer?

    // Content state
    private var words: [String] = []
    private var totalCharCount: Int = 0
    private var hasNextPage: Bool = false
    private weak var speechRecognizer: SpeechRecognizer?
    private weak var overlayContent: OverlayContent?
    private var timerWordProgress: Double = 0
    private var contentActive: Bool = false

    var httpPort: UInt16 { NotchSettings.shared.browserServerPort }
    var wsPort: UInt16 { httpPort + 1 }
    var isRunning: Bool { httpListener != nil }
    var connectedClients: Int { wsConnections.count }

    // MARK: - Lifecycle

    func start() {
        stop()
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
        contentActive = false
    }

    // MARK: - Content Management

    func showContent(speechRecognizer: SpeechRecognizer, content: OverlayContent) {
        self.speechRecognizer = speechRecognizer
        self.overlayContent = content
        self.words = content.words
        self.totalCharCount = content.totalCharCount
        self.hasNextPage = content.hasNextPage
        self.timerWordProgress = 0
        self.contentActive = true
        startBroadcasting()
    }

    func updateContent(words: [String], totalCharCount: Int, hasNextPage: Bool) {
        self.words = words
        self.totalCharCount = totalCharCount
        self.hasNextPage = hasNextPage
        self.timerWordProgress = 0
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
        let html = Self.generateHTML(wsPort: wsPort)
        let body = Data(html.utf8)
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
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
        conn.start(queue: .main)
        wsConnections.append(conn)
        receiveWSMessage(conn)

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.wsConnections.removeAll { $0 === conn }
            default: break
            }
        }
    }

    private func receiveWSMessage(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] _, _, _, error in
            if error != nil { conn.cancel(); return }
            self?.receiveWSMessage(conn)
        }
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

        let charCount: Int
        let mode = NotchSettings.shared.listeningMode
        switch mode {
        case .wordTracking:
            words = overlayContent?.words ?? words
            totalCharCount = overlayContent?.totalCharCount ?? totalCharCount
            hasNextPage = overlayContent?.hasNextPage ?? hasNextPage
            charCount = overlayContent?.highlightedCharCount ?? speechRecognizer?.recognizedCharCount ?? 0
        case .classic:
            timerWordProgress += NotchSettings.shared.scrollSpeed * 0.1
            charCount = charOffsetForWordProgress(timerWordProgress)
        case .silencePaused:
            if speechRecognizer?.isListening == true && (speechRecognizer?.isSpeaking ?? false) {
                timerWordProgress += NotchSettings.shared.scrollSpeed * 0.1
            }
            charCount = charOffsetForWordProgress(timerWordProgress)
        }

        let effective = min(charCount, totalCharCount)
        let isDone = totalCharCount > 0 && effective >= totalCharCount

        let highlightWords = mode == .wordTracking
        let trackingState = overlayContent?.trackingState.rawValue ?? speechRecognizer?.trackingState.rawValue ?? TrackingState.tracking.rawValue
        let confidenceLevel = overlayContent?.confidenceLevel.rawValue ?? speechRecognizer?.confidenceLevel.rawValue ?? TrackingConfidence.low.rawValue
        let expectedWord = overlayContent?.expectedWord ?? speechRecognizer?.expectedWord ?? ""
        let nextCue = overlayContent?.nextCue ?? speechRecognizer?.nextCue ?? ""
        let manualAsideActive = (overlayContent?.manualAsideMode.isActive ?? speechRecognizer?.manualAsideMode.isActive ?? false)

        let state = BrowserState(
            words: words,
            highlightedCharCount: effective,
            totalCharCount: totalCharCount,
            audioLevels: (speechRecognizer?.audioLevels ?? []).map { Double($0) },
            isListening: speechRecognizer?.isListening ?? false,
            isDone: isDone,
            fontColor: NotchSettings.shared.fontColorPreset.cssColor,
            cueColor: NotchSettings.shared.cueColorPreset.cssColor,
            hasNextPage: hasNextPage,
            isActive: true,
            highlightWords: highlightWords,
            lastSpokenText: speechRecognizer?.lastSpokenText ?? "",
            trackingState: trackingState,
            confidenceLevel: confidenceLevel,
            expectedWord: expectedWord,
            nextCue: nextCue,
            manualAsideActive: manualAsideActive
        )
        broadcast(state)
    }

    private func broadcastInactive() {
        let state = BrowserState(
            words: [], highlightedCharCount: 0, totalCharCount: 0,
            audioLevels: [], isListening: false, isDone: false,
            fontColor: "#ffffff", cueColor: "#ffffff", hasNextPage: false, isActive: false,
            highlightWords: true, lastSpokenText: "",
            trackingState: TrackingState.tracking.rawValue,
            confidenceLevel: TrackingConfidence.low.rawValue,
            expectedWord: "",
            nextCue: "",
            manualAsideActive: false
        )
        broadcast(state)
    }

    private func broadcast(_ state: BrowserState) {
        guard !wsConnections.isEmpty, let data = try? JSONEncoder().encode(state) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "ws", metadata: [meta])
        for conn in wsConnections {
            conn.send(content: data, contentContext: ctx, completion: .idempotent)
        }
    }

    // MARK: - Helpers

    private func charOffsetForWordProgress(_ progress: Double) -> Int {
        let wholeWord = Int(progress)
        let frac = progress - Double(wholeWord)
        var offset = 0
        for i in 0..<min(wholeWord, words.count) {
            offset += words[i].count + 1
        }
        if wholeWord < words.count {
            offset += Int(Double(words[wholeWord].count) * frac)
        }
        return min(offset, totalCharCount)
    }

    static func localIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var preferred: String?
        var fallback: String?

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let addr = ptr.pointee
            guard addr.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: addr.ifa_name)

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                addr.ifa_addr, socklen_t(addr.ifa_addr.pointee.sa_len),
                &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            let ip = String(cString: hostname)
            guard ip != "127.0.0.1" else { continue }

            if name == "en0" || name == "en1" {
                preferred = ip
            } else if fallback == nil {
                fallback = ip
            }
        }
        return preferred ?? fallback
    }

    // MARK: - HTML Template

    static func generateHTML(wsPort: UInt16) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
        <title>Textream</title>
        <style>
        *{margin:0;padding:0;box-sizing:border-box}
        html,body{height:100%;overflow:hidden;background:#000;color:#fff;
          font-family:-apple-system,BlinkMacSystemFont,'SF Pro Display','Helvetica Neue',system-ui,sans-serif}
        body{display:flex;flex-direction:column}

        /* Waiting */
        #waiting{flex:1;display:flex;flex-direction:column;align-items:center;
          justify-content:center;gap:16px}
        #waiting .icon{font-size:48px}
        #waiting .title{font-size:20px;font-weight:600;color:rgba(255,255,255,.6);
          animation:pulse 2s ease-in-out infinite}
        #waiting .sub{font-size:14px;color:rgba(255,255,255,.3);text-align:center;
          max-width:320px;line-height:1.5}
        #waiting .url{font-size:12px;color:rgba(255,255,255,.15);margin-top:8px;
          font-family:ui-monospace,monospace}
        @keyframes pulse{0%,100%{opacity:.6}50%{opacity:1}}

        /* Main */
        #main{display:none;flex-direction:column;height:100%}

        /* Prompter with fade mask */
        #prompter-wrap{flex:1;position:relative;overflow:hidden}
        #prompter-wrap::before,#prompter-wrap::after{
          content:'';position:absolute;left:0;right:0;z-index:2;pointer-events:none}
        #prompter-wrap::before{top:0;height:8%;
          background:linear-gradient(to bottom,#000,transparent)}
        #prompter-wrap::after{bottom:0;height:8%;
          background:linear-gradient(to top,#000,transparent)}
        #prompter{height:100%;overflow-y:auto;
          padding:20px max(40px,8%);
          -webkit-overflow-scrolling:touch;scroll-behavior:smooth}
        #prompter::-webkit-scrollbar{display:none}

        /* Text: match ExternalDisplayView font sizing: max(48, min(96, width/14)) */
        #text-container{
          font-size:clamp(48px,calc(100vw / 14),96px);
          font-weight:600;line-height:1.4;word-wrap:break-word}
        .w{display:inline;transition:color .12s ease}
        .w.ann{font-style:italic}

        /* Bottom bar — matches ExternalDisplayView layout */
        #bar{flex-shrink:0;padding:12px max(40px,8%) 40px;
          display:flex;align-items:center;gap:16px}
        #waveform{width:240px;height:32px;display:flex;align-items:center;gap:1.5px}
        .wf{width:3px;background:rgba(255,255,255,.15);border-radius:1.5px;
          min-height:3px;transition:height .08s ease,background .12s ease;align-self:center}
        #spoken{font-size:18px;font-weight:500;color:rgba(255,255,255,.5);
          flex:1;overflow:hidden;white-space:nowrap;text-overflow:ellipsis;
          direction:rtl;text-align:left}
        #mic-btn{width:40px;height:40px;border-radius:50%;
          background:rgba(255,255,255,.15);display:flex;align-items:center;
          justify-content:center;flex-shrink:0}
        #mic-dot{width:10px;height:10px;border-radius:50%;
          background:#facc15;opacity:0;transition:opacity .2s}
        #mic-dot.on{opacity:1}

        /* Done */
        #done{display:none;flex-direction:column;align-items:center;
          justify-content:center;height:100%;gap:12px}
        #done .check{width:64px;height:64px;border-radius:50%;background:#22c55e;
          display:flex;align-items:center;justify-content:center;
          font-size:32px;color:#fff;animation:pop .4s ease}
        #done .label{font-size:32px;font-weight:700;color:#fff;
          animation:fadeUp .4s ease .1s both}
        @keyframes pop{0%{transform:scale(0);opacity:0}
          60%{transform:scale(1.15)}100%{transform:scale(1);opacity:1}}
        @keyframes fadeUp{0%{opacity:0;transform:translateY(8px)}
          100%{opacity:1;transform:translateY(0)}}

        @media(max-width:768px){
          #prompter{padding:16px 5%}
          #bar{padding:10px 5% 20px}
          #waveform{width:160px;height:28px}
          #text-container{font-size:clamp(28px,calc(100vw / 10),60px)}
        }
        </style>
        </head>
        <body>

        <div id="waiting">
          <div class="icon">📡</div>
          <div class="title">Waiting for Textream…</div>
          <div class="sub">Start reading in the app to see your teleprompter here</div>
          <div class="url" id="conn-status">Connecting…</div>
        </div>

        <div id="main">
          <div id="prompter-wrap">
            <div id="prompter"><div id="text-container"></div></div>
          </div>
          <div id="bar">
            <div id="waveform"></div>
            <div id="spoken"></div>
            <div id="mic-btn"><div id="mic-dot"></div></div>
          </div>
        </div>

        <div id="done">
          <div class="check">✓</div>
          <div class="label">Done!</div>
        </div>

        <script>
        const WSP=\(wsPort),host=location.hostname;
        let ws,rt,prevWordKey='',scrollTgt=null;

        /* ---- helpers ---- */

        // Parse a CSS color into [r,g,b]
        function parseColor(c){
          if(c.startsWith('#')){
            const v=c.length===4
              ?[c[1]+c[1],c[2]+c[2],c[3]+c[3]]
              :[c.slice(1,3),c.slice(3,5),c.slice(5,7)];
            return v.map(h=>parseInt(h,16));
          }
          const m=c.match(/(\\d+)/g);
          return m?m.slice(0,3).map(Number):[255,255,255];
        }
        function rgba(rgb,a){return 'rgba('+rgb[0]+','+rgb[1]+','+rgb[2]+','+a+')';}

        // Detect visually-styled annotation words. Bracket cues still participate
        // in tracking as long as they contain matchable letters or digits.
        function isAnnotation(w){
          if(w.startsWith('[')&&w.endsWith(']'))return true;
          return!/[a-zA-Z0-9\\u00C0-\\u024F\\u0400-\\u04FF\\u3000-\\u9FFF\\uAC00-\\uD7AF]/.test(w);
        }

        function trackingTokenCount(w){
          const m=w.match(/[a-zA-Z0-9\\u00C0-\\u024F\\u0400-\\u04FF\\u3000-\\u9FFF\\uAC00-\\uD7AF]/g);
          return m?m.length:0;
        }

        // Count letters+digits in a word
        function letterCount(w){
          return Math.max(1,trackingTokenCount(w));
        }

        /* ---- connection ---- */

        function connect(){
          ws=new WebSocket('ws://'+host+':'+WSP);
          ws.onopen=()=>{clearTimeout(rt);
            document.getElementById('conn-status').textContent='Connected';};
          ws.onmessage=e=>{try{render(JSON.parse(e.data))}catch(x){console.error(x)}};
          ws.onclose=()=>{
            document.getElementById('conn-status').textContent='Reconnecting…';
            rt=setTimeout(connect,1500);};
          ws.onerror=()=>{ws.close()};
        }

        /* ---- render ---- */

        function render(s){
          const wEl=document.getElementById('waiting'),
                mEl=document.getElementById('main'),
                dEl=document.getElementById('done');

          if(!s.isActive){wEl.style.display='flex';mEl.style.display='none';
            dEl.style.display='none';return}
          if(s.isDone){wEl.style.display='none';mEl.style.display='none';
            dEl.style.display='flex';return}
          wEl.style.display='none';mEl.style.display='flex';dEl.style.display='none';

          const c=document.getElementById('text-container'),
                words=s.words||[],
                fc=s.fontColor||'#ffffff',
                cc=s.cueColor||fc,
                rgb=parseColor(fc),
                crgb=parseColor(cc),
                hlWords=s.highlightWords!==false,
                hcc=s.highlightedCharCount||0;

          // Rebuild spans only when words change
          const wordKey=words.length+'|'+(words[0]||'')+'|'+(words[words.length-1]||'');
          if(wordKey!==prevWordKey){
            c.innerHTML='';
            let cp=0;
            for(let i=0;i<words.length;i++){
              const wd=words[i],ann=isAnnotation(wd),trackable=trackingTokenCount(wd)>0;
              const sp=document.createElement('span');
              sp.className=ann?'w ann':'w';
              sp.dataset.s=cp;
              sp.dataset.l=wd.length;
              sp.dataset.lc=letterCount(wd);
              sp.dataset.a=ann?'1':'0';
              sp.dataset.t=trackable?'1':'0';
              sp.textContent=wd+' ';
              c.appendChild(sp);
              cp+=wd.length+1;
            }
            prevWordKey=wordKey;
          }

          // Find the next-word index. Bracket cues remain trackable, while
          // emoji-only / punctuation-only tokens are skipped.
          let nextIdx=-1;
          if(hlWords){
            const spans=c.children;
            for(let i=0;i<spans.length;i++){
              const d=spans[i].dataset;
              if(d.t!=='1')continue;
              const charOff=parseInt(d.s),wLen=parseInt(d.l),lc=parseInt(d.lc);
              const litCount=Math.max(0,Math.min(wLen,hcc-charOff));
              if(litCount<lc){nextIdx=i;break}
            }
          }

          // Color each word to match native WordFlowLayout
          scrollTgt=null;
          const spans=c.children;
          for(let i=0;i<spans.length;i++){
            const sp=spans[i],d=sp.dataset;
            const charOff=parseInt(d.s),wLen=parseInt(d.l),lc=parseInt(d.lc);
            const ann=d.a==='1',trackable=d.t==='1';
            const litCount=Math.max(0,Math.min(wLen,hcc-charOff));
            const isFullyLit=litCount>=lc;
            const charsInto=hcc-charOff;
            const isCurrent=trackable&&((i===nextIdx)||(charsInto>=0&&!isFullyLit));

            let color,underline=false;

            if(!hlWords){
              // Classic / silence-paused: uniform color, no per-word highlight
              color=ann?rgba(crgb,0.4):fc;
            } else if(ann){
              // Annotation: cue color with varying opacity
              color=isFullyLit?rgba(crgb,0.5):(isCurrent?rgba(crgb,0.72):rgba(crgb,0.2));
              underline=isCurrent;
            } else if(isFullyLit){
              // Already read: dimmed
              color=rgba(rgb,0.3);
            } else if(isCurrent){
              // Current / next word: medium + underline
              color=rgba(rgb,0.6);
              underline=true;
            } else {
              // Unread: full brightness
              color=fc;
            }

            sp.style.color=color;
            sp.style.textDecoration=underline?'underline':'none';
            sp.style.textDecorationColor=underline?color:'';
            sp.style.textUnderlineOffset=underline?'4px':'';

            // Track the active word for scrolling
            if(isCurrent||(!scrollTgt&&isFullyLit)){
              scrollTgt=sp;
            }
          }

          // Auto-scroll: keep active word centered
          if(scrollTgt){
            const p=document.getElementById('prompter'),
                  r=scrollTgt.getBoundingClientRect(),
                  pr=p.getBoundingClientRect(),
                  mid=pr.top+pr.height*0.4;
            if(r.top>mid+40||r.bottom<pr.top)
              scrollTgt.scrollIntoView({behavior:'smooth',block:'center'});
          }

          // Waveform with progress coloring (matches native AudioWaveformProgressView)
          const wf=document.getElementById('waveform'),
                lv=s.audioLevels||[],
                pct=s.totalCharCount>0?s.highlightedCharCount/s.totalCharCount:0;
          while(wf.children.length<lv.length){
            const b=document.createElement('div');b.className='wf';wf.appendChild(b)}
          const barCount=wf.children.length;
          for(let i=0;i<barCount;i++){
            const l=i<lv.length?lv[i]:0;
            const barProgress=barCount>1?i/(barCount-1):0;
            const isLit=barProgress<=pct;
            wf.children[i].style.height=Math.max(3,l*32)+'px';
            wf.children[i].style.background=isLit
              ?'rgba(250,204,21,0.9)':'rgba(255,255,255,0.15)';
          }

          // Last spoken text (word-tracking mode only)
          const spokenEl=document.getElementById('spoken');
          if(hlWords&&s.lastSpokenText){
            const tail=s.lastSpokenText.split(' ').slice(-5).join(' ');
            spokenEl.textContent=tail;
          } else {
            spokenEl.textContent='';
          }

          // Mic indicator
          document.getElementById('mic-dot').classList.toggle('on',!!s.isListening);
        }

        // Init waveform bars
        const wfInit=document.getElementById('waveform');
        for(let i=0;i<30;i++){const b=document.createElement('div');
          b.className='wf';b.style.height='2px';wfInit.appendChild(b)}

        connect();
        </script>
        </body>
        </html>
        """
    }
}
