package signaling

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/url"
	"sync"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
	"github.com/gorilla/websocket"
)

const (
	// DefaultSignalingServer is the public LocalSend signaling server.
	DefaultSignalingServer = "wss://public.localsend.org/v1/ws"

	// Ping interval to keep connection alive (matches web client: 120 seconds).
	pingInterval = 2 * time.Minute

	// Token refresh interval for long sessions (matches web client: 30 minutes).
	// Tokens are valid for 1 hour, so refreshing at 30 minutes provides margin.
	tokenRefreshInterval = 30 * time.Minute

	// Write timeout for WebSocket messages.
	writeTimeout = 10 * time.Second
)

// SignalingClient manages connection to the LocalSend signaling server.
type SignalingClient struct {
	conn      *websocket.Conn
	client    ClientInfo // Our info with server-assigned ID
	peers     map[uuid.UUID]ClientInfo
	peersMu   sync.RWMutex
	msgChan   chan WsServerMessage
	sendChan  chan WsClientMessage
	done      chan struct{}
	closeOnce sync.Once                        // Ensures Close() is only executed once
	onAnswer  map[string]func(WsServerMessage) // sessionID -> callback
	answerMu  sync.Mutex

	// Token refresh support
	baseInfo       ClientInfoWithoutID // Client info without token (for refresh)
	tokenGenerator atomic.Value        // func() (string, error) - stored atomically for thread safety
	refreshStarted atomic.Bool         // Prevents multiple token refresh goroutines
}

// Connect establishes a WebSocket connection to the signaling server.
func Connect(uri string, info ClientInfoWithoutID) (*SignalingClient, error) {
	return ConnectWithContext(context.Background(), uri, info)
}

// ConnectWithContext establishes a WebSocket connection with context for cancellation.
func ConnectWithContext(ctx context.Context, uri string, info ClientInfoWithoutID) (*SignalingClient, error) {
	// Encode client info as base64 JSON in query parameter
	infoJSON, err := json.Marshal(info)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal client info: %w", err)
	}
	encodedInfo := base64.RawURLEncoding.EncodeToString(infoJSON)

	// Build WebSocket URL with query parameter
	wsURL, err := url.Parse(uri)
	if err != nil {
		return nil, fmt.Errorf("invalid signaling server URL: %w", err)
	}
	q := wsURL.Query()
	q.Set("d", encodedInfo)
	wsURL.RawQuery = q.Encode()

	slog.Debug("Connecting to signaling server", "url", wsURL.String())

	// Connect to WebSocket with context
	dialer := websocket.Dialer{}
	conn, _, err := dialer.DialContext(ctx, wsURL.String(), nil)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to signaling server: %w", err)
	}

	client := &SignalingClient{
		conn:     conn,
		peers:    make(map[uuid.UUID]ClientInfo),
		msgChan:  make(chan WsServerMessage, 16),
		sendChan: make(chan WsClientMessage, 16),
		done:     make(chan struct{}),
		onAnswer: make(map[string]func(WsServerMessage)),
		baseInfo: ClientInfoWithoutID{
			Alias:       info.Alias,
			Version:     info.Version,
			DeviceModel: info.DeviceModel,
			DeviceType:  info.DeviceType,
			// Token will be regenerated during refresh
		},
	}

	// Wait for HELLO message
	if err := client.waitForHello(); err != nil {
		_ = conn.Close()
		return nil, err
	}

	// Start background goroutines
	go client.readLoop()
	go client.writeLoop()
	go client.pingLoop()

	slog.Info("Connected to signaling server", "id", client.client.ID, "peers", len(client.peers))

	return client, nil
}

