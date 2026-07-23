# Helper protocol and privilege boundary

The core decides policy and produces one narrowly allowed operation. The helper validates the same schema and performs only the requested confined filesystem/privilege primitive. It has no shell/command field, catalog access, trust enrollment, selector policy, network access or arbitrary path API.

HELPER_TRANSPORT=platform_specific

HELPER_AUTHENTICATION_PLAN=mutually authenticate a pinned, code-signed helper identity plus OS peer identity/credentials; bind request and response to protocol version, operation ID and nonce; unsigned, untrusted or uninspectable identity fails closed

HELPER_REQUEST_ALLOWLIST_MODEL=closed operation enum such as CreateDirectory, PublishFile, SetPermissions and RemoveStaging; each operation has a schema-specific payload, maximum sizes and required privilege; no generic execute or free-form arguments

HELPER_PATH_CONFINEMENT=core sends typed root ID plus validated relative path and expected root/file identity; helper resolves handle-relative without following links/reparse points and rechecks the final object beneath a configured root

HELPER_REPLAY_PROTECTION=cryptographically random single-use nonce, OperationID, request digest, short expiry and durable bounded replay cache; duplicate identical completed request returns recorded result, changed digest rejects

HELPER_VERSION_HANDSHAKE=major-equal capability exchange with schema minimum/current minor ranges and operation allowlist; unknown major or missing required capability fails closed

HELPER_PROTOCOL_STATUS=RESOLVED

Request fields: protocol version, request/operation identity, allowed root/path, closed operation, expected digest/metadata, privilege requirement, nonce, issued/expiry time, cancellation token and correlation ID. Result fields: request digest/nonce, status, observed digest/metadata, stable platform error, audit reference and completion time. Timeouts are bounded; cancellation is cooperative before the atomic point and returns explicit indeterminate status after it, forcing recovery inspection. Windows transport candidate is a secured named pipe; Linux/macOS candidate is an owner-restricted Unix-domain endpoint to a supervised helper. Exact transport is selected in SLICE-9 without changing this message contract.
