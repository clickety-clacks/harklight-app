The canonical `Scripts/verify.sh test` command generates fresh loopback-only TLS
fixtures before generating the Xcode project. The generated certificate and
PKCS12 identity are ignored by Git; no test private key is distributed in source.

The PKCS12 password is `public-fixture-only`, a fixed test-container password,
not a user credential. A new temporary CA signs a localhost/loopback RSA server
certificate with serverAuth usage for each run. Temporary CA and leaf key files
are removed after preparing the fixture. The generated identity is used only by
the ephemeral loopback listener in guided-enrollment business tests; no system
trust setting or real enrollment identity is changed. The test reads the paired
public CA from `guided-local-tls.pem` and identity from `guided-local-tls.p12`.
