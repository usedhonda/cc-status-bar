/**
 * CC Status Bar - Stream Deck Plugin (TypeScript Source)
 *
 * This is the TypeScript source file for the plugin.
 * Compile with: tsc src/plugin.ts --outDir bin --target ES2020 --module CommonJS
 */

import WebSocket from 'ws';
import { execSync, exec } from 'child_process';
import { appendFileSync } from 'fs';
import path from 'path';

// Debug log to file
import { mkdirSync } from 'fs';
const LOG_DIR = path.join(process.env.HOME || '', 'Library/Logs/CCStatusBar');
const LOG_FILE = path.join(LOG_DIR, 'streamdeck-plugin.log');
try { mkdirSync(LOG_DIR, { recursive: true }); } catch {}
function debugLog(msg: string): void {
    try {
        appendFileSync(LOG_FILE, `${new Date().toISOString()} ${msg}\n`);
    } catch (e) {
        console.error('Log error:', e);
    }
}

// Stream Deck SDK events
const Events = {
    DID_RECEIVE_SETTINGS: 'didReceiveSettings',
    DID_RECEIVE_GLOBAL_SETTINGS: 'didReceiveGlobalSettings',
    KEY_DOWN: 'keyDown',
    KEY_UP: 'keyUp',
    WILL_APPEAR: 'willAppear',
    WILL_DISAPPEAR: 'willDisappear',
    TITLE_PARAMETERS_DID_CHANGE: 'titleParametersDidChange',
    DEVICE_DID_CONNECT: 'deviceDidConnect',
    DEVICE_DID_DISCONNECT: 'deviceDidDisconnect',
    APPLICATION_DID_LAUNCH: 'applicationDidLaunch',
    APPLICATION_DID_TERMINATE: 'applicationDidTerminate',
    SYSTEM_DID_WAKE_UP: 'systemDidWakeUp',
    PROPERTY_INSPECTOR_DID_APPEAR: 'propertyInspectorDidAppear',
    PROPERTY_INSPECTOR_DID_DISAPPEAR: 'propertyInspectorDidDisappear',
    SEND_TO_PLUGIN: 'sendToPlugin'
} as const;

// Action UUIDs
const Actions = {
    SESSION: 'com.ccstatusbar.session',
    SCROLL_UP: 'com.ccstatusbar.scroll-up',
    SCROLL_DOWN: 'com.ccstatusbar.scroll-down',
    DICTATION: 'com.ccstatusbar.dictation',
    ENTER: 'com.ccstatusbar.enter',
    ESCAPE: 'com.ccstatusbar.escape',
    SHIFT_TAB: 'com.ccstatusbar.shift-tab',
    FOCUS_WAITING: 'com.ccstatusbar.focus-waiting'
} as const;

// Device type to columns mapping
const DeviceColumns: Record<number, number> = {
    0: 5,  // Standard (15 buttons, 3x5)
    1: 3,  // Mini (6 buttons, 2x3)
    2: 8,  // XL (32 buttons, 4x8)
    7: 4,  // Plus (8 buttons + touch, 2x4)
    9: 4   // Neo (8 buttons + touch, 2x4)
};

// Device info storage
interface DeviceInfo {
    type: number;
    columns: number;
    rows: number;
}
const devices = new Map<string, DeviceInfo>();

// Types
interface Session {
    id: string;
    project: string;
    status: 'running' | 'waiting_input' | 'stopped';
    path: string;
    waiting_reason?: 'permission_prompt' | 'stop' | 'unknown';
    is_acknowledged?: boolean;
    environment?: string;   // "Ghostty", "iTerm2/tmux", "VS Code", etc.
    icon_base64?: string;   // Base64 PNG data for terminal/editor icon
}

interface SessionListResponse {
    sessions: Session[];
    offset: number;
    total: number;
}

