// static/ergopti_plus/_shared/core/network/native/go/native_http/range_response_test.go
package nativehttp

import (
	"io"
	"net/http"
	"strings"
	"testing"
)

func rangeResponse(status int, contentRange, body string) *http.Response {
	header := make(http.Header)
	if contentRange != "" {
		header.Set("Content-Range", contentRange)
	}
	return &http.Response{StatusCode: status, Header: header, Body: io.NopCloser(strings.NewReader(body))}
}

func TestAlignRangeSkipsAFullResponseToThePartOffset(t *testing.T) {
	progress := 0
	response := rangeResponse(http.StatusOK, "", "0123456789")
	if err := AlignRange(response, 4, func() { progress++ }); err != nil {
		t.Fatal(err)
	}
	rest, err := io.ReadAll(response.Body)
	if err != nil || string(rest) != "456789" {
		t.Fatalf("a part must receive its own bytes, not the blob's head: %q, %v", rest, err)
	}
	if progress == 0 {
		t.Fatal("the skip must keep the stall watchdog fed")
	}
}

func TestAlignRangeKeepsTheBodyOfTheAskedRange(t *testing.T) {
	response := rangeResponse(http.StatusPartialContent, "bytes 4-9/10", "456789")
	if err := AlignRange(response, 4, func() {}); err != nil {
		t.Fatal(err)
	}
	if rest, _ := io.ReadAll(response.Body); string(rest) != "456789" {
		t.Fatalf("a served range is copied untouched: %q", rest)
	}
	if err := AlignRange(rangeResponse(http.StatusPartialContent, "bytes 4-9/*", ""), 4, func() {}); err != nil {
		t.Fatalf("an unknown total is a valid Content-Range: %v", err)
	}
}

func TestAlignRangeRefusesWhatWouldCorruptTheFile(t *testing.T) {
	for name, response := range map[string]*http.Response{
		"another offset":   rangeResponse(http.StatusPartialContent, "bytes 0-5/10", "012345"),
		"no content range": rangeResponse(http.StatusPartialContent, "", "456789"),
		"block page":       rangeResponse(http.StatusForbidden, "", "<html>blocked</html>"),
		"short full body":  rangeResponse(http.StatusOK, "", "012"),
	} {
		if err := AlignRange(response, 4, func() {}); err == nil {
			t.Fatalf("%s must be refused", name)
		}
	}
}
