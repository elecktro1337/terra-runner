import readline from 'node:readline';

export function footerRows(controls) {
  return [`  ${controls}`];
}

export function liveStatusRows(status, detail = '') {
  return [`  ${status}`, `  ${detail || 'Waiting for runner events…'}`];
}

class FixedRows {
  constructor(stream, row = 0, minimumRows = 1) {
    this.stream = stream;
    this.row = row;
    this.minimumRows = minimumRows;
    this.enabled = this.isUsable();
    this.visible = false;
    this.lastRow = -1;
    this.lastCount = 0;
  }

  isUsable() { return Boolean(this.stream?.isTTY && Number(this.stream.rows) >= this.minimumRows); }

  clearRowsAt(row, count) {
    const terminalRows = Number(this.stream?.rows || 0);
    if (row < 0 || row >= terminalRows) return;
    for (let index = 0; index < count && row + index < terminalRows; index++) {
      readline.cursorTo(this.stream, 0, row + index);
      readline.clearLine(this.stream, 0);
    }
  }

  clear() {
    if (!this.visible) return;
    this.clearRowsAt(this.lastRow, this.lastCount);
    this.visible = false;
    this.lastRow = -1;
    this.lastCount = 0;
  }

  renderRows(rows, row) {
    if (!this.isUsable()) { this.clear(); this.enabled = false; return false; }
    this.enabled = true;
    const normalized = rows.map(value => String(value));
    const moved = this.visible && (this.lastRow !== row || this.lastCount !== normalized.length);
    if (moved) this.clearRowsAt(this.lastRow, this.lastCount);
    for (let index = 0; index < normalized.length; index++) {
      readline.cursorTo(this.stream, 0, row + index);
      readline.clearLine(this.stream, 0);
      this.stream.write(normalized[index]);
    }
    this.visible = true;
    this.lastRow = row;
    this.lastCount = normalized.length;
    return true;
  }
}

export class LiveFooter extends FixedRows {
  constructor(stream, controls) {
    super(stream, 0, 2);
    this.controls = controls;
  }

  render() {
    const rows = footerRows(this.controls);
    const row = Math.max(0, Number(this.stream?.rows || 0) - rows.length);
    return this.renderRows(rows, row);
  }
}

export class LiveStatusBlock extends FixedRows {
  constructor(stream, row) {
    super(stream, row, Number(row) + 3);
  }

  render(status, detail = '') {
    return this.renderRows(liveStatusRows(status, detail), this.row);
  }
}