interface ButtonInfo {
    row: number;
    col: number;
    buttonIndex: number;
    deviceId?: string;
    sessionNumber?: string; // "auto" or "1"-"10"
}

interface StreamDeckMessage {
    event: string;
    action?: string;
    context?: string;
    device?: string;
    deviceInfo?: {
        type: number;
        size: {
            columns: number;
            rows: number;
        };
    };
    payload?: {
        coordinates?: {
            row: number;
            column: number;
        };
        settings?: {
            sessionNumber?: string;
            [key: string]: unknown;
        };
    };
}

// Plugin state
let websocket: WebSocket | null = null;
let pluginUUID: string | null = null;
const sessionButtons = new Map<string, ButtonInfo>();
let currentOffset = 0;
let totalSessions = 0;
let sessions: Session[] = [];
let pollInterval: NodeJS.Timeout | null = null;

// CCStatusBar CLI path
const CLI_PATH = path.join(
    process.env.HOME || '',
    'Library/Application Support/CCStatusBar/bin/CCStatusBar'
);

/**
 * Connect to Stream Deck
 */
function connectElgatoStreamDeckSocket(
    port: string,
    uuid: string,
    registerEvent: string,
    _info: string
): void {
    pluginUUID = uuid;

    websocket = new WebSocket(`ws://127.0.0.1:${port}`);

    websocket.on('open', () => {
        debugLog('WebSocket connected');
        send({ event: registerEvent, uuid });
        startPolling();
    });

    websocket.on('message', (data: WebSocket.Data) => {
        const message = JSON.parse(data.toString()) as StreamDeckMessage;
        handleMessage(message);
    });

    websocket.on('error', (error: Error) => {
        console.error('WebSocket error:', error);
    });

    websocket.on('close', () => {
        stopPolling();
    });
}

/**
 * Send message to Stream Deck
 */
function send(payload: Record<string, unknown>): void {
    if (websocket && websocket.readyState === WebSocket.OPEN) {
        websocket.send(JSON.stringify(payload));
    }
}

/**
 * Handle incoming messages from Stream Deck
 */
function handleMessage(data: StreamDeckMessage): void {
    debugLog(`handleMessage: event=${data.event}, action=${data.action || 'none'}`);
    const { event, action, context, device, deviceInfo, payload } = data;

    switch (event) {
        case Events.DEVICE_DID_CONNECT:
            if (device && deviceInfo) {
                handleDeviceDidConnect(device, deviceInfo);
            }
            break;

        case Events.WILL_APPEAR:
            if (action && context && payload) {
                handleWillAppear(action, context, payload, device);
            }
            break;

        case Events.WILL_DISAPPEAR:
            if (action && context) {
                handleWillDisappear(action, context);
            }
            break;

        case Events.KEY_DOWN:
            if (action && context) {
                handleKeyDown(action, context);
            }
            break;

        case Events.DID_RECEIVE_SETTINGS:
            if (action && context && payload) {
                handleDidReceiveSettings(action, context, payload);
            }
            break;
    }
}

/**
 * Handle device connection
 */
function handleDeviceDidConnect(
    deviceId: string,
    deviceInfo: NonNullable<StreamDeckMessage['deviceInfo']>
): void {
    const columns = DeviceColumns[deviceInfo.type] || deviceInfo.size.columns;
    devices.set(deviceId, {
        type: deviceInfo.type,
        columns,
        rows: deviceInfo.size.rows
    });
}

/**
 * Handle settings received from Property Inspector
 */
function handleDidReceiveSettings(
    action: string,
    context: string,
    payload: NonNullable<StreamDeckMessage['payload']>
): void {
    if (action === Actions.SESSION) {
        const buttonInfo = sessionButtons.get(context);
        if (buttonInfo) {
            buttonInfo.sessionNumber = payload.settings?.sessionNumber || 'auto';
            updateSessionButton(context, buttonInfo);
        }
    }
}

/**
 * Handle button appearing
 */
