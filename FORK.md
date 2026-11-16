# Fork notes

Fork of [steelbrain/RDPKit](https://github.com/steelbrain/RDPKit) for Swift Connection
Manager, meant as a bridge until the change is upstream.

Branch `connection-manager-0.8`, tag `0.8.0-cm.1`: upstream 0.8.0 plus
`RDPConnectionConfiguration.legacyCredSSPFromStart`. With it the client speaks CredSSP
version 3 from its first TSRequest on. A Windows Server 2008 (also seen with 2008 R2)
answers with version 5, yet completes only the pre-2018 public key binding, and only when
the client's first message already was below version 5; otherwise it drops the connection
after the AUTHENTICATE with no status (`credSSPClosedAfterCredentials`).
