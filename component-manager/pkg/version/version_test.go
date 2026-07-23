package version

import (
	"encoding/json"
	"testing"
)

func TestSemVerPrecedence(t *testing.T) {
	order := []string{
		"1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
		"1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0",
	}
	for i := 0; i < len(order)-1; i++ {
		a, err := ParseSoftwareVersion(order[i], 0)
		if err != nil {
			t.Fatal(err)
		}
		b, err := ParseSoftwareVersion(order[i+1], 0)
		if err != nil {
			t.Fatal(err)
		}
		if a.Compare(b) >= 0 {
			t.Fatalf("%s must precede %s", order[i], order[i+1])
		}
	}
}

func TestBuildMetadataDoesNotAffectPrecedence(t *testing.T) {
	a, _ := ParseSoftwareVersion("1.2.3+one", 0)
	b, _ := ParseSoftwareVersion("1.2.3+two", 0)
	if a.Compare(b) != 0 || a.String() == b.String() {
		t.Fatal("build metadata precedence or representation incorrect")
	}
}

func TestPackageRevisionBreaksTies(t *testing.T) {
	a, _ := ParseSoftwareVersion("1.2.3", 1)
	b, _ := ParseSoftwareVersion("1.2.3", 2)
	if a.Compare(b) >= 0 {
		t.Fatal("package revision did not break tie")
	}
}

func TestSoftwareVersionRejectsInvalid(t *testing.T) {
	for _, value := range []string{"", "1", "1.2", "01.2.3", "1.2.3-", "v1.2.3", "1.2.3-01"} {
		if _, err := ParseSoftwareVersion(value, 0); err == nil {
			t.Fatalf("accepted %q", value)
		}
	}
	if _, err := ParseSoftwareVersion("1.2.3", -1); err == nil {
		t.Fatal("accepted negative package revision")
	}
}

func TestSoftwareVersionJSONRoundTrip(t *testing.T) {
	want, _ := ParseSoftwareVersion("1.2.3-rc.1+build.7", 4)
	data, _ := json.Marshal(want)
	var got SoftwareVersion
	if err := json.Unmarshal(data, &got); err != nil || got != want {
		t.Fatalf("JSON round trip: %v, %#v", err, got)
	}
}

func TestModelRevisionIsOpaqueAndCaseSensitive(t *testing.T) {
	a, err := ParseModelRevision("Publisher-Rev_A")
	if err != nil || a.String() != "Publisher-Rev_A" {
		t.Fatalf("parse: %v", err)
	}
	b, _ := ParseModelRevision("publisher-rev_a")
	if a == b {
		t.Fatal("model revisions were normalized")
	}
	for _, bad := range []string{"", " rev", "rev ", "rev\n2"} {
		if _, err := ParseModelRevision(bad); err == nil {
			t.Fatalf("accepted %q", bad)
		}
	}
}
