package main

import (
	"encoding/json"
	"testing"
)

func TestValidIMEI(t *testing.T) {
	for _, tc := range []struct {
		value string
		valid bool
	}{
		{"012345678901234", true},
		{"123", false},
		{"01234567890123a", false},
		{"0123456789012345", false},
	} {
		if got := validIMEI(tc.value); got != tc.valid {
			t.Errorf("validIMEI(%q) = %v", tc.value, got)
		}
	}
}

func TestValidateModel(t *testing.T) {
	good := model{Name: " player ", Fields: []string{"playing", "trackName"}, Commands: []string{"PLAY", "PAUSE"}}
	if !validateModel(&good) || good.Name != "player" {
		t.Fatal("valid model rejected")
	}
	for _, bad := range []model{
		{Name: ""},
		{Name: "x", Fields: []string{"bad field"}},
		{Name: "x", Commands: []string{"PLAY", "PLAY"}},
	} {
		if validateModel(&bad) {
			t.Errorf("invalid model accepted: %+v", bad)
		}
	}
}

func TestValidateCommand(t *testing.T) {
	zero, max, negative, over := 0, 100, -1, 101
	for _, tc := range []struct {
		request commandRequest
		valid   bool
	}{
		{commandRequest{Command: "PLAY"}, true},
		{commandRequest{Command: "PLAY", Volume: &zero}, false},
		{commandRequest{Command: "ULTRASONIC_PLAY"}, true},
		{commandRequest{Command: "ULTRASONIC_STOP"}, true},
		{commandRequest{Command: "ULTRASONIC_SWEEP"}, true},
		{commandRequest{Command: "ULTRASONIC_FIXED"}, true},
		{commandRequest{Command: "ULTRASONIC_PLAY", Volume: &zero}, false},
		{commandRequest{Command: "SET_VOLUME", Volume: &zero}, true},
		{commandRequest{Command: "SET_VOLUME", Volume: &max}, true},
		{commandRequest{Command: "SET_VOLUME"}, false},
		{commandRequest{Command: "SET_VOLUME", Volume: &negative}, false},
		{commandRequest{Command: "SET_VOLUME", Volume: &over}, false},
		{commandRequest{Command: "UNKNOWN"}, false},
	} {
		if got := validateCommand(tc.request) == ""; got != tc.valid {
			t.Errorf("validateCommand(%+v) valid = %v", tc.request, got)
		}
	}
}

func TestVolumeCommandPayload(t *testing.T) {
	volume := 37
	payload, err := commandPayload(commandRequest{Command: "SET_VOLUME", Volume: &volume}, "123", "123456789012345", 1000)
	if err != nil {
		t.Fatal(err)
	}
	var result struct {
		Type   string `json:"type"`
		ID     string `json:"id"`
		IMEI   string `json:"imei"`
		TS     int64  `json:"ts"`
		Cmd    string `json:"cmd"`
		Params struct {
			Volume int `json:"volume"`
		} `json:"params"`
	}
	if err := json.Unmarshal(payload, &result); err != nil {
		t.Fatal(err)
	}
	if result.Type != "command" || result.ID != "123" || result.IMEI != "123456789012345" ||
		result.TS != 1000 || result.Cmd != "SET_VOLUME" || result.Params.Volume != volume {
		t.Fatalf("unexpected payload: %s", payload)
	}
}
