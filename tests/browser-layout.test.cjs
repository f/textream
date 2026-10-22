const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = process.argv[2] || path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'Textream/Textream/BrowserServer.swift'), 'utf8');
const match = source.match(/<script>([\s\S]*?)<\/script>/);
assert.ok(match, 'embedded remote script not found');
// Decode the Swift string's backslashes and supply the interpolated test port.
const script = match[1].replace(/\\\(wsPort\)/g, '7374').replace(/\\\\/g, '\\');
assert.ok(!script.includes('\\('), 'unexpected Swift interpolation in remote script');

class Element {
    constructor() {
        this.children = [];
        this.dataset = {};
        this.style = {};
        this.classList = { toggle() {} };
        this.textContent = '';
    }
    set innerHTML(value) { assert.equal(value, ''); this.children = []; }
    appendChild(child) { this.children.push(child); }
    setAttribute() {}
    addEventListener() {}
    getBoundingClientRect() { return { top: 0, bottom: 20, height: 200 }; }
    scrollIntoView() {}
}
const elements = new Map();
const context = vm.createContext({
    document: {
        body: new Element(),
        getElementById(id) {
            if (!elements.has(id)) elements.set(id, new Element());
            return elements.get(id);
        },
        createElement() { return new Element(); }
    },
    location: { hostname: 'localhost', search: '' },
    localStorage: { getItem() { return null; }, setItem() {} },
    URLSearchParams,
    WebSocket: class {},
    setTimeout() {}, clearTimeout() {}, console
});
vm.runInContext(script, context, { filename: 'remote-prompter.js' });
const render = (words, extra = {}) => context.render({
    isActive: true, isDone: false, words, highlightedCharCount: 0,
    totalCharCount: words.join(' ').length, ...extra
});
render(['中', '旧', '文']);
const container = elements.get('text-container');
const text = () => container.children.map(child => child.textContent).join('');
assert.equal(text(), '中 旧 文 ');
const oldMiddle = container.children[1];
render(['中', '新', '文']);
assert.equal(text(), '中 新 文 ', 'same-length middle edit must rebuild spans');
assert.notEqual(container.children[1], oldMiddle);
const unchangedMiddle = container.children[1];
render(['中', '新', '文'], { highlightedCharCount: 2 });
assert.equal(container.children[1], unchangedMiddle, 'highlight updates should reuse spans');
render(['中', '2026', '文']);
assert.equal(text(), '中 2026 文 ');
assert.equal(container.children[2].dataset.s, 7, 'offset must reflect changed word length');
render(['中', '2026', '文'], { isActive: false });
render(['中', '1234', '文']);
assert.equal(text(), '中 1234 文 ', 'resuming must display the new script');
render([]);
assert.equal(container.children.length, 0, 'cleared script must remove old spans');
console.log('Remote span updates, offsets, highlight reuse, resume, and clear: passed');
