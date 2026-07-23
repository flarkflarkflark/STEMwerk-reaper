#!/usr/bin/env python3
"""Executable Contract v1 policy conformance examples; no production implementation."""
import unittest

OFFICIAL = {"official.catalog", "official.artifact", "official.helper"}
ALGORITHMS = {"Ed25519", "ECDSA-P256-SHA256"}

def trust_allowed(origin, scope, confirmed=True, verified=True):
    if scope in OFFICIAL:
        return origin == "trusted_distribution" and verified
    if scope == "user.catalog":
        return origin == "user_enrollment" and confirmed and verified
    return scope == "development.local" and origin == "development"

def signature_allowed(algorithm, signed, scope, digest_bound=True):
    if scope in OFFICIAL and not signed:
        return False
    return signed and algorithm in ALGORITHMS and digest_bound

def revocation_action(status, action, critical=False):
    if critical and action == "active_use":
        return "block"
    if status in {"revoked", "expired", "unknown"} and action in {"install", "activate", "rollback"}:
        return "block"
    if status == "revoked" and action == "active_use":
        return "diagnostic_recovery"
    return "allow"

def offline_action(age_days, action, critical=False, clock_rollback=False):
    if clock_rollback:
        return "block"
    if critical and action == "active_use":
        return "block"
    if age_days > 30 and action in {"install", "repair", "activate", "rollback"}:
        return "block"
    return "allow"

def catalog_accept(last_seq, last_digest, seq, digest, previous_digest):
    if seq < last_seq or (seq == last_seq and digest != last_digest):
        return False
    if seq > last_seq and previous_digest != last_digest:
        return False
    return True

def gc_eligible(*, rank, age_days, active=False, pinned=False, leased=False,
                suspected=False, ownership_known=True, references=0, dry_run=True):
    protected = active or pinned or leased or suspected or not ownership_known or references != 0
    return not protected and rank > 3 and age_days >= 30 and dry_run

def schema_compatible(read_major, read_minor, object_major, object_minor):
    return object_major == read_major == 1 and object_minor <= read_minor

class TrustPolicyTests(unittest.TestCase):
    def test_01_scope_isolation(self): self.assertFalse(trust_allowed("user_enrollment", "official.catalog"))
    def test_02_no_official_tofu(self): self.assertFalse(trust_allowed("tofu", "official.artifact"))
    def test_03_user_enrollment_auditable_confirmation(self): self.assertFalse(trust_allowed("user_enrollment", "user.catalog", confirmed=False))

class SignaturePolicyTests(unittest.TestCase):
    def test_04_primary_algorithm(self): self.assertTrue(signature_allowed("Ed25519", True, "official.catalog"))
    def test_05_algorithm_allowlist(self): self.assertFalse(signature_allowed("RSA-PSS", True, "official.catalog"))
    def test_06_signed_digest_binding(self): self.assertFalse(signature_allowed("Ed25519", True, "official.artifact", False))

class RevocationPolicyTests(unittest.TestCase):
    def test_07_new_install_revoked(self): self.assertEqual(revocation_action("revoked", "install"), "block")
    def test_08_active_recovery_default(self): self.assertEqual(revocation_action("revoked", "active_use"), "diagnostic_recovery")
    def test_09_critical_deny(self): self.assertEqual(revocation_action("revoked", "active_use", True), "block")

class OfflinePolicyTests(unittest.TestCase):
    def test_10_expired_install(self): self.assertEqual(offline_action(31, "install"), "block")
    def test_11_expired_active_use(self): self.assertEqual(offline_action(31, "active_use"), "allow")
    def test_12_clock_rollback(self): self.assertEqual(offline_action(1, "activate", clock_rollback=True), "block")

class CatalogRollbackTests(unittest.TestCase):
    def test_13_monotonic_advance(self): self.assertTrue(catalog_accept(4, "a", 5, "b", "a"))
    def test_14_lower_sequence(self): self.assertFalse(catalog_accept(4, "a", 3, "z", "x"))
    def test_15_same_sequence_digest_fork(self): self.assertFalse(catalog_accept(4, "a", 4, "b", "a"))

class GCPolicyTests(unittest.TestCase):
    def test_16_count_threshold(self): self.assertFalse(gc_eligible(rank=3, age_days=40))
    def test_17_age_threshold(self): self.assertFalse(gc_eligible(rank=4, age_days=29))
    def test_18_count_and_age(self): self.assertTrue(gc_eligible(rank=4, age_days=30))
    def test_19_suspected_or_unknown_kept(self):
        self.assertFalse(gc_eligible(rank=4, age_days=40, suspected=True))
        self.assertFalse(gc_eligible(rank=4, age_days=40, ownership_known=False))
    def test_20_shared_reference_and_dry_run(self):
        self.assertFalse(gc_eligible(rank=4, age_days=40, references=1))
        self.assertFalse(gc_eligible(rank=4, age_days=40, dry_run=False))

class SchemaWindowTests(unittest.TestCase):
    def test_21_unknown_major(self): self.assertFalse(schema_compatible(1, 0, 2, 0))
    def test_22_newer_minor(self): self.assertFalse(schema_compatible(1, 0, 1, 1))
    def test_23_writer_and_downgrade_window(self):
        self.assertTrue(schema_compatible(1, 0, 1, 0))
        self.assertFalse(schema_compatible(1, 0, 1, 1))

class InteractionTests(unittest.TestCase):
    def test_24_policy_interaction_matrix(self):
        self.assertEqual(revocation_action("revoked", "rollback"), "block")
        self.assertEqual(offline_action(31, "active_use"), "allow")
        self.assertFalse(trust_allowed("development", "official.artifact"))

if __name__ == "__main__":
    unittest.main(verbosity=2)
