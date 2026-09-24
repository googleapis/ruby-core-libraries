Google API Extensions for Ruby
================================

Generated API Client common code (gapic-common) is a set of modules which aids
the development of APIs for clients and servers based on [gRPC][] and Google API
conventions.

Application code will rarely need to use most of the classes within this library
directly, but code generated automatically from the API definition files in
[Google APIs][] can use services such as page streaming to provide a more
convenient and idiomatic API surface to callers.

[gRPC]: http://grpc.io
[Google APIs]: https://github.com/googleapis/googleapis/

## Supported Ruby Versions

This library is supported on Ruby 3.2+.

Google provides official support for Ruby versions that are actively supported
by Ruby Core—that is, Ruby versions that are either in normal maintenance or in
security maintenance, and not end of life. Older versions of Ruby _may_ still
work, but are unsupported and not recommended. See
https://www.ruby-lang.org/en/downloads/branches/ for details about the Ruby
support schedule.

## Post-Quantum Key Exchange

Clients built on this library negotiate the hybrid post-quantum key exchange
group `X25519MLKEM768` — classical X25519 paired with ML-KEM-768 ([NIST FIPS
203][]) — over TLS 1.3. No application code changes are required, because the
handshake belongs to the transport layer. The two transports source that
support differently:

| Transport | Cryptographic provider | Requirement | Enforced by this gem? |
| --- | --- | --- | --- |
| gRPC | BoringSSL, vendored inside the `grpc` gem | `grpc >= 1.83` | Yes |
| REST | Host system OpenSSL, via `Net::HTTP` and Faraday | OpenSSL `>= 3.5` | No |

gRPC clients get post-quantum key exchange automatically: `gapic-common`
depends on `grpc >= 1.83`, the first release to offer `X25519MLKEM768` in the
TLS ClientHello by default.

The REST requirement cannot be expressed as a gem dependency. Ruby's `openssl`
is a default gem bound to whatever `libssl` the host provides, and ML-KEM first
ships in OpenSSL 3.5. On an older host, REST connections negotiate classical
X25519 instead — a safe fallback rather than an error, but not post-quantum. To
check the OpenSSL your Ruby is linked against:

```sh
ruby -ropenssl -e 'puts OpenSSL::OPENSSL_LIBRARY_VERSION'
```

[NIST FIPS 203]: https://csrc.nist.gov/pubs/fips/203/final

## Contributing

Contributions to this library are always welcome and highly encouraged.

See the [CONTRIBUTING](CONTRIBUTING.md) documentation for more information on how to get started.
