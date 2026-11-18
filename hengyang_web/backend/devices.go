package main

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

var imeiPattern = regexp.MustCompile(`^[0-9]{15}$`)
var fieldPattern = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_]{0,63}$`)

func validIMEI(value string) bool { return imeiPattern.MatchString(value) }

type model struct {
	ID       int64    `json:"id"`
	Name     string   `json:"name"`
	Fields   []string `json:"fields"`
	Commands []string `json:"commands"`
}

func validateModel(m *model) bool {
	m.Name = strings.TrimSpace(m.Name)
	if len(m.Name) == 0 || len(m.Name) > 100 || len(m.Fields) > 50 || len(m.Commands) > 50 {
		return false
	}
	if m.Fields == nil {
		m.Fields = []string{}
	}
	if m.Commands == nil {
		m.Commands = []string{}
	}
	for _, list := range [][]string{m.Fields, m.Commands} {
		seen := map[string]bool{}
		for _, item := range list {
			if !fieldPattern.MatchString(item) || seen[item] {
				return false
			}
			seen[item] = true
		}
	}
	return true
}

func (s *server) listModels(c *gin.Context) {
	rows, err := s.db.Query(`SELECT id, name, fields, commands FROM device_models ORDER BY name`)
	if err != nil {
		dbError(c, err)
		return
	}
	defer rows.Close()
	result := []model{}
	for rows.Next() {
		var m model
		var fields, commands []byte
		if err = rows.Scan(&m.ID, &m.Name, &fields, &commands); err != nil {
			dbError(c, err)
			return
		}
		if err = json.Unmarshal(fields, &m.Fields); err == nil {
			err = json.Unmarshal(commands, &m.Commands)
		}
		if err != nil {
			dbError(c, err)
			return
		}
		result = append(result, m)
	}
	if err = rows.Err(); err != nil {
		dbError(c, err)
		return
	}
	c.JSON(http.StatusOK, result)
}

func modelBody(c *gin.Context) (model, bool) {
	var m model
	if err := c.ShouldBindJSON(&m); err != nil || !validateModel(&m) {
		jsonError(c, http.StatusBadRequest, "型号名称或字段、命令配置无效")
		return model{}, false
	}
	return m, true
}

func (s *server) createModel(c *gin.Context) {
	m, ok := modelBody(c)
	if !ok {
		return
	}
	fields, _ := json.Marshal(m.Fields)
	commands, _ := json.Marshal(m.Commands)
	res, err := s.db.Exec(`INSERT INTO device_models (name, fields, commands) VALUES (?, ?, ?)`, m.Name, string(fields), string(commands))
	if err != nil {
		dbError(c, err)
		return
	}
	m.ID, err = res.LastInsertId()
	if err != nil {
		dbError(c, err)
		return
	}
	c.JSON(http.StatusCreated, m)
}

func (s *server) updateModel(c *gin.Context) {
	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil || id < 1 {
		jsonError(c, http.StatusBadRequest, "型号 ID 无效")
		return
	}
	m, ok := modelBody(c)
	if !ok {
		return
	}
	fields, _ := json.Marshal(m.Fields)
	commands, _ := json.Marshal(m.Commands)
	result, err := s.db.Exec(`UPDATE device_models SET name = ?, fields = ?, commands = ? WHERE id = ?`, m.Name, string(fields), string(commands), id)
	finishUpdate(c, result, err)
}

func (s *server) deleteModel(c *gin.Context) {
	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil || id < 1 {
		jsonError(c, http.StatusBadRequest, "型号 ID 无效")
		return
	}
	result, err := s.db.Exec(`DELETE FROM device_models WHERE id = ?`, id)
	finishUpdate(c, result, err)
}

type device struct {
	IMEI       string          `json:"imei"`
	Name       string          `json:"name"`
	ModelID    int64           `json:"model_id"`
	Status     json.RawMessage `json:"status"`
	ReceivedAt *time.Time      `json:"received_at"`
}

type commandRequest struct {
	Command   string `json:"command"`
	Volume    *int   `json:"volume"`
	SongIndex *int   `json:"song_index"`
}

func validateCommand(body commandRequest) string {
	if body.SongIndex != nil && (body.Command != "PLAY" || *body.SongIndex < 0 || *body.SongIndex >= 800) {
		return "曲目序号无效，仅播放命令接受 0 至 799 的曲目序号"
	}
	switch body.Command {
	case "PLAY", "PAUSE", "NEXT", "PREV", "ULTRASONIC_PLAY", "ULTRASONIC_STOP", "ULTRASONIC_SWEEP", "ULTRASONIC_FIXED":
		if body.Volume != nil {
			return "此命令不接受音量参数"
		}
	case "SET_VOLUME":
		if body.Volume == nil || *body.Volume < 0 || *body.Volume > 100 {
			return "音量必须为 0 至 100 的整数"
		}
	default:
		return "此命令尚未由固件支持"
	}
	return ""
}

func commandPayload(body commandRequest, id, imei string, timestamp int64) ([]byte, error) {
	params := gin.H{}
	if body.Volume != nil {
		params["volume"] = *body.Volume
	}
	if body.SongIndex != nil {
		params["song_index"] = *body.SongIndex
	}
	return json.Marshal(gin.H{"type": "command", "id": id, "imei": imei, "ts": timestamp, "cmd": body.Command, "params": params})
}

func (s *server) listDevices(c *gin.Context) {
	rows, err := s.db.Query(`SELECT imei, name, model_id, status, status_received_at FROM devices ORDER BY name, imei`)
	if err != nil {
		dbError(c, err)
		return
	}
	defer rows.Close()
	result := []device{}
	for rows.Next() {
		var d device
		var status []byte
		var received sql.NullTime
		if err = rows.Scan(&d.IMEI, &d.Name, &d.ModelID, &status, &received); err != nil {
			dbError(c, err)
			return
		}
		d.Status = status
		if received.Valid {
			d.ReceivedAt = &received.Time
		}
		result = append(result, d)
	}
	if err = rows.Err(); err != nil {
		dbError(c, err)
		return
	}
	c.JSON(http.StatusOK, result)
}

func deviceBody(c *gin.Context) (device, bool) {
	var d device
	if err := c.ShouldBindJSON(&d); err != nil {
		jsonError(c, http.StatusBadRequest, "设备数据无效")
		return d, false
	}
	d.Name = strings.TrimSpace(d.Name)
	if !validIMEI(d.IMEI) || d.Name == "" || len(d.Name) > 100 || d.ModelID < 1 {
		jsonError(c, http.StatusBadRequest, "IMEI 必须为 15 位数字，设备名称和型号不能为空")
		return d, false
	}
	return d, true
}

func (s *server) createDevice(c *gin.Context) {
	d, ok := deviceBody(c)
	if !ok {
		return
	}
	result, err := s.db.Exec(`INSERT INTO devices (imei, name, model_id) VALUES (?, ?, ?)`, d.IMEI, d.Name, d.ModelID)
	if err != nil {
		dbError(c, err)
		return
	}
	_ = result
	c.JSON(http.StatusCreated, d)
}

func (s *server) updateDevice(c *gin.Context) {
	oldIMEI := c.Param("imei")
	d, ok := deviceBody(c)
	if !ok {
		return
	}
	if !validIMEI(oldIMEI) {
		jsonError(c, http.StatusBadRequest, "IMEI 无效")
		return
	}
	result, err := s.db.Exec(`UPDATE devices SET status = IF(imei = ?, status, NULL), status_received_at = IF(imei = ?, status_received_at, NULL), imei = ?, name = ?, model_id = ? WHERE imei = ?`, d.IMEI, d.IMEI, d.IMEI, d.Name, d.ModelID, oldIMEI)
	finishUpdate(c, result, err)
}

func (s *server) deleteDevice(c *gin.Context) {
	if !validIMEI(c.Param("imei")) {
		jsonError(c, http.StatusBadRequest, "IMEI 无效")
		return
	}
	result, err := s.db.Exec(`DELETE FROM devices WHERE imei = ?`, c.Param("imei"))
	finishUpdate(c, result, err)
}

func finishUpdate(c *gin.Context, result sql.Result, err error) {
	if err != nil {
		dbError(c, err)
		return
	}
	count, err := result.RowsAffected()
	if err != nil {
		dbError(c, err)
		return
	}
	if count == 0 {
		jsonError(c, http.StatusNotFound, "记录不存在或没有变化")
		return
	}
	c.Status(http.StatusNoContent)
}

func (s *server) command(c *gin.Context) {
	imei := c.Param("imei")
	var body commandRequest
	if !validIMEI(imei) || c.ShouldBindJSON(&body) != nil {
		jsonError(c, http.StatusBadRequest, "设备或命令无效")
		return
	}
	if message := validateCommand(body); message != "" {
		jsonError(c, http.StatusBadRequest, message)
		return
	}
	var data []byte
	err := s.db.QueryRow(`SELECT m.commands FROM devices d JOIN device_models m ON d.model_id = m.id WHERE d.imei = ?`, imei).Scan(&data)
	if errors.Is(err, sql.ErrNoRows) {
		jsonError(c, http.StatusNotFound, "设备不存在")
		return
	}
	if err != nil {
		dbError(c, err)
		return
	}
	var commands []string
	if err = json.Unmarshal(data, &commands); err != nil {
		dbError(c, err)
		return
	}
	allowed := false
	for _, name := range commands {
		allowed = allowed || name == body.Command
	}
	if !allowed {
		jsonError(c, http.StatusForbidden, "此型号未配置该命令")
		return
	}
	if !s.mqtt.IsConnected() {
		jsonError(c, http.StatusServiceUnavailable, "MQTT 未连接")
		return
	}
	id := s.node.Generate().String()
	payload, err := commandPayload(body, id, imei, time.Now().Unix())
	if err != nil {
		jsonError(c, http.StatusInternalServerError, "无法编码命令")
		return
	}
	token := s.mqtt.Publish(fmt.Sprintf("aisms/%s/cmd", imei), 1, false, payload)
	if !token.WaitTimeout(10 * time.Second) {
		jsonError(c, http.StatusGatewayTimeout, "发送超时，无法确定命令是否已送达，请勿立即重复发送")
		return
	}
	if token.Error() != nil {
		jsonError(c, http.StatusBadGateway, "MQTT 发布失败")
		return
	}
	c.JSON(http.StatusAccepted, gin.H{"id": id, "status": "published", "message": "命令已发布"})
}

func (s *server) getSettings(c *gin.Context) {
	var latitude, longitude float64
	if err := s.db.QueryRow(`SELECT latitude, longitude FROM platform_settings WHERE id = 1`).Scan(&latitude, &longitude); err != nil {
		dbError(c, err)
		return
	}
	c.JSON(http.StatusOK, gin.H{"latitude": latitude, "longitude": longitude})
}

func (s *server) updateSettings(c *gin.Context) {
	var body struct {
		Latitude  *float64 `json:"latitude"`
		Longitude *float64 `json:"longitude"`
	}
	if c.ShouldBindJSON(&body) != nil || body.Latitude == nil || body.Longitude == nil || math.Abs(*body.Latitude) > 90 || math.Abs(*body.Longitude) > 180 {
		jsonError(c, http.StatusBadRequest, "经纬度无效")
		return
	}
	_, err := s.db.Exec(`UPDATE platform_settings SET latitude = ?, longitude = ? WHERE id = 1`, *body.Latitude, *body.Longitude)
	if err != nil {
		dbError(c, err)
		return
	}
	c.Status(http.StatusNoContent)
}
