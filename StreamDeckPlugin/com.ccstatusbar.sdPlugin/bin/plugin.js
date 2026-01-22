"use strict";
/**
 * CC Status Bar - Stream Deck Plugin (TypeScript Source)
 *
 * This is the TypeScript source file for the plugin.
 * Compile with: tsc src/plugin.ts --outDir bin --target ES2020 --module CommonJS
 */
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const ws_1 = __importDefault(require("ws"));
const child_process_1 = require("child_process");
const fs_1 = require("fs");
const path_1 = __importDefault(require("path"));
// Debug log to file
const fs_2 = require("fs");
const LOG_DIR = path_1.default.join(process.env.HOME || '', 'Library/Logs/CCStatusBar');
const LOG_FILE = path_1.default.join(LOG_DIR, 'streamdeck-plugin.log');
try {
    (0, fs_2.mkdirSync)(LOG_DIR, { recursive: true });
}
catch { }
function debugLog(msg) {
    try {
        (0, fs_1.appendFileSync)(LOG_FILE, `${new Date().toISOString()} ${msg}\n`);
    }
    catch (e) {
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
};
// Action UUIDs
const Actions = {
    SESSION: 'com.ccstatusbar.session',
    SCROLL_UP: 'com.ccstatusbar.scroll-up',
    SCROLL_DOWN: 'com.ccstatusbar.scroll-down',
    DICTATION: 'com.ccstatusbar.dictation',
    ENTER: 'com.ccstatusbar.enter',
    ESCAPE: 'com.ccstatusbar.escape'
};
// Device type to columns mapping
const DeviceColumns = {
    0: 5, // Standard (15 buttons, 3x5)
    1: 3, // Mini (6 buttons, 2x3)
    2: 8, // XL (32 buttons, 4x8)
    7: 4, // Plus (8 buttons + touch, 2x4)
    9: 4 // Neo (8 buttons + touch, 2x4)
};
const devices = new Map();
// Plugin state
let websocket = null;
let pluginUUID = null;
const sessionButtons = new Map();
let currentOffset = 0;
let totalSessions = 0;
let sessions = [];
let pollInterval = null;
// CCStatusBar CLI path
const CLI_PATH = path_1.default.join(process.env.HOME || '', 'Library/Application Support/CCStatusBar/bin/CCStatusBar');
/**
 * Connect to Stream Deck
 */
function connectElgatoStreamDeckSocket(port, uuid, registerEvent, _info) {
    pluginUUID = uuid;
    websocket = new ws_1.default(`ws://127.0.0.1:${port}`);
    websocket.on('open', () => {
        debugLog('WebSocket connected');
        send({ event: registerEvent, uuid });
        startPolling();
    });
    websocket.on('message', (data) => {
        const message = JSON.parse(data.toString());
        handleMessage(message);
    });
    websocket.on('error', (error) => {
        console.error('WebSocket error:', error);
    });
    websocket.on('close', () => {
        stopPolling();
    });
}
/**
 * Send message to Stream Deck
 */
function send(payload) {
    if (websocket && websocket.readyState === ws_1.default.OPEN) {
        websocket.send(JSON.stringify(payload));
    }
}
/**
 * Handle incoming messages from Stream Deck
 */
function handleMessage(data) {
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
function handleDeviceDidConnect(deviceId, deviceInfo) {
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
function handleDidReceiveSettings(action, context, payload) {
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
function handleWillAppear(action, context, payload, deviceId) {
    if (action === Actions.SESSION && payload.coordinates) {
        const { row, column } = payload.coordinates;
        // Get device columns (default to 5 for Standard)
        const device = deviceId ? devices.get(deviceId) : undefined;
        const columns = device?.columns || 5;
        const buttonIndex = row * columns + column;
        // Get session number from settings
        const sessionNumber = payload.settings?.sessionNumber || 'auto';
        const buttonInfo = {
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
function handleWillDisappear(action, context) {
    if (action === Actions.SESSION) {
        sessionButtons.delete(context);
    }
}
/**
 * Handle key press
 */
function handleKeyDown(action, context) {
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
    }
}
/**
 * Handle escape key
 */
function handleEscape() {
    (0, child_process_1.exec)(`osascript -e 'tell application "System Events" to key code 53'`, (error) => {
        if (error) {
            console.error('Escape key error:', error.message);
        }
    });
}
/**
 * Handle session button click
 */
function handleSessionClick(context) {
    const buttonInfo = sessionButtons.get(context);
    if (!buttonInfo)
        return;
    // Determine session index based on settings
    let sessionIndex;
    if (buttonInfo.sessionNumber && buttonInfo.sessionNumber !== 'auto') {
        sessionIndex = parseInt(buttonInfo.sessionNumber, 10) - 1;
    }
    else {
        sessionIndex = currentOffset + buttonInfo.buttonIndex;
    }
    if (sessionIndex < 0 || sessionIndex >= sessions.length)
        return;
    try {
        (0, child_process_1.execSync)(`"${CLI_PATH}" focus --index ${sessionIndex}`, {
            encoding: 'utf-8',
            timeout: 5000
        });
    }
    catch (error) {
        console.error('Focus error:', error.message);
    }
}
/**
 * Handle up arrow key
 */
function handleScrollUp() {
    (0, child_process_1.exec)(`osascript -e 'tell application "System Events" to key code 126'`, (error) => {
        if (error) {
            console.error('Up arrow key error:', error.message);
        }
    });
}
/**
 * Handle down arrow key
 */
function handleScrollDown() {
    (0, child_process_1.exec)(`osascript -e 'tell application "System Events" to key code 125'`, (error) => {
        if (error) {
            console.error('Down arrow key error:', error.message);
        }
    });
}
/**
 * Handle dictation toggle via CCStatusBar CLI
 */
function handleDictation() {
    // Use CCStatusBar CLI which handles CGEvent double-Fn tap with AppleScript fallback
    (0, child_process_1.exec)(`"${CLI_PATH}" dictation`, (error) => {
        if (error) {
            console.error('Dictation error:', error.message);
        }
    });
}
/**
 * Handle enter key
 */
function handleEnter() {
    (0, child_process_1.exec)(`osascript -e 'tell application "System Events" to key code 36'`, (error) => {
        if (error) {
            console.error('Enter key error:', error.message);
        }
    });
}
/**
 * Start polling for session updates
 */
function startPolling() {
    fetchSessions();
    pollInterval = setInterval(fetchSessions, 1000);
}
/**
 * Stop polling
 */
function stopPolling() {
    if (pollInterval) {
        clearInterval(pollInterval);
        pollInterval = null;
    }
}
/**
 * Fetch sessions from CLI
 */
function fetchSessions() {
    try {
        const output = (0, child_process_1.execSync)(`"${CLI_PATH}" list --json`, {
            encoding: 'utf-8',
            timeout: 5000
        });
        const data = JSON.parse(output);
        sessions = data.sessions || [];
        totalSessions = data.total || 0;
        updateAllSessionButtons();
    }
    catch {
        sessions = [];
        totalSessions = 0;
        updateAllSessionButtons();
    }
}
/**
 * Update all session buttons
 */
function updateAllSessionButtons() {
    for (const [context, buttonInfo] of sessionButtons) {
        updateSessionButton(context, buttonInfo);
    }
}
/**
 * Update a single session button
 */
function updateSessionButton(context, buttonInfo) {
    // Determine session index based on settings
    let sessionIndex;
    if (buttonInfo.sessionNumber && buttonInfo.sessionNumber !== 'auto') {
        // Fixed session number (1-based, convert to 0-based)
        sessionIndex = parseInt(buttonInfo.sessionNumber, 10) - 1;
    }
    else {
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
    let bgColor;
    if (session.is_acknowledged) {
        bgColor = '#34C759'; // Green (acknowledged)
    }
    else if (session.status === 'running') {
        bgColor = '#34C759'; // Green
    }
    else if (session.status === 'waiting_input') {
        bgColor = session.waiting_reason === 'permission_prompt' ? '#FF3B30' : '#FFCC00';
    }
    else {
        bgColor = '#8E8E93'; // Gray
    }
    const svg = createSessionButtonSVG(session.project, bgColor, buttonInfo.buttonIndex);
    setImage(context, svg);
}
/**
 * Create SVG for session button (72x72, max 3 lines, vertically centered)
 */
function createSessionButtonSVG(projectName, bgColor, buttonIndex = 0) {
    const textColor = bgColor === '#FFCC00' ? '#000000' : '#FFFFFF';
    const maxCharsPerLine = 6;
    const fontSize = 18;
    const lineHeight = 20;
    // Split into lines (max 3)
    const lines = [];
    let remaining = projectName;
    while (remaining.length > 0 && lines.length < 3) {
        if (remaining.length <= maxCharsPerLine) {
            lines.push(remaining);
            break;
        }
        // Try to split at hyphen/underscore within range
        const chunk = remaining.substring(0, maxCharsPerLine + 2);
        const splitMatch = chunk.match(/[-_]/);
        let splitIndex;
        if (splitMatch && splitMatch.index !== undefined && splitMatch.index > 0 && splitMatch.index <= maxCharsPerLine) {
            splitIndex = splitMatch.index + 1;
        }
        else {
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
    const textElements = lines.map((line, i) => `<text x="36" y="${startY + i * lineHeight}" font-family="system-ui, -apple-system, sans-serif" font-size="${fontSize}" font-weight="bold" fill="${textColor}" text-anchor="middle" dominant-baseline="middle">${escapeXml(line)}</text>`).join('\n');
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="72" height="72" viewBox="0 0 72 72">
<rect width="72" height="72" rx="8" fill="${bgColor}"/>
<text x="4" y="12" font-family="system-ui, -apple-system, sans-serif" font-size="10" font-weight="bold" fill="${textColor}" opacity="0.7">${sessionNum}</text>
${textElements}
</svg>`;
    return `data:image/svg+xml,${encodeURIComponent(svg)}`;
}
/**
 * Create SVG for empty button (72x72)
 */
function createEmptyButtonSVG() {
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="72" height="72" viewBox="0 0 72 72">
<rect width="72" height="72" rx="8" fill="#2C2C2E"/>
</svg>`;
    return `data:image/svg+xml,${encodeURIComponent(svg)}`;
}
/**
 * Escape XML special characters
 */
function escapeXml(str) {
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
function setImage(context, imageData) {
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
let port;
let uuid;
let registerEvent;
let info;
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