function handleWillAppear(
    action: string,
    context: string,
    payload: NonNullable<StreamDeckMessage['payload']>,
    deviceId?: string
): void {
    if (action === Actions.SESSION && payload.coordinates) {
        const { row, column } = payload.coordinates;

        // Get device columns (default to 5 for Standard)
        const device = deviceId ? devices.get(deviceId) : undefined;
        const columns = device?.columns || 5;
        const buttonIndex = row * columns + column;

        // Get session number from settings
        const sessionNumber = payload.settings?.sessionNumber || 'auto';

        const buttonInfo: ButtonInfo = {
            row,
            col: column,
            buttonIndex,
            deviceId,
            sessionNumber
        };
        sessionButtons.set(context, buttonInfo);
        updateSessionButton(context, buttonInfo);
    }
}

/**
 * Handle button disappearing
 */
function handleWillDisappear(action: string, context: string): void {
    if (action === Actions.SESSION) {
        sessionButtons.delete(context);
    }
}

/**
 * Handle key press
 */
function handleKeyDown(action: string, context: string): void {
    debugLog(`KeyDown: action=${action}`);
    switch (action) {
        case Actions.SESSION:
            handleSessionClick(context);
            break;
        case Actions.SCROLL_UP:
            debugLog('Executing handleScrollUp');
            handleScrollUp();
            break;
        case Actions.SCROLL_DOWN:
            debugLog('Executing handleScrollDown');
            handleScrollDown();
            break;
        case Actions.DICTATION:
            handleDictation();
            break;
        case Actions.ENTER:
            debugLog('Executing handleEnter');
            handleEnter();
            break;
        case Actions.ESCAPE:
            handleEscape();
            break;
        case Actions.SHIFT_TAB:
            handleShiftTab();
            break;
        case Actions.FOCUS_WAITING:
            handleFocusWaiting();
            break;
    }
}

/**
 * Handle escape key
 */
function handleEscape(): void {
    exec(`osascript -e 'tell application "System Events" to key code 53'`, (error) => {
        if (error) {
            console.error('Escape key error:', error.message);
        }
    });
}

/**
 * Handle Shift+Tab key (toggle plan mode)
 */
function handleShiftTab(): void {
    exec(`osascript -e 'tell application "System Events" to key code 48 using shift down'`, (error) => {
        if (error) {
            console.error('Shift+Tab error:', error.message);
        }
    });
}

/**
 * Handle focus waiting session (same as global hotkey)
 * Simulates Cmd+Ctrl+C to trigger the app's handleHotkeyPressed
 */
function handleFocusWaiting(): void {
    // Simulate the global hotkey (Cmd+Ctrl+C) to use app's unified logic
    exec(`osascript -e 'tell application "System Events" to key code 8 using {command down, control down}'`, (error) => {
        if (error) console.error('Hotkey simulation error:', error.message);
    });
}

/**
 * Handle session button click
 */
function handleSessionClick(context: string): void {
    const buttonInfo = sessionButtons.get(context);
    if (!buttonInfo) return;

    // Determine session index based on settings
    let sessionIndex: number;
    if (buttonInfo.sessionNumber && buttonInfo.sessionNumber !== 'auto') {
        sessionIndex = parseInt(buttonInfo.sessionNumber, 10) - 1;
    } else {
        sessionIndex = currentOffset + buttonInfo.buttonIndex;
    }

    if (sessionIndex < 0 || sessionIndex >= sessions.length) return;

    try {
        execSync(`"${CLI_PATH}" focus --index ${sessionIndex}`, {
            encoding: 'utf-8',
            timeout: 5000
        });
    } catch (error) {
        console.error('Focus error:', (error as Error).message);
    }
}

/**
 * Handle up arrow key
 */
function handleScrollUp(): void {
    exec(`osascript -e 'tell application "System Events" to key code 126'`, (error) => {
        if (error) {
            console.error('Up arrow key error:', error.message);
        }
    });
}

