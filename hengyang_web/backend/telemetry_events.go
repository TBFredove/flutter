package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
)

type telemetryHub struct {
	mu          sync.Mutex
	subscribers map[chan struct{}]struct{}
}

func (h *telemetryHub) subscribe() chan struct{} {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.subscribers == nil {
		h.subscribers = make(map[chan struct{}]struct{})
	}
	ch := make(chan struct{}, 1)
	h.subscribers[ch] = struct{}{}
	return ch
}

func (h *telemetryHub) unsubscribe(ch chan struct{}) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.subscribers, ch)
}

func (h *telemetryHub) publish() {
	h.mu.Lock()
	defer h.mu.Unlock()
	for ch := range h.subscribers {
		select {
		case ch <- struct{}{}:
		default:
		}
	}
}

func (s *server) telemetryEvents(c *gin.Context) {
	flusher, ok := c.Writer.(http.Flusher)
	if !ok {
		jsonError(c, http.StatusInternalServerError, "无法建立遥测连接")
		return
	}
	token, err := c.Cookie("hengyang_session")
	if err != nil {
		jsonError(c, http.StatusUnauthorized, "请先登录")
		return
	}
	updates := s.events.subscribe()
	defer s.events.unsubscribe(updates)
	c.Header("Content-Type", "text/event-stream")
	c.Header("X-Accel-Buffering", "no")
	c.Header("Cache-Control", "no-store")
	c.Status(http.StatusOK)
	if _, err = fmt.Fprint(c.Writer, "retry: 3000\n: connected\n\n"); err != nil {
		return
	}
	flusher.Flush()
	ticker := time.NewTicker(20 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-c.Request.Context().Done():
			return
		case <-updates:
			if _, err := fmt.Fprint(c.Writer, "data: changed\n\n"); err != nil {
				return
			}
			flusher.Flush()
		case <-ticker.C:
			ctx, cancel := context.WithTimeout(c.Request.Context(), 5*time.Second)
			var valid int
			err := s.db.QueryRowContext(ctx, `SELECT 1 FROM platform_sessions s JOIN platform_users u ON u.id = s.user_id WHERE s.token_hash = ? AND s.expires_at > UTC_TIMESTAMP() AND u.must_change = FALSE`, tokenHash(token)).Scan(&valid)
			cancel()
			if err != nil {
				if !errors.Is(err, sql.ErrNoRows) {
					log.Printf("Checking telemetry session: %v", err)
				}
				return
			}
			if _, err := fmt.Fprint(c.Writer, ": heartbeat\n\n"); err != nil {
				return
			}
			flusher.Flush()
		}
	}
}
