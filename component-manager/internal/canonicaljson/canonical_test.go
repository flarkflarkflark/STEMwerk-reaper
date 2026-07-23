package canonicaljson

import (
	"bytes"
	"testing"
)

func TestRFC8785Vectors(t *testing.T) {
	tests := []struct{ input, want string }{
		{`{"numbers":[333333333.33333329,1E30,4.50,2e-3,0.000000000000000000000000001]}`, `{"numbers":[333333333.3333333,1e+30,4.5,0.002,1e-27]}`},
		{`{"string":"€$\u000f\nA'B\"\\\"/"}`, `{"string":"€$\u000f\nA'B\"\\\"/"}`},
		{`{"literals":[null,true,false],"z":0,"a":{"b":2,"a":1}}`, `{"a":{"a":1,"b":2},"literals":[null,true,false],"z":0}`},
	}
	for _, tc := range tests {
		got, err := Canonicalize([]byte(tc.input))
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != tc.want {
			t.Fatalf("got %s want %s", got, tc.want)
		}
		for i := 0; i < 100; i++ {
			again, err := Canonicalize([]byte(tc.input))
			if err != nil || !bytes.Equal(got, again) {
				t.Fatal("non-deterministic result")
			}
		}
	}
}

func FuzzCanonicalize(f *testing.F) {
	f.Add([]byte(`{"b":2,"a":1}`))
	f.Fuzz(func(t *testing.T, data []byte) {
		first, e1 := Canonicalize(data)
		second, e2 := Canonicalize(data)
		if (e1 == nil) != (e2 == nil) || !bytes.Equal(first, second) {
			t.Fatal("non-deterministic")
		}
	})
}
