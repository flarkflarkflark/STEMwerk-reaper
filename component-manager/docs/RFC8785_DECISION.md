# RFC 8785 decision

Selected: `github.com/gowebpki/jcs@v1.0.1`, Apache-2.0. The wrapper is bounded to 4 MiB and writes no state. Tests cover the RFC 8785 number sample, escaping/Unicode, nested member ordering, literals, and 100 deterministic repetitions per vector.

Bounded candidates: gowebpki/jcs (selected reviewed Go module); the Cyberphone reference Go tree (rejected as no comparably clean pinned Go module); an internal implementation (rejected because cryptographically relevant string/number canonicalization should not be rewritten). Primary sources: RFC 8785 and `https://github.com/gowebpki/jcs`. No own canonicalization algorithm was written.
