package main

import (
	"bufio"
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
)

func TestTelemetryHubCoalescesAndUnsubscribes(t *testing.T) {
	var hub telemetryHub
	first, second := hub.subscribe(), hub.subscribe()
	hub.publish()
	hub.publish()
	if len(first) != 1 || len(second) != 1 {
		t.Fatal("notifications must reach each subscriber and coalesce")
	}
	<-first
	hub.unsubscribe(first)
	hub.publish()
	if len(first) != 0 || len(second) != 1 {
		t.Fatal("unsubscribed channel received an update")
	}
	hub.unsubscribe(second)
}

func TestTelemetryEventsFlushAndDisconnect(t *testing.T) {
	gin.SetMode(gin.TestMode)
	var s server
	router := gin.New()
	router.GET("/events", s.telemetryEvents)
	server := httptest.NewServer(router)
	defer server.Close()
	ctx, cancel := context.WithCancel(context.Background())
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, server.URL+"/events", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.AddCookie(&http.Cookie{Name: "hengyang_session", Value: "test"})
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK || resp.Header.Get("X-Accel-Buffering") != "no" || !strings.HasPrefix(resp.Header.Get("Content-Type"), "text/event-stream") {
		t.Fatalf("unexpected response: %s %v", resp.Status, resp.Header)
	}
	reader := bufio.NewReader(resp.Body)
	for i := 0; i < 3; i++ {
		if _, err := reader.ReadString('\n'); err != nil {
			t.Fatal(err)
		}
	}
	s.events.publish()
	line, err := reader.ReadString('\n')
	if err != nil || line != "data: changed\n" {
		t.Fatalf("notification: %q, %v", line, err)
	}
	cancel()
	deadline := time.Now().Add(time.Second)
	for {
		s.events.mu.Lock()
		n := len(s.events.subscribers)
		s.events.mu.Unlock()
		if n == 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("subscription not removed after disconnect")
		}
		time.Sleep(time.Millisecond)
	}
}

func TestTelemetryHubConcurrentSubscribers(t *testing.T) {
	var hub telemetryHub
	var wg sync.WaitGroup
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 100; j++ {
				ch := hub.subscribe()
				hub.publish()
				hub.unsubscribe(ch)
			}
		}()
	}
	wg.Wait()
}
