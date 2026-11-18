package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
)

const playlistPageSize = 20

type playlistItem struct {
	Index int    `json:"index"`
	Name  string `json:"name"`
}

type playlistPage struct {
	Offset int            `json:"offset"`
	Total  int            `json:"total"`
	Items  []playlistItem `json:"items"`
}

func (p playlistPage) valid(offset int) bool {
	if p.Offset != offset || p.Total < offset || p.Total > 800 || p.Items == nil ||
		len(p.Items) != min(playlistPageSize, p.Total-offset) {
		return false
	}
	for i, item := range p.Items {
		if item.Index != offset+i || len(item.Name) > 63 {
			return false
		}
	}
	return true
}

type playlistReply struct {
	page *playlistPage
}

type playlistWaiter struct {
	id     string
	offset int
	reply  chan playlistReply
}

type playlistRequests struct {
	mu      sync.Mutex
	pending map[string]playlistWaiter
}

func (p *playlistRequests) receive(imei string, payload []byte) bool {
	p.mu.Lock()
	waiter, exists := p.pending[imei]
	p.mu.Unlock()
	if !exists {
		return false
	}
	var response struct {
		Type    string        `json:"type"`
		MsgType string        `json:"msgType"`
		IMEI    string        `json:"imei"`
		ID      string        `json:"request_id"`
		MsgID   string        `json:"msgId"`
		Command string        `json:"cmd"`
		Result  string        `json:"result"`
		Data    *playlistPage `json:"data"`
	}
	if json.Unmarshal(payload, &response) != nil || response.IMEI != imei {
		return false
	}
	reply := playlistReply{}
	switch {
	case response.Type == "playlist_page" && response.ID == waiter.id:
		if response.Data != nil && response.Data.valid(waiter.offset) {
			reply.page = response.Data
		}
	case response.MsgType == "ack" && response.MsgID == waiter.id && response.Command == "GET_SONGS" &&
		(response.Result == "rejected" || response.Result == "failed"):
	default:
		return false
	}
	select {
	case waiter.reply <- reply:
	default:
	}
	return true
}

func (s *server) getPlaylist(c *gin.Context) {
	imei := c.Param("imei")
	var request struct {
		Offset *int `json:"offset"`
	}
	if !validIMEI(imei) || c.ShouldBindJSON(&request) != nil || request.Offset == nil ||
		*request.Offset < 0 || *request.Offset > 800 {
		jsonError(c, http.StatusBadRequest, "设备或歌单页无效")
		return
	}
	ctx, cancel := context.WithTimeout(c.Request.Context(), 15*time.Second)
	defer cancel()
	var raw []byte
	err := s.db.QueryRowContext(ctx, `SELECT m.commands FROM devices d JOIN device_models m ON d.model_id = m.id WHERE d.imei = ?`, imei).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		jsonError(c, http.StatusNotFound, "设备不存在")
		return
	}
	var commands []string
	if err == nil {
		err = json.Unmarshal(raw, &commands)
	}
	if err != nil {
		dbError(c, err)
		return
	}
	allowed := false
	for _, command := range commands {
		allowed = allowed || command == "PLAY"
	}
	if !allowed {
		jsonError(c, http.StatusForbidden, "此型号未配置播放命令")
		return
	}
	if !s.mqtt.IsConnected() {
		jsonError(c, http.StatusServiceUnavailable, "MQTT 未连接")
		return
	}
	p := &s.playlists
	waiter := playlistWaiter{s.node.Generate().String(), *request.Offset, make(chan playlistReply, 1)}
	p.mu.Lock()
	if _, exists := p.pending[imei]; exists || len(p.pending) >= 128 {
		p.mu.Unlock()
		jsonError(c, http.StatusTooManyRequests, "歌单请求繁忙，请稍后重试")
		return
	}
	if p.pending == nil {
		p.pending = make(map[string]playlistWaiter)
	}
	p.pending[imei] = waiter
	p.mu.Unlock()
	defer func() {
		p.mu.Lock()
		delete(p.pending, imei)
		p.mu.Unlock()
	}()
	payload, err := json.Marshal(gin.H{"type": "command", "id": waiter.id, "imei": imei,
		"ts": time.Now().Unix(), "cmd": "GET_SONGS",
		"params": gin.H{"offset": waiter.offset, "limit": playlistPageSize}})
	if err != nil {
		jsonError(c, http.StatusInternalServerError, "无法编码歌单请求")
		return
	}
	token := s.mqtt.Publish(fmt.Sprintf("aisms/%s/cmd", imei), 1, false, payload)
	select {
	case <-token.Done():
		if token.Error() != nil {
			jsonError(c, http.StatusBadGateway, "歌单请求发布失败")
			return
		}
	case <-ctx.Done():
		jsonError(c, http.StatusGatewayTimeout, "歌单请求发布超时")
		return
	}
	select {
	case reply := <-waiter.reply:
		if reply.page == nil {
			jsonError(c, http.StatusBadGateway, "设备无法返回此页歌单，请从第一页重新获取并检查设备固件")
			return
		}
		c.JSON(http.StatusOK, reply.page)
	case <-ctx.Done():
		jsonError(c, http.StatusGatewayTimeout, "设备未返回歌单，请检查连接和固件")
	}
}