/**
 * Handle down arrow key
 */
function handleScrollDown(): void {
    exec(`osascript -e 'tell application "System Events" to key code 125'`, (error) => {
        if (error) {
            console.error('Down arrow key error:', error.message);
        }
    });
}

/**
 * Handle dictation toggle via CCStatusBar CLI
 */
function handleDictation(): void {
    // Use CCStatusBar CLI which handles CGEvent double-Fn tap with AppleScript fallback
    exec(`"${CLI_PATH}" dictation`, (error) => {
        if (error) {
            console.error('Dictation error:', error.message);
        }
    });
}

/**
 * Handle enter key
 */
function handleEnter(): void {
    exec(`osascript -e 'tell application "System Events" to key code 36'`, (error) => {
        if (error) {
            console.error('Enter key error:', error.message);
        }
    });
}

/**
 * Start polling for session updates
 */
function startPolling(): void {
    fetchSessions();
    pollInterval = setInterval(fetchSessions, 1000);
}

/**
 * Stop polling
 */
function stopPolling(): void {
    if (pollInterval) {
        clearInterval(pollInterval);
        pollInterval = null;
    }
}

/**
 * Fetch sessions from CLI
 */
function fetchSessions(): void {
    try {
        const output = execSync(`"${CLI_PATH}" list --json`, {
            encoding: 'utf-8',
            timeout: 5000
        });

        const data = JSON.parse(output) as SessionListResponse;
        sessions = data.sessions || [];
        totalSessions = data.total || 0;

        updateAllSessionButtons();
    } catch {
        sessions = [];
        totalSessions = 0;
        updateAllSessionButtons();
    }
}

/**
 * Update all session buttons
 */
function updateAllSessionButtons(): void {
    for (const [context, buttonInfo] of sessionButtons) {
        updateSessionButton(context, buttonInfo);
    }
}

/**
 * Update a single session button
 */
function updateSessionButton(context: string, buttonInfo: ButtonInfo): void {
    // Determine session index based on settings
    let sessionIndex: number;
    if (buttonInfo.sessionNumber && buttonInfo.sessionNumber !== 'auto') {
        // Fixed session number (1-based, convert to 0-based)
        sessionIndex = parseInt(buttonInfo.sessionNumber, 10) - 1;
    } else {
        // Auto: use button position with current offset
        sessionIndex = currentOffset + buttonInfo.buttonIndex;
    }

    const session = sessions[sessionIndex];

    if (!session) {
        setImage(context, createEmptyButtonSVG());
        return;
    }

    // Determine background color based on status and acknowledged state
    // Match menu bar behavior: acknowledged waiting_input shows as green
    let bgColor: string;
    if (session.is_acknowledged) {
        bgColor = '#34C759';  // Green (acknowledged)
    } else if (session.status === 'running') {
        bgColor = '#34C759';  // Green
    } else if (session.status === 'waiting_input') {
        bgColor = session.waiting_reason === 'permission_prompt' ? '#FF3B30' : '#FFCC00';
    } else {
        bgColor = '#8E8E93';  // Gray
    }

    const svg = createSessionButtonSVG(session.project, bgColor, buttonInfo.buttonIndex, session.icon_base64);
    setImage(context, svg);
}

/**
 * Create SVG for session button (72x72, max 3 lines, vertically centered)
 * Layers: background color → terminal/editor icon → project name
 */