// waitForHello waits for the initial HELLO message from the server.
func (c *SignalingClient) waitForHello() error {
	_ = c.conn.SetReadDeadline(time.Now().Add(30 * time.Second))
	defer func() { _ = c.conn.SetReadDeadline(time.Time{}) }()

	_, msgBytes, err := c.conn.ReadMessage()
	if err != nil {
		return fmt.Errorf("failed to read HELLO: %w", err)
	}

	var msg WsServerMessage
	if err := json.Unmarshal(msgBytes, &msg); err != nil {
		return fmt.Errorf("failed to parse HELLO: %w", err)
	}

	if msg.Type != "HELLO" {
		return fmt.Errorf("expected HELLO, got %s", msg.Type)
	}

	if msg.Client == nil {
		return fmt.Errorf("HELLO missing client info")
	}

	c.client = *msg.Client
	if msg.Peers != nil {
		for _, peer := range *msg.Peers {
			c.peers[peer.ID] = peer
		}
	}

	return nil
}

// readLoop reads messages from the WebSocket.
func (c *SignalingClient) readLoop() {
	defer close(c.msgChan)

	for {
		_, msgBytes, err := c.conn.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseNormalClosure) {
				slog.Warn("WebSocket read error", "error", err)
			}
			return
		}

		var msg WsServerMessage
		if err := json.Unmarshal(msgBytes, &msg); err != nil {
			slog.Warn("Failed to parse message", "error", err, "msg", string(msgBytes))
			continue
		}

		// Handle peer updates
		c.handlePeerUpdate(msg)

		// Handle answer callbacks
		if msg.Type == "ANSWER" && msg.SessionID != "" {
			c.answerMu.Lock()
			if callback, ok := c.onAnswer[msg.SessionID]; ok {
				delete(c.onAnswer, msg.SessionID)
				c.answerMu.Unlock()
				callback(msg)
				continue
			}
			c.answerMu.Unlock()
		}

		// Forward to message channel
		select {
		case c.msgChan <- msg:
		case <-c.done:
			return
		}
	}
}

// writeLoop sends messages to the WebSocket.
func (c *SignalingClient) writeLoop() {
	for {
		select {
		case msg := <-c.sendChan:
			_ = c.conn.SetWriteDeadline(time.Now().Add(writeTimeout))
			if err := c.conn.WriteJSON(msg); err != nil {
				slog.Warn("Failed to send message", "error", err)
				// Close connection on write failure so subsequent operations fail properly
				c.Close()
				return
			}
		case <-c.done:
			return
		}
	}
}

// pingLoop sends periodic pings to keep the connection alive.
func (c *SignalingClient) pingLoop() {
	ticker := time.NewTicker(pingInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			_ = c.conn.SetWriteDeadline(time.Now().Add(writeTimeout))
			if err := c.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				slog.Warn("Failed to send ping", "error", err)
				return
			}
		case <-c.done:
			return
		}
	}
}

// tokenRefreshLoop periodically refreshes the token for long sessions.
// This matches the web client behavior of refreshing every 30 minutes.
func (c *SignalingClient) tokenRefreshLoop() {
	ticker := time.NewTicker(tokenRefreshInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			// Load token generator atomically
			genVal := c.tokenGenerator.Load()
			if genVal == nil {
				continue
			}
			gen := genVal.(func() (string, error))

			newToken, err := gen()
			if err != nil {
				slog.Warn("Failed to generate refresh token", "error", err)
				continue
			}

			// Create updated info with new token
			info := c.baseInfo
			info.Token = newToken

			if err := c.SendUpdate(info); err != nil {
				slog.Warn("Failed to send token refresh", "error", err)
			} else {
				slog.Debug("Token refreshed successfully")
			}
		case <-c.done:
			return
		}
	}
}

// SetTokenGenerator sets a function to generate new tokens for refresh.
// If set, the client will periodically refresh the token during long sessions.
// Thread-safe: uses atomic operations to prevent data races.
func (c *SignalingClient) SetTokenGenerator(gen func() (string, error)) {
	// Store generator atomically to prevent data race with tokenRefreshLoop
	if gen != nil {
		c.tokenGenerator.Store(gen)
	}

	// Only start ONE goroutine, even if SetTokenGenerator is called multiple times
	if gen != nil && !c.refreshStarted.Swap(true) {
		go c.tokenRefreshLoop()
	}
}

