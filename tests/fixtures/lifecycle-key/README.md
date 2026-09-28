Synthetic ed25519 key for `tests/test-swift-host-lifecycle-parity.py`.

It only reaches the stateful fake runtime; no VM or host trusts it. It is
fixed so the recorded baseline (`tests/baseline/parity/lifecycle.json`) is
reproducible: the key's fingerprint feeds each image's `manifest_id`, and the
public key is part of the image build context.
