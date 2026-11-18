package main

import (
	"encoding/json"
	"testing"
)

func TestPlaylistMatchesPendingRequest(t *testing.T) {
	const imei = "123456789012345"
	reply := make(chan playlistReply, 1)
	p := playlistRequests{pending: map[string]playlistWaiter{
		imei: {id: "123", offset: 20, reply: reply},
	}}
	page := []byte(`{"type":"playlist_page","imei":"123456789012345","request_id":"123","data":{"offset":20,"total":21,"items":[{"index":20,"name":"曲目"}]}}`)
	if p.receive("000000000000000", page) ||
		p.receive(imei, []byte(`{"type":"playlist_page","imei":"123456789012345","request_id":"999"}`)) {
		t.Fatal("accepted mismatched device or request")
	}
	if !p.receive(imei, page) {
		t.Fatal("matching page was ignored")
	}
	if got := <-reply; got.page == nil || got.page.Items[0].Index != 20 {
		t.Fatalf("unexpected page: %+v", got)
	}
	if !p.receive(imei, []byte(`{"type":"playlist_page","imei":"123456789012345","request_id":"123","data":{"offset":20,"total":21,"items":[{"index":21,"name":"曲目"}]}}`)) ||
		(<-reply).page != nil {
		t.Fatal("malformed page did not return an error")
	}
	if !p.receive(imei, []byte(`{"msgType":"ack","imei":"123456789012345","msgId":"123","cmd":"GET_SONGS","result":"rejected"}`)) ||
		(<-reply).page != nil {
		t.Fatal("rejected request did not return an error")
	}
}

func TestPlaySongPayloadUsesZeroBasedIndex(t *testing.T) {
	zero := 0
	req := commandRequest{Command: "PLAY", SongIndex: &zero}
	if msg := validateCommand(req); msg != "" {
		t.Fatal(msg)
	}
	payload, err := commandPayload(req, "123", "123456789012345", 1000)
	if err != nil {
		t.Fatal(err)
	}
	var body struct{ Params map[string]int }
	if err := json.Unmarshal(payload, &body); err != nil {
		t.Fatal(err)
	}
	if index, exists := body.Params["song_index"]; !exists || index != 0 {
		t.Fatalf("incorrect payload: %s", payload)
	}
	req.Command = "PAUSE"
	if validateCommand(req) == "" {
		t.Fatal("PAUSE accepted song_index")
	}
}