// handlePeerUpdate updates the peer list based on server messages.
func (c *SignalingClient) handlePeerUpdate(msg WsServerMessage) {
	c.peersMu.Lock()
	defer c.peersMu.Unlock()

	switch msg.Type {
	case "JOIN":
		if msg.Peer != nil {
			c.peers[msg.Peer.ID] = *msg.Peer
			slog.Info("Peer joined", "alias", msg.Peer.Alias, "id", msg.Peer.ID)
		}
	case "UPDATE":
		if msg.Peer != nil {
			c.peers[msg.Peer.ID] = *msg.Peer
		}
	case "LEFT":
		if msg.PeerID != nil {
			if peer, ok := c.peers[*msg.PeerID]; ok {
				slog.Info("Peer left", "alias", peer.Alias, "id", *msg.PeerID)
			}
			delete(c.peers, *msg.PeerID)
		}
	}
}

// Close closes the signaling connection.
// Clears all pending answer callbacks to prevent memory leaks.
func (c *SignalingClient) Close() error {
	var closeErr error
	c.closeOnce.Do(func() {
		close(c.done)

		// Clear pending answer callbacks to prevent memory leak
		c.answerMu.Lock()
		c.onAnswer = make(map[string]func(WsServerMessage))
		c.answerMu.Unlock()

		if c.conn != nil {
			closeErr = c.conn.Close()
		}
	})
	return closeErr
}

// ClientID returns our client ID assigned by the server.
func (c *SignalingClient) ClientID() uuid.UUID {
	return c.client.ID
}

// ClientInfo returns our client info.
func (c *SignalingClient) ClientInfo() ClientInfo {
	return c.client
}

// GetPeers returns a copy of all known peers.
func (c *SignalingClient) GetPeers() []ClientInfo {
	c.peersMu.RLock()
	defer c.peersMu.RUnlock()

	peers := make([]ClientInfo, 0, len(c.peers))
	for _, peer := range c.peers {
		peers = append(peers, peer)
	}
	return peers
}

// GetPeer returns a specific peer by ID.
func (c *SignalingClient) GetPeer(id uuid.UUID) (ClientInfo, bool) {
	c.peersMu.RLock()
	defer c.peersMu.RUnlock()
	peer, ok := c.peers[id]
	return peer, ok
}

// Messages returns a channel for receiving server messages.
func (c *SignalingClient) Messages() <-chan WsServerMessage {
	return c.msgChan
}

// SendUpdate sends an UPDATE message to the server.
func (c *SignalingClient) SendUpdate(info ClientInfoWithoutID) error {
	msg := NewUpdateMessage(info)
	select {
	case c.sendChan <- msg:
		return nil
	case <-c.done:
		return fmt.Errorf("connection closed")
	}
}

// SendOffer sends an OFFER message to a target peer.
func (c *SignalingClient) SendOffer(sessionID string, target uuid.UUID, sdp string) error {
	compressedSDP, err := CompressSDP(sdp)
	if err != nil {
		return fmt.Errorf("failed to compress SDP: %w", err)
	}

	msg := NewOfferMessage(sessionID, target, compressedSDP)
	select {
	case c.sendChan <- msg:
		return nil
	case <-c.done:
		return fmt.Errorf("connection closed")
	}
}

// SendAnswer sends an ANSWER message to a target peer.
func (c *SignalingClient) SendAnswer(sessionID string, target uuid.UUID, sdp string) error {
	compressedSDP, err := CompressSDP(sdp)
	if err != nil {
		return fmt.Errorf("failed to compress SDP: %w", err)
	}

	msg := NewAnswerMessage(sessionID, target, compressedSDP)
	select {
	case c.sendChan <- msg:
		return nil
	case <-c.done:
		return fmt.Errorf("connection closed")
	}
}

// OnAnswer registers a callback for when an ANSWER is received for a session.
func (c *SignalingClient) OnAnswer(sessionID string, callback func(WsServerMessage)) {
	c.answerMu.Lock()
	defer c.answerMu.Unlock()
	c.onAnswer[sessionID] = callback
}
