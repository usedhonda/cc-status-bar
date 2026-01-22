# CC Status Bar - Stream Deck Plugin

Control your Claude Code sessions from Stream Deck.

## Layout

For a 15-button Stream Deck:

```
┌─────┬─────┬─────┬─────┬─────┐
│  1  │  2  │  3  │  4  │  5  │  ← Sessions 1-5
├─────┼─────┼─────┼─────┼─────┤
│  6  │  7  │  8  │  9  │ 10  │  ← Sessions 6-10
├─────┼─────┼─────┼─────┼─────┤
│  ▲  │  ▼  │  🎤  │  ⏎  │     │  ← Controls
└─────┴─────┴─────┴─────┴─────┘
```

## Features

### Session Buttons (1-10)

- **Green**: Running session
- **Yellow**: Waiting for input (stop/unknown)
- **Red**: Permission prompt required
- **Gray**: Stopped

Click to focus the session in your terminal.

### Control Buttons

- **▲ Scroll Up**: Navigate to previous 10 sessions
- **▼ Scroll Down**: Navigate to next 10 sessions
- **🎤 Dictation**: Toggle Mac dictation (Fn Fn)
- **⏎ Enter**: Send Enter key to focused application

## Installation

### Prerequisites

1. CC Status Bar app installed and running
2. Stream Deck software installed
3. Node.js installed

### Install Plugin

```bash
cd StreamDeckPlugin/cc-status-bar.sdPlugin

# Install dependencies
npm install

# Link plugin to Stream Deck
npm run install-plugin
# or manually:
# streamdeck link .
```

### Restart Stream Deck

Restart the Stream Deck software to load the plugin.

## Development

### Build from TypeScript

```bash
npm run build
```

### Development workflow

```bash
npm run dev  # Build and install plugin
```

## Requirements

- macOS 10.15+
- Stream Deck software 6.0+
- CC Status Bar app running
- Node.js (for plugin execution)
