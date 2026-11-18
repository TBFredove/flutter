package main

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/bwmarrin/snowflake"
	mqtt "github.com/eclipse/paho.mqtt.golang"
	"github.com/gin-gonic/gin"
	"github.com/go-sql-driver/mysql"
	_ "github.com/lib/pq"
	"golang.org/x/crypto/bcrypt"
)

type server struct {
	db        *sql.DB
	mqtt      mqtt.Client
	node      *snowflake.Node
	origin    string
	events    telemetryHub
	playlists playlistRequests
}

func main() {
	cfg := mysql.NewConfig()
	cfg.User, cfg.Passwd = os.Getenv("MYSQL_USER"), os.Getenv("MYSQL_PASSWORD")
	cfg.Net, cfg.Addr, cfg.DBName = "tcp", os.Getenv("MYSQL_HOST"), os.Getenv("MYSQL_DATABASE")
	cfg.ParseTime, cfg.Loc = true, time.UTC
	cfg.ClientFoundRows = true
	cfg.Params = map[string]string{"charset": "utf8mb4"}
	db, err := sql.Open("mysql", cfg.FormatDSN())
	if err != nil {
		log.Fatalf("MySQL configuration: %v", err)
	}
	defer db.Close()
	if err = db.Ping(); err != nil {
		log.Fatalf("MySQL connection: %v", err)
	}
	if err = initialize(db); err != nil {
		log.Fatalf("MySQL initialization: %v", err)
	}
	log.Println("[OK] MySQL connected")

	pgURL := url.URL{Scheme: "postgres", User: url.UserPassword(os.Getenv("PG_USER"), os.Getenv("PG_PASSWORD")), Host: os.Getenv("PG_HOST"), Path: "/" + os.Getenv("PG_DATABASE")}
	query := pgURL.Query()
	query.Set("sslmode", "disable")
	pgURL.RawQuery = query.Encode()
	pg, err := sql.Open("postgres", pgURL.String())
	if err != nil {
		log.Fatalf("PostgreSQL configuration: %v", err)
	}
	defer pg.Close()
	if err = pg.Ping(); err != nil {
		log.Fatalf("PostgreSQL connection: %v", err)
	}
	log.Println("[OK] PostgreSQL connected")

	node, err := snowflake.NewNode(1)
	if err != nil {
		log.Fatal(err)
	}
	s := &server{db: db, node: node, origin: os.Getenv("PUBLIC_ORIGIN")}
	if s.origin == "" {
		log.Fatal("PUBLIC_ORIGIN must be configured")
	}
	broker := os.Getenv("MQTT_BROKER")
	if broker == "" {
		log.Fatal("MQTT_BROKER must be configured")
	}
	opts := mqtt.NewClientOptions().AddBroker(broker).
		SetClientID(fmt.Sprintf("hengyang-backend-%d", time.Now().UnixNano())).
		SetAutoReconnect(true).SetConnectRetry(true).
		SetConnectRetryInterval(5 * time.Second).
		SetOnConnectHandler(func(c mqtt.Client) {
			token := c.Subscribe("aisms/+/status", 1, s.receiveStatus)
			if !token.WaitTimeout(10*time.Second) || token.Error() != nil {
				log.Printf("MQTT subscribe failed: %v", token.Error())
			} else {
				log.Print("[OK] MQTT connected and subscribed")
			}
		})
	s.mqtt = mqtt.NewClient(opts)
	s.mqtt.Connect()
	gin.SetMode(gin.ReleaseMode)
	router := gin.Default()
	if err := router.SetTrustedProxies(nil); err != nil {
		log.Fatal(err)
	}
	router.Use(func(c *gin.Context) {
		c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, 64*1024)
		c.Header("Cache-Control", "no-store")
		c.Next()
	})
	router.GET("/api/v1/health", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"status": "ok", "service": "hengyang-backend", "mqtt_alive": s.mqtt.IsConnected(), "timestamp": time.Now().Unix()})
	})
	api := router.Group("/api/v1")
	api.POST("/login", s.checkOrigin, s.login)
	api.POST("/logout", s.checkOrigin, s.auth, s.logout)
	api.GET("/session", s.auth, s.session)
	api.POST("/password", s.checkOrigin, s.auth, s.changePassword)
	secure := api.Group("")
	secure.Use(s.auth, s.passwordChanged, s.checkOrigin)
	secure.GET("/models", s.listModels)
	secure.POST("/models", s.createModel)
	secure.PUT("/models/:id", s.updateModel)
	secure.DELETE("/models/:id", s.deleteModel)
	secure.GET("/devices", s.listDevices)
	secure.GET("/telemetry/events", s.telemetryEvents)
	secure.POST("/devices", s.createDevice)
	secure.PUT("/devices/:imei", s.updateDevice)
	secure.DELETE("/devices/:imei", s.deleteDevice)
	secure.POST("/devices/:imei/commands", s.command)
	secure.POST("/devices/:imei/playlist", s.getPlaylist)
	secure.GET("/settings", s.getSettings)
	secure.PUT("/settings", s.updateSettings)
	log.Print("Backend listening on :8000")
	if err := router.Run(":8000"); err != nil {
		log.Fatal(err)
	}
}

