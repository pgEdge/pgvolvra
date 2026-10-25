package main

import "testing"

// The checksum mode decides whether an upload is verified from the provider's
// own hash or by reading the object back. Getting it wrong for an endpoint is
// not a degradation: a server-side checksum travels as an aws-chunked trailing
// header, and a provider that does not implement that rejects the upload
// outright. So the defaulting is worth pinning down.
func TestResolveChecksum(t *testing.T) {
	cases := []struct {
		mode, endpoint, want string
	}{
		{"", "s3.us-east-1.amazonaws.com", checksumServer},
		{"auto", "s3.us-east-1.amazonaws.com", checksumServer},
		{"auto", "127.0.0.1:9000", checksumServer},

		// Google Cloud Storage's S3 interoperability endpoint does not accept
		// trailing-header checksums.
		{"auto", "storage.googleapis.com", checksumReadback},
		{"auto", "STORAGE.GOOGLEAPIS.COM", checksumReadback},
		{"auto", "storage.googleapis.com:443", checksumReadback},
		{"auto", "my-bucket.storage.googleapis.com", checksumReadback},

		// An explicit choice always wins over the default.
		{"server", "storage.googleapis.com", checksumServer},
		{"readback", "s3.amazonaws.com", checksumReadback},
	}
	for _, c := range cases {
		got, err := resolveChecksum(c.mode, c.endpoint)
		if err != nil {
			t.Errorf("resolveChecksum(%q, %q) returned %v", c.mode, c.endpoint, err)
			continue
		}
		if got != c.want {
			t.Errorf("resolveChecksum(%q, %q) = %q, want %q",
				c.mode, c.endpoint, got, c.want)
		}
	}

	if _, err := resolveChecksum("nonsense", "s3.amazonaws.com"); err == nil {
		t.Error("an unknown checksum mode must be rejected, not silently defaulted")
	}
}
