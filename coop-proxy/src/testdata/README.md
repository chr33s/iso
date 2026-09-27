# TLS test fixtures

`untrusted_upstream_*` is public self-signed localhost test data. It is never
installed in the host trust store and must be rejected by production roots.

The shared forwarding corpus generates disposable certificates using
`tests/fixtures/credential-proxy/generate-forwarding-certificates.py`: a two-day
CA and one-day server leaf for both provider DNS names. Both implementations
use that generator, enable ordinary chain/hostname verification, and remove
the generated keys after their tests. Short validity satisfies Apple trust
policy and avoids checked-in certificates expiring. Python 3 and OpenSSL are
required for these tests. The generator also emits a self-signed leaf, a leaf
for the wrong hostname, and an expired leaf for the shared failure cases.