func initialize(db *sql.DB) error {
	statements := []string{
		`CREATE TABLE IF NOT EXISTS platform_users (id BIGINT PRIMARY KEY AUTO_INCREMENT, username VARCHAR(64) NOT NULL UNIQUE, password_hash VARCHAR(100) NOT NULL, must_change BOOLEAN NOT NULL DEFAULT TRUE)`,
		`CREATE TABLE IF NOT EXISTS platform_sessions (token_hash CHAR(64) PRIMARY KEY, user_id BIGINT NOT NULL, expires_at DATETIME NOT NULL, FOREIGN KEY (user_id) REFERENCES platform_users(id) ON DELETE CASCADE)`,
		`CREATE TABLE IF NOT EXISTS device_models (id BIGINT PRIMARY KEY AUTO_INCREMENT, name VARCHAR(100) NOT NULL UNIQUE, fields JSON NOT NULL, commands JSON NOT NULL)`,
		`CREATE TABLE IF NOT EXISTS devices (imei CHAR(15) PRIMARY KEY, name VARCHAR(100) NOT NULL, model_id BIGINT NOT NULL, status JSON NULL, status_received_at DATETIME NULL, FOREIGN KEY (model_id) REFERENCES device_models(id))`,
		`CREATE TABLE IF NOT EXISTS platform_settings (id TINYINT PRIMARY KEY, latitude DOUBLE NOT NULL, longitude DOUBLE NOT NULL)`,
	}
	for _, stmt := range statements {
		if _, err := db.Exec(stmt); err != nil {
			return err
		}
	}
	hash, err := bcrypt.GenerateFromPassword([]byte("admin"), bcrypt.DefaultCost)
	if err != nil {
		return err
	}
	if _, err = db.Exec(`INSERT INTO platform_users (username, password_hash, must_change) VALUES ('admin', ?, TRUE) ON DUPLICATE KEY UPDATE username = username`, string(hash)); err != nil {
		return err
	}
	_, err = db.Exec(`INSERT INTO platform_settings (id, latitude, longitude) VALUES (1, 37.76, 117.58) ON DUPLICATE KEY UPDATE id = id`)
	return err
}

func jsonError(c *gin.Context, code int, message string) {
	c.AbortWithStatusJSON(code, gin.H{"error": message})
}

func dbError(c *gin.Context, err error) {
	log.Printf("database request: %v", err)
	var mysqlErr *mysql.MySQLError
	if errors.As(err, &mysqlErr) && (mysqlErr.Number == 1062 || mysqlErr.Number == 1451 || mysqlErr.Number == 1452) {
		jsonError(c, http.StatusConflict, "数据已存在、仍被引用或关联对象不存在")
		return
	}
	jsonError(c, http.StatusInternalServerError, "数据库操作失败")
}

func (s *server) checkOrigin(c *gin.Context) {
	if c.Request.Method != http.MethodGet && c.GetHeader("Origin") != s.origin {
		jsonError(c, http.StatusForbidden, "请求来源不被允许")
		return
	}
	c.Next()
}

func tokenHash(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

func (s *server) receiveStatus(_ mqtt.Client, msg mqtt.Message) {
	parts := strings.Split(msg.Topic(), "/")
	if len(parts) != 3 || !validIMEI(parts[1]) || len(msg.Payload()) > 16384 {
		return
	}
	if s.playlists.receive(parts[1], msg.Payload()) || len(msg.Payload()) > 4096 {
		return
	}
	var data map[string]json.RawMessage
	if json.Unmarshal(msg.Payload(), &data) != nil {
		log.Printf("Invalid status JSON for %s", parts[1])
		return
	}
	var imei, kind string
	if json.Unmarshal(data["imei"], &imei) != nil || imei != parts[1] || json.Unmarshal(data["msgType"], &kind) != nil {
		return
	}
	if kind != "telemetry" && kind != "online" && kind != "offline" {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if kind == "telemetry" {
		result, err := s.db.ExecContext(ctx, `UPDATE devices SET status = ?, status_received_at = UTC_TIMESTAMP() WHERE imei = ?`, string(msg.Payload()), imei)
		if err != nil {
			log.Printf("Saving telemetry for %s: %v", imei, err)
			return
		}
		count, err := result.RowsAffected()
		if err != nil {
			log.Printf("Checking telemetry update for %s: %v", imei, err)
			return
		}
		if count > 0 {
			s.events.publish()
		}
	}
}
