import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import vm from 'node:vm';

test('a rejected connection tells Action Cable not to reconnect', async () => {
    const transports = [];
    class NativeWebSocket extends EventTarget {
        constructor() {
            super();
            transports.push(this);
        }
        send() {}
        close() {}
    }
    const sandbox = {
        WebSocket: NativeWebSocket, EventTarget, Event, MessageEvent, CloseEvent: Event, DOMException,
        AbortController, AbortSignal, URL, crypto, setTimeout, clearTimeout, setInterval, clearInterval,
        location: { href: 'https://demo.example/' },
        __laravelCloudWebsockets: { scheme: 'https', host: 'socket.example', port: 443, key: 'public-key' },
        addEventListener() {}, removeEventListener() {},
        fetch: async () => ({ ok: false, status: 401, json: async () => ({ error: 'Unauthorized connection' }) }),
    };
    vm.runInNewContext(await readFile(new URL('../lib/action_cable/subscription_adapter/cloud/transport.js', import.meta.url), 'utf8'), sandbox);
    const socket = new sandbox.WebSocket('/cable', ['actioncable-v1-json', 'actioncable-unsupported']);
    const events = [];
    socket.onmessage = event => events.push(JSON.parse(event.data));
    socket.onclose = () => events.push('close');

    transports[0].dispatchEvent(new MessageEvent('message', { data: JSON.stringify({ event: 'pusher:connection_established', data: { socket_id: '1.1' } }) }));
    await new Promise(resolve => setImmediate(resolve));

    assert.deepEqual(events, [{ type: 'disconnect', reason: 'Unauthorized connection', reconnect: false }, 'close']);
    assert.equal(socket.readyState, 3);
});
