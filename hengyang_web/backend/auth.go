package main

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"golang.org/x/crypto/bcrypt"
)

var loginAttempts struct {
	sync.Mutex
	start time.Time
	count int
}

func (s *server) login(c *gin.Context) {
	loginAttempts.Lock()
	if time.Since(loginAttempts.start) >= time.Minute {
		loginAttempts.start, loginAttempts.count = time.Now(), 0
	}
	loginAttempts.count++
	limited := loginAttempts.count > 10
	loginAttempts.Unlock()
	if limited {
		jsonError(c, http.StatusTooManyRequests, "登录尝试过多，请稍后再试")
		return
	}
	var body struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := c.ShouldBindJSON(&body); err != nil || len(body.Username) > 64 || len(body.Password) > 72 {
		jsonError(c, http.StatusBadRequest, "账号或密码格式错误")
		return
	}
	var id int64
	var hash string
	var mustChange bool
	err := s.db.QueryRow(`SELECT id, password_hash, must_change FROM platform_users WHERE username = ?`, body.Username).Scan(&id, &hash, &mustChange)
	if errors.Is(err, sql.ErrNoRows) {
		jsonError(c, http.StatusUnauthorized, "账号或密码错误")
		return
	}
	if err != nil {
		dbError(c, err)
		return
	}
	if bcrypt.CompareHashAndPassword([]byte(hash), []byte(body.Password)) != nil {
		jsonError(c, http.StatusUnauthorized, "账号或密码错误")
		return
	}
	random := make([]byte, 32)
	if _, err := rand.Read(random); err != nil {
		log.Printf("session random source: %v", err)
		jsonError(c, http.StatusInternalServerError, "无法创建登录会话")
		return
	}
	token := hex.EncodeToString(random)
	if _, err := s.db.Exec(`DELETE FROM platform_sessions WHERE expires_at <= UTC_TIMESTAMP()`); err != nil {
		dbError(c, err)
		return
	}
	if _, err := s.db.Exec(`INSERT INTO platform_sessions (token_hash, user_id, expires_at) VALUES (?, ?, DATE_ADD(UTC_TIMESTAMP(), INTERVAL 12 HOUR))`, tokenHash(token), id); err != nil {
		dbError(c, err)
		return
	}
	http.SetCookie(c.Writer, &http.Cookie{Name: "hengyang_session", Value: token, Path: "/", MaxAge: 12 * 60 * 60, Secure: true, HttpOnly: true, SameSite: http.SameSiteStrictMode})
	c.JSON(http.StatusOK, gin.H{"username": body.Username, "must_change": mustChange})
}

func (s *server) auth(c *gin.Context) {
	token, err := c.Cookie("hengyang_session")
	if err != nil || len(token) != 64 {
		jsonError(c, http.StatusUnauthorized, "请先登录")
		return
	}
	var id int64
	var username string
	var mustChange bool
	err = s.db.QueryRow(`SELECT u.id, u.username, u.must_change FROM platform_sessions s JOIN platform_users u ON u.id = s.user_id WHERE s.token_hash = ? AND s.expires_at > UTC_TIMESTAMP()`, tokenHash(token)).Scan(&id, &username, &mustChange)
	if errors.Is(err, sql.ErrNoRows) {
		jsonError(c, http.StatusUnauthorized, "登录已过期")
		return
	}
	if err != nil {
		dbError(c, err)
		return
	}
	c.Set("user_id", id)
	c.Set("username", username)
	c.Set("must_change", mustChange)
	c.Next()
}

func (s *server) passwordChanged(c *gin.Context) {
	if c.GetBool("must_change") {
		jsonError(c, http.StatusForbidden, "请先修改初始密码")
		return
	}
	c.Next()
}

func (s *server) session(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"username": c.GetString("username"), "must_change": c.GetBool("must_change")})
}

func (s *server) logout(c *gin.Context) {
	token, _ := c.Cookie("hengyang_session")
	if _, err := s.db.Exec(`DELETE FROM platform_sessions WHERE token_hash = ?`, tokenHash(token)); err != nil {
		dbError(c, err)
		return
	}
	http.SetCookie(c.Writer, &http.Cookie{Name: "hengyang_session", Path: "/", MaxAge: -1, Secure: true, HttpOnly: true, SameSite: http.SameSiteStrictMode})
	c.Status(http.StatusNoContent)
}

func (s *server) changePassword(c *gin.Context) {
	var body struct {
		Current string `json:"current"`
		New     string `json:"new"`
	}
	if err := c.ShouldBindJSON(&body); err != nil || len(body.New) < 10 || len(body.New) > 72 || strings.TrimSpace(body.New) != body.New || body.New == "admin" {
		jsonError(c, http.StatusBadRequest, "新密码需要 10 至 72 字节，且首尾不能有空格")
		return
	}
	id := c.GetInt64("user_id")
	var oldHash string
	if err := s.db.QueryRow(`SELECT password_hash FROM platform_users WHERE id = ?`, id).Scan(&oldHash); err != nil {
		dbError(c, err)
		return
	}
	if bcrypt.CompareHashAndPassword([]byte(oldHash), []byte(body.Current)) != nil {
		jsonError(c, http.StatusUnauthorized, "当前密码不正确")
		return
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(body.New), bcrypt.DefaultCost)
	if err != nil {
		jsonError(c, http.StatusInternalServerError, "无法更新密码")
		return
	}
	tx, err := s.db.Begin()
	if err != nil {
		dbError(c, err)
		return
	}
	defer tx.Rollback()
	if _, err = tx.Exec(`UPDATE platform_users SET password_hash = ?, must_change = FALSE WHERE id = ?`, string(hash), id); err != nil {
		dbError(c, err)
		return
	}
	token, _ := c.Cookie("hengyang_session")
	if _, err = tx.Exec(`DELETE FROM platform_sessions WHERE user_id = ? AND token_hash <> ?`, id, tokenHash(token)); err != nil {
		dbError(c, err)
		return
	}
	if err = tx.Commit(); err != nil {
		dbError(c, err)
		return
	}
	c.Status(http.StatusNoContent)
}
