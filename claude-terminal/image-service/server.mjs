#!/usr/bin/env node

/**
 * Claude Terminal Pro - Image Upload Service
 *
 * Lightweight Express server that handles file uploads (images, PDFs, text,
 * anything Claude can read) from browser paste/drag-drop.
 * Designed for resource-constrained environments (Raspberry Pi).
 *
 * Features:
 * - Serves custom HTML interface with embedded ttyd terminal
 * - Handles file uploads via POST /upload
 * - Saves them to /data/uploads (left out of backups, pruned after 30 days)
 * - Returns file paths for use with Claude CLI
 * - ARM-compatible (no native dependencies)
 */

import express from 'express';
import http from 'node:http';
import multer from 'multer';
import path from 'node:path';
import fs from 'node:fs';
import { createProxyMiddleware } from 'http-proxy-middleware';

import { register as registerFilesApi } from './files-api.mjs';
import { register as registerGitApi } from './git-api.mjs';
import { uploadFileName, uniqueName } from './uploads.mjs';

const app = express();
const PORT = process.env.IMAGE_SERVICE_PORT || 7680;
const TTYD_PORT = process.env.TTYD_PORT || 7681;
const UPLOAD_DIR = process.env.UPLOAD_DIR || '/data/uploads';
const MAX_UPLOAD_MB = 50;
// Set by run.sh from the add-on metadata; shown in the panel header
const ADDON_VERSION = process.env.ADDON_VERSION || '';
// Set by run.sh when port 7680 is published to the host
const ALLOW_DIRECT_ACCESS = process.env.ALLOW_DIRECT_ACCESS === '1';
// The Supervisor's ingress proxy, plus loopback for in-container checks
const INGRESS_ADDRESSES = new Set(['172.30.32.2', '127.0.0.1', '::1']);

// Ensure upload directory exists
if (!fs.existsSync(UPLOAD_DIR)) {
    fs.mkdirSync(UPLOAD_DIR, { recursive: true, mode: 0o755 });
    console.log(`Created upload directory: ${UPLOAD_DIR}`);
}

// Any file type: Claude reads PDFs, text, code and data as well as images.
// Files are only stored, never run, and whoever can reach this page already
// has a root shell in the add-on.
const storage = multer.diskStorage({
    destination: (req, file, cb) => {
        cb(null, UPLOAD_DIR);
    },
    filename: (req, file, cb) => {
        // The path is typed at the prompt after upload, so the browser's
        // name is reduced to characters that need no quoting
        cb(null, uniqueName(UPLOAD_DIR, uploadFileName(file.originalname, file.mimetype)));
    }
});

const upload = multer({
    storage: storage,
    limits: {
        fileSize: MAX_UPLOAD_MB * 1024 * 1024
    }
});

// API routes MUST come before static files middleware
// Otherwise static middleware will intercept API requests

// Health check endpoint
app.get('/health', (req, res) => {
    res.json({ status: 'ok', uploadDir: UPLOAD_DIR, version: ADDON_VERSION });
});

// Provide ttyd port to frontend
app.get('/config', (req, res) => {
    res.json({
        ttydPort: TTYD_PORT,
        uploadDir: UPLOAD_DIR,
        version: ADDON_VERSION
    });
});

// Read-only file browser for the sidebar, plus HA's config check
registerFilesApi(app);
// Changes tab: git status/diff of /config, revert and checkpoints
registerGitApi(app);

// File upload endpoint
app.post('/upload', upload.single('file'), (req, res) => {
    if (!req.file) {
        return res.status(400).json({ error: 'No file provided' });
    }

    const filePath = path.join(UPLOAD_DIR, req.file.filename);
    console.log(`File uploaded: ${filePath} (${(req.file.size / 1024).toFixed(2)} KB)`);

    res.json({
        success: true,
        path: filePath,
        filename: req.file.filename,
        size: req.file.size
    });
});

// Proxy endpoint for ttyd terminal
// This allows ttyd to work through Home Assistant ingress
// Handles both HTTP and WebSocket connections
// http-proxy-middleware v4: Express strips the mount path (/terminal) from
// req.url before the middleware sees it, so the stripped path is forwarded
// as-is and no pathRewrite is needed (v2 repatched req.url, which is why it
// needed the rewrite). ws: true subscribes to the server's upgrade event on
// the first HTTP request through /terminal, same as v2.
app.use('/terminal', createProxyMiddleware({
    target: `http://127.0.0.1:${TTYD_PORT}`,
    changeOrigin: true,
    ws: true, // Enable WebSocket proxying
    // WS upgrades arrive with the full browser path (/terminal/ws) because
    // Express only strips the mount for HTTP; ttyd expects its socket at
    // /ws, so strip the prefix on upgrades. HTTP paths after the mount
    // don't start with /terminal, so they pass through untouched.
    pathRewrite: (p, req) => (req.headers.upgrade ? p.replace(/^\/terminal/, '') : p),
    on: {
        error: (err, req, res) => {
            console.error('Proxy error:', err.message);
            // res may be a raw socket (WebSocket) instead of an Express response
            if (typeof res.status === 'function') {
                res.status(502).send('Failed to connect to terminal');
            } else if (typeof res.end === 'function') {
                res.end();
            }
        }
    }
}));

// Serve static files (HTML interface) - MUST be after API routes
app.use(express.static(path.join(import.meta.dirname, 'public')));

// Multer error handling middleware
app.use((err, req, res, next) => {
    if (err instanceof multer.MulterError) {
        console.error('Multer error:', err.message);
        const message = err.code === 'LIMIT_FILE_SIZE'
            ? `File too large (the limit is ${MAX_UPLOAD_MB} MB)`
            : `Upload error: ${err.message}`;
        return res.status(400).json({
            success: false,
            error: message
        });
    }

    if (err) {
        console.error('Error:', err.message);
        return res.status(500).json({
            success: false,
            error: err.message
        });
    }

    next();
});

// Create HTTP server and start listening
const server = http.createServer(app);

// This page is a root shell with no login of its own. Unless the port has
// been published deliberately, refuse anything but ingress at the socket, so
// other add-ons on the hassio network can't reach it. Checking the socket
// also covers WebSocket upgrades, which bypass Express middleware.
if (!ALLOW_DIRECT_ACCESS) {
    server.on('connection', (socket) => {
        const address = (socket.remoteAddress || '').replace(/^::ffff:/, '');
        if (!INGRESS_ADDRESSES.has(address)) {
            console.warn(`Refused connection from ${address} (only ingress is allowed)`);
            socket.destroy();
        }
    });
}

server.listen(PORT, '0.0.0.0', () => {
    console.log(`Claude Terminal Image Service running on port ${PORT}`);
    console.log(`Upload directory: ${UPLOAD_DIR}`);
    console.log(`ttyd terminal on port: ${TTYD_PORT}`);
    console.log(`Terminal proxy available at /terminal/`);
});