function createSessionButtonSVG(projectName: string, bgColor: string, buttonIndex: number = 0, iconBase64?: string): string {
    const textColor = bgColor === '#FFCC00' ? '#000000' : '#FFFFFF';
    const maxCharsPerLine = 6;
    const fontSize = 18;
    const lineHeight = 20;

    // Split into lines (max 3)
    const lines: string[] = [];
    let remaining = projectName;

    while (remaining.length > 0 && lines.length < 3) {
        if (remaining.length <= maxCharsPerLine) {
            lines.push(remaining);
            break;
        }
        // Try to split at hyphen/underscore within range
        const chunk = remaining.substring(0, maxCharsPerLine + 2);
        const splitMatch = chunk.match(/[-_]/);
        let splitIndex: number;
        if (splitMatch && splitMatch.index !== undefined && splitMatch.index > 0 && splitMatch.index <= maxCharsPerLine) {
            splitIndex = splitMatch.index + 1;
        } else {
            splitIndex = maxCharsPerLine;
        }
        lines.push(remaining.substring(0, splitIndex));
        remaining = remaining.substring(splitIndex);
    }

    // Truncate last line if there's more text
    if (remaining.length > 0 && lines.length === 3) {
        lines[2] = lines[2].substring(0, maxCharsPerLine - 1) + '…';
    }

    const sessionNum = currentOffset + buttonIndex + 1;

    // Calculate vertical center (36 is center of 72px canvas)
    const totalTextHeight = lines.length * lineHeight;
    const startY = 36 - (totalTextHeight / 2) + (lineHeight / 2) + 4; // +4 for session number offset

    // Add shadow for white text (not needed for black text on yellow)
    const needsShadow = textColor === '#FFFFFF';
    const textElements = lines.map((line, i) => {
        const y = startY + i * lineHeight;
        const shadow = needsShadow
            ? `<text x="38" y="${y + 2}" font-family="system-ui, -apple-system, sans-serif" font-size="${fontSize}" font-weight="bold" fill="#000000" opacity="0.6" text-anchor="middle" dominant-baseline="middle">${escapeXml(line)}</text>`
            : '';
        const main = `<text x="36" y="${y}" font-family="system-ui, -apple-system, sans-serif" font-size="${fontSize}" font-weight="bold" fill="${textColor}" text-anchor="middle" dominant-baseline="middle">${escapeXml(line)}</text>`;
        return shadow + main;
    }).join('\n');

    // Terminal/editor icon (72x72, full size)
    const iconElement = iconBase64
        ? `<image x="0" y="0" width="72" height="72" opacity="0.4" href="data:image/png;base64,${iconBase64}"/>`
        : '';

    const svg = `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="72" height="72" viewBox="0 0 72 72">
<rect width="72" height="72" rx="8" fill="${bgColor}"/>
${iconElement}
<text x="4" y="12" font-family="system-ui, -apple-system, sans-serif" font-size="10" font-weight="bold" fill="${textColor}" opacity="0.7">${sessionNum}</text>
${textElements}
</svg>`;

    return `data:image/svg+xml,${encodeURIComponent(svg)}`;
}

/**
 * Create SVG for empty button (72x72)
 */
function createEmptyButtonSVG(): string {
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="72" height="72" viewBox="0 0 72 72">
<rect width="72" height="72" rx="8" fill="#2C2C2E"/>
</svg>`;

    return `data:image/svg+xml,${encodeURIComponent(svg)}`;
}

/**
 * Escape XML special characters
 */
function escapeXml(str: string): string {
    return str
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&apos;');
}

/**
 * Set button image
 */
function setImage(context: string, imageData: string): void {
    send({
        event: 'setImage',
        context,
        payload: {
            image: imageData,
            target: 0
        }
    });
}

// Parse command line arguments and connect
const args = process.argv.slice(2);
let port: string | undefined;
let uuid: string | undefined;
let registerEvent: string | undefined;
let info: string | undefined;

for (let i = 0; i < args.length; i++) {
    switch (args[i]) {
        case '-port':
            port = args[++i];
            break;
        case '-pluginUUID':
            uuid = args[++i];
            break;
        case '-registerEvent':
            registerEvent = args[++i];
            break;
        case '-info':
            info = args[++i];
            break;
    }
}

if (port && uuid && registerEvent) {
    connectElgatoStreamDeckSocket(port, uuid, registerEvent, info || '');
}
