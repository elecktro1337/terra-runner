import readline from 'node:readline';

export function footerRows(status, controls) {
  return [`  ${status}`, `  ${controls}`];
}

export class LiveFooter {
  constructor(stream, controls) {
    this.stream = stream;
    this.controls = controls;
    this.enabled = this.isUsable();
    this.visible = false;
  }

  isUsable() { return Boolean(this.stream?.isTTY && Number(this.stream.rows) >= 4); }

  render(status) {
    if (!this.isUsable()) { this.clear(); this.enabled = false; return; }
    this.enabled = true;
    const rows = footerRows(status, this.controls);
    const bottom = Math.max(0, Number(this.stream.rows || 0) - 2);
    readline.cursorTo(this.stream, 0, bottom);
    readline.clearLine(this.stream, 0); this.stream.write(rows[0]);
    readline.cursorTo(this.stream, 0, bottom + 1);
    readline.clearLine(this.stream, 0); this.stream.write(rows[1]);
    this.visible = true;
  }

  clear() {
    if (!this.enabled || !this.visible) return;
    const bottom = Math.max(0, Number(this.stream.rows || 0) - 2);
    readline.cursorTo(this.stream, 0, bottom); readline.clearLine(this.stream, 0);
    readline.cursorTo(this.stream, 0, bottom + 1); readline.clearLine(this.stream, 0);
    this.visible = false;
  }

  persist(text) {
    if (!this.enabled) { this.stream.write(`\n${text}\n`); return; }
    this.clear();
    this.stream.write(`\n${text}\n`);
  }
}
