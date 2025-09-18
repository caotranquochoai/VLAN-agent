import { WebSocket } from 'ws';
import { spawn } from 'child_process';
import os from 'os';
import dotenv from 'dotenv';
import path from 'path';

// --- Configuration ---
dotenv.config({ path: path.resolve(__dirname, '.env') });

const SERVER_URL = process.env.SERVER_URL;
const AGENT_ID = process.env.AGENT_ID;
const ACCESS_CODE = process.env.AGENT_ACCESS_CODE;
const FINGERPRINT_HASH = process.env.FINGERPRINT_HASH;

if (!SERVER_URL || !AGENT_ID || !ACCESS_CODE || !FINGERPRINT_HASH) {
    console.error('Missing required environment variables. Please run setup_agent.sh again.');
    process.exit(1);
}

let ws: WebSocket;
let reconnectInterval: NodeJS.Timeout | null = null;

async function connect() {
    console.log(`Attempting to connect to server at ${SERVER_URL} as ${AGENT_ID}...`);
    
    const connectUrl = new URL(SERVER_URL!);
    connectUrl.searchParams.append('type', 'agent');
    connectUrl.searchParams.append('id', AGENT_ID!);
    connectUrl.searchParams.append('accessCode', ACCESS_CODE!);
    connectUrl.searchParams.append('fingerprint', FINGERPRINT_HASH!);
    
    ws = new WebSocket(connectUrl.toString());

    ws.on('open', () => {
        console.log('Connection to server established.');
        if (reconnectInterval) {
            clearInterval(reconnectInterval);
            reconnectInterval = null;
        }
        setInterval(() => {
            if (ws.readyState === WebSocket.OPEN) {
                ws.send(JSON.stringify({ type: 'heartbeat' }));
            }
        }, 30000);
    });

    ws.on('message', (message) => {
        try {
            const data = JSON.parse(message.toString());
            if (data && data.script && data.id) {
                sendMessageToServer({ type: 'ack', commandId: data.id, status: 'started' });
                executeShellCommand(data);
            }
        } catch (error) {
            console.error('Failed to parse incoming message:', error);
        }
    });

    ws.on('close', (code, reason) => {
        const reasonString = reason.toString();
        console.log(`Disconnected from server. Code: ${code}, Reason: ${reasonString}`);

        if (code === 1008) { // Policy Violation
            console.error(`FATAL: Connection rejected by server: ${reasonString}. Please re-run setup_agent.sh or contact an administrator.`);
            if (reconnectInterval) clearInterval(reconnectInterval);
            return;
        }

        if (!reconnectInterval) {
            console.log('Attempting to reconnect in 5 seconds...');
            reconnectInterval = setInterval(connect, 5000);
        }
    });

    ws.on('error', (error) => {
        console.error('WebSocket error:', error.message);
        ws.close();
    });
}

function sendMessageToServer(payload: object) {
    if (ws && ws.readyState === WebSocket.OPEN) {
        const message = {
            target: 'server',
            sourceId: AGENT_ID,
            payload: { ...payload, agentId: AGENT_ID }
        };
        ws.send(JSON.stringify(message));
    }
}

function executeShellCommand(command: { id: string, script: string, args: string[] }) {
    const { id, script, args } = command;
    const scriptPath = `./${script}`;

    // Wrapper to ensure commandId is always included
    const sendReply = (message: object) => {
        sendMessageToServer({ commandId: id, ...message });
    };

    const child = spawn(scriptPath, args, { shell: true, stdio: ['pipe', 'pipe', 'pipe'] });

    if (script === 'export_proxies.sh' && args.length > 0) {
        const stdinData = (command as any).stdin_data;
        if (stdinData && Array.isArray(stdinData)) {
            child.stdin.write(stdinData.join('\n'));
        }
    }
    child.stdin.end();

    let stdout = '';
    child.stdout.on('data', (data) => { stdout += data.toString(); });
    child.stderr.on('data', (data) => { /* stderr is handled on close */ });
    child.on('error', (err) => {
        sendReply({ type: 'status', status: 'error', message: err.message });
    });
    
    child.stdout.on('end', () => {
        if (script === 'list_proxies.sh' || script === 'export_proxies.sh') {
            sendReply({ type: 'log', stream: 'stdout', data: stdout.trim() });
            return;
        }
        const lines = stdout.split('\n').filter(line => line.trim() !== '');
        lines.forEach(line => {
            if (line.startsWith('STATUS_JSON:')) {
                try {
                    sendReply({ type: 'agent-status-update', status: JSON.parse(line.substring(12)) });
                } catch (e) { console.error(`Failed to parse agent status JSON:`, e); }
            } else if (line.startsWith('EVENT_PAYLOAD:')) {
                try {
                    const eventData = JSON.parse(line.substring(14));
                    // For bulk creation, the original command ID is passed through the script
                    const finalCommandId = eventData.originalCommandId || id;
                    
                    // Re-wrap the payload to be sent to the server
                    const messageToServer = {
                        target: 'server',
                        sourceId: AGENT_ID,
                        payload: {
                            type: 'event',
                            id: finalCommandId, // Use the original ID for bulk, or current ID for single
                            payload: eventData
                        }
                    };
                    ws.send(JSON.stringify(messageToServer));

                } catch (e) { console.error('Failed to parse event payload:', e); }
            } else {
                 sendReply({ type: 'log', stream: 'stdout', data: line });
            }
        });
    });

    child.on('close', (code) => {
        sendReply({ type: 'status', status: 'completed', exitCode: code });
    });
}

connect();
