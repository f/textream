// Color runs are the only document data; DOM spans are an editing representation.
let lockedRuns = [], savedEditorRange = null, typingColor = null, palette = [];
const editor = document.getElementById('edit-text');

function normalizeColor(value) {
  if (/^#[0-9a-f]{6}$/i.test(value || '')) return value.toLowerCase();
  const channels = (value || '').match(/[\d.]+/g);
  if (!channels || channels.length < 3) return '#ffffff';
  return '#' + channels.slice(0, 3).map(v => Math.max(0, Math.min(255, Math.round(Number(v)))).toString(16).padStart(2, '0')).join('');
}
function mergeRuns(runs) {
  const result = [];
  for (const run of runs) {
    if (!run.text) continue;
    const color = normalizeColor(run.color), last = result[result.length - 1];
    if (last && last.color === color) last.text += run.text;
    else result.push({text: run.text, color});
  }
  return result;
}
function normalizeDirectorRuns(runs) {
  const result = [];
  let separator = '', separatorColor = '#ffffff';
  function append(text, color) { result.push({text, color}); }
  for (const run of mergeRuns(runs)) {
    for (const char of run.text) {
      if (/\p{White_Space}/u.test(char)) {
        if (!separator) separatorColor = run.color;
        separator = char === '\r' || char === '\n' ? '\n' : separator || ' ';
      } else {
        if (result.length && separator) append(separator, separatorColor);
        separator = '';
        append(char, run.color);
      }
    }
  }
  return mergeRuns(result);
}
function plain(runs) { return runs.map(r => r.text).join(''); }
function splitRunsAt(runs, offset) {
  const left = [], right = [];
  for (const run of runs) {
    const cut = Math.min(run.text.length, Math.max(0, offset));
    left.push({text: run.text.slice(0, cut), color: run.color});
    right.push({text: run.text.slice(cut), color: run.color});
    offset -= cut;
  }
  return [mergeRuns(left), mergeRuns(right)];
}
function extractRuns(root, inheritedColor = '#ffffff') {
  const result = [];
  function visit(node, color) {
    if (node.nodeType === Node.TEXT_NODE) {
      result.push({text: node.nodeValue, color});
      return;
    }
    if (node.nodeType !== Node.ELEMENT_NODE && node.nodeType !== Node.DOCUMENT_FRAGMENT_NODE) return;
    if (node.tagName === 'BR') { result.push({text: '\n', color}); return; }
    if (node.nodeType === Node.ELEMENT_NODE) {
      color = normalizeColor(node.style.color || node.getAttribute('color') || getComputedStyle(node).color || color);
    }
    const block = /^(DIV|P|LI|H[1-6]|BLOCKQUOTE|PRE)$/.test(node.tagName || '');
    if (block && result.length && !plain(result).endsWith('\n')) result.push({text: '\n', color});
    for (const child of node.childNodes) visit(child, color);
    if (block && result.length && !plain(result).endsWith('\n')) result.push({text: '\n', color});
  }
  for (const child of root.childNodes) visit(child, inheritedColor);
  return mergeRuns(result);
}
function fullRuns() { return normalizeDirectorRuns([...lockedRuns, ...extractRuns(editor)]); }
function refreshDefaultTextColors(element) {
  for (const node of element.childNodes) {
    if (node.nodeType !== Node.ELEMENT_NODE) continue;
    const sourceColor = node.style.color || node.getAttribute('color');
    const color = sourceColor ? normalizeColor(sourceColor) : null;
    // Keep the original inline color for extraction, saving, and read-prefix checks.
    node.classList.toggle('default-text-color', color === '#000000' || color === '#ffffff');
    refreshDefaultTextColors(node);
  }
}
function renderRuns(element, runs) {
  const fragment = document.createDocumentFragment();
  for (const run of runs) {
    const span = document.createElement('span');
    span.style.color = run.color;
    span.textContent = run.text;
    fragment.appendChild(span);
  }
  element.replaceChildren(fragment);
  refreshDefaultTextColors(element);
}
function editorRange() {
  const selection = window.getSelection();
  if (!selection || !selection.rangeCount) return null;
  const range = selection.getRangeAt(0);
  return editor.contains(range.startContainer) && editor.contains(range.endContainer) ? range : null;
}
function selectionOffsets() {
  const range = editorRange();
  if (!range) return null;
  function offset(node, index) {
    const path = [];
    for (let current = node; current !== editor; current = current.parentNode) {
      path.unshift(Array.prototype.indexOf.call(current.parentNode.childNodes, current));
    }
    const clone = editor.cloneNode(true);
    const endpoint = path.reduce((parent, childIndex) => parent.childNodes[childIndex], clone);
    let marker = '\u0001';
    while ((plain(lockedRuns) + editor.textContent).includes(marker)) marker += '\u0001';
    const caret = document.createRange();
    caret.setStart(endpoint, index);
    caret.collapse(true);
    caret.insertNode(document.createTextNode(marker));
    // Put the marker inside the partial paragraph, before its synthetic closing newline.
    const text = plain(normalizeDirectorRuns([...lockedRuns, ...extractRuns(clone)]));
    return text.indexOf(marker) - plain(lockedRuns).length;
  }
  return [offset(range.startContainer, range.startOffset), offset(range.endContainer, range.endOffset)];
}
function restoreOffsets(offsets) {
  if (!offsets) return;
  function position(offset) {
    const walker = document.createTreeWalker(editor, NodeFilter.SHOW_TEXT);
    let node, last = null;
    while ((node = walker.nextNode())) {
      last = node;
      if (offset <= node.length) return [node, Math.max(0, offset)];
      offset -= node.length;
    }
    return last ? [last, last.length] : [editor, 0];
  }
  const range = document.createRange(), start = position(offsets[0]), end = position(offsets[1]);
  range.setStart(...start); range.setEnd(...end);
  const selection = window.getSelection();
  selection.removeAllRanges(); selection.addRange(range);
  savedEditorRange = range.cloneRange();
}
function updateFormattedBoundary(utf16Count) {
  const oldCount = plain(lockedRuns).length;
  if (utf16Count === oldCount) return;
  // Keep an unfinished trailing space while moving the read boundary through a live edit.
  const withSentinel = normalizeDirectorRuns([...lockedRuns, ...extractRuns(editor), {text: '\u0001', color: '#ffffff'}]);
  const runs = splitRunsAt(withSentinel, plain(withSentinel).length - 1)[0];
  const count = Math.min(plain(runs).length, Math.max(0, utf16Count));
  const [read, unread] = splitRunsAt(runs, count), offsets = selectionOffsets();
  const currentUnread = extractRuns(editor);
  const changed = JSON.stringify(mergeRuns(currentUnread)) !== JSON.stringify(unread);
  lockedRuns = read;
  lockedReadText = plain(read);
  renderRuns(document.getElementById('read-text'), read);
  document.getElementById('read-divider').classList.toggle('visible', count > 0);
  if (changed) {
    renderRuns(editor, unread);
    restoreOffsets(offsets && offsets.map(offset => Math.max(0, offset + oldCount - count)));
    if (typingColor && editorRange()?.collapsed) document.execCommand('foreColor', false, typingColor);
  }
}
function sendFormatted(type) {
  const runs = fullRuns(), payload = {type, text: plain(runs), formattedRuns: runs};
  if (type === 'updateText') payload.readCharCount = lastReadCount;
  send(payload);
}
function scheduleFormattedUpdate() {
  if (!isRunning) return;
  clearTimeout(editDebounce);
  editDebounce = setTimeout(() => sendFormatted('updateText'), 300);
}
function selectedColor() {
  const range = editorRange();
  if (!range) return typingColor;
  if (range.collapsed) {
    if (typingColor) return typingColor;
    return normalizeColor(document.queryCommandValue('foreColor'));
  }
  const node = range.startContainer.nodeType === Node.TEXT_NODE ? range.startContainer.parentElement : range.startContainer;
  const colors = new Set(extractRuns(range.cloneContents(), normalizeColor(getComputedStyle(node).color)).map(r => r.color));
  return colors.size === 1 ? [...colors][0] : null;
}
function updateDots() {
  const color = selectedColor();
  document.querySelectorAll('.color-dot').forEach(dot => {
    const selected = dot.dataset.color === color;
    dot.classList.toggle('selected', selected);
    dot.setAttribute('aria-pressed', String(selected));
  });
}
function applyDirectorColor(color) {
  editor.focus();
  if (savedEditorRange && editor.contains(savedEditorRange.startContainer) && editor.contains(savedEditorRange.endContainer)) {
    const selection = window.getSelection();
    selection.removeAllRanges(); selection.addRange(savedEditorRange);
  }
  if (!editorRange()) restoreOffsets([plain(extractRuns(editor)).length, plain(extractRuns(editor)).length]);
  typingColor = color;
  document.execCommand('styleWithCSS', false, true);
  document.execCommand('foreColor', false, color);
  refreshDefaultTextColors(editor);
  savedEditorRange = editorRange()?.cloneRange() || null;
  updateDots();
  scheduleFormattedUpdate();
}
function syncPalette(colors) {
  const next = (Array.isArray(colors) && colors.length ? colors : ['#ffffff']).slice(0, 9).map(normalizeColor);
  if (JSON.stringify(next) === JSON.stringify(palette)) return;
  palette = next;
  const container = document.getElementById('color-palette');
  container.replaceChildren();
  container.hidden = palette.length <= 1;
  for (const color of palette) {
    const button = document.createElement('button');
    button.className = 'color-dot'; button.type = 'button'; button.dataset.color = color;
    button.style.backgroundColor = color;
    button.setAttribute('aria-label', 'Text color ' + color);
    button.addEventListener('mousedown', event => event.preventDefault());
    button.addEventListener('click', () => applyDirectorColor(color));
    container.appendChild(button);
  }
  updateDots();
}
editor.addEventListener('pointerdown', () => { typingColor = null; });
editor.addEventListener('keydown', event => {
  if (['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', 'Home', 'End'].includes(event.key)) typingColor = null;
});
editor.addEventListener('beforeinput', event => {
  if (typingColor && event.inputType.startsWith('insert') && !event.isComposing) {
    document.execCommand('styleWithCSS', false, true);
    document.execCommand('foreColor', false, typingColor);
  }
});
document.addEventListener('selectionchange', () => {
  const range = editorRange();
  if (range) savedEditorRange = range.cloneRange();
  updateDots();
});
editor.addEventListener('input', () => { refreshDefaultTextColors(editor); updateDots(); scheduleFormattedUpdate(); });
