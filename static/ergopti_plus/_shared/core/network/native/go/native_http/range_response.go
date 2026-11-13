// static/ergopti_plus/_shared/core/network/native/go/native_http/range_response.go
package nativehttp

import (
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strconv"
)

var contentRangeStart = regexp.MustCompile(`^bytes (\d+)-\d+/(?:\d+|\*)$`)

// keepAliveWriter reports progress for bytes nobody stores, so the caller's
// stall watchdog does not read a long skip as a dead connection.
type keepAliveWriter struct{ progress func() }

func (w keepAliveWriter) Write(data []byte) (int, error) {
	w.progress()
	return len(data), nil
}

// AlignRange leaves a blob part's response body at the byte the part asked for.
// Upstream copies the body at the part's offset whatever the status was: a relay
// that ignores Range answers 200 with the whole blob, so every part received the
// blob's head, the file had the right size and each pull ended on a digest
// mismatch (field reports of 2026-11-01 and 2026-11-02, behind a PAC). A 200 is
// skipped to the offset; any other answer is refused before it reaches the file.
func AlignRange(response *http.Response, start int64, progress func()) error {
	switch response.StatusCode {
	case http.StatusPartialContent:
		match := contentRangeStart.FindStringSubmatch(response.Header.Get("Content-Range"))
		if match == nil {
			return fmt.Errorf("partial response without a usable Content-Range")
		}
		served, err := strconv.ParseInt(match[1], 10, 64)
		if err != nil || served != start {
			return fmt.Errorf("partial response starts at %s, not at %d", match[1], start)
		}
		return nil
	case http.StatusOK:
		if _, err := io.CopyN(keepAliveWriter{progress}, response.Body, start); err != nil {
			return fmt.Errorf("skipping to offset %d of a full response: %w", start, err)
		}
		return nil
	}
	return fmt.Errorf("unexpected status %d for a blob range", response.StatusCode)
}
