# WARNING: GENERATED FILE, DO NOT EDIT.
# This file is generated by running hack/bin/generate-local-nix-packages.sh and
# must be regenerated whenever local packages are added or removed, or
# dependencies are added or removed.
{ mkDerivation
, aeson
, aeson-qq
, base
, base64-bytestring
, bilge
, brig-types
, bytestring
, bytestring-conversion
, case-insensitive
, cassandra-util
, cassava
, conduit
, containers
, cookie
, cryptonite
, data-default
, email-validate
, exceptions
, extended
, galley-types
, gitignoreSource
, hscim
, HsOpenSSL
, hspec
, hspec-discover
, hspec-wai
, http-api-data
, http-client
, http-types
, imports
, iso639
, lens
, lens-aeson
, lib
, metrics-wai
, MonadRandom
, mtl
, network-uri
, optparse-applicative
, polysemy
, polysemy-check
, polysemy-plugin
, polysemy-wire-zoo
, QuickCheck
, random
, raw-strings-qq
, retry
, saml2-web-sso
, servant
, servant-multipart
, servant-server
, servant-swagger
, silently
, swagger2
, tasty-hunit
, text
, text-latin1
, time
, tinylog
, transformers
, types-common
, uri-bytestring
, uuid
, vector
, wai
, wai-extra
, wai-utilities
, warp
, wire-api
, x509
, xml-conduit
, yaml
, zauth
}:
mkDerivation {
  pname = "spar";
  version = "0.1";
  src = gitignoreSource ./.;
  isLibrary = true;
  isExecutable = true;
  libraryHaskellDepends = [
    aeson
    base
    base64-bytestring
    bilge
    brig-types
    bytestring
    bytestring-conversion
    case-insensitive
    cassandra-util
    containers
    cookie
    cryptonite
    data-default
    exceptions
    extended
    galley-types
    hscim
    hspec
    http-types
    imports
    lens
    metrics-wai
    mtl
    network-uri
    optparse-applicative
    polysemy
    polysemy-check
    polysemy-plugin
    polysemy-wire-zoo
    QuickCheck
    raw-strings-qq
    saml2-web-sso
    servant-multipart
    servant-server
    text
    text-latin1
    time
    tinylog
    transformers
    types-common
    uri-bytestring
    uuid
    wai
    wai-utilities
    warp
    wire-api
    x509
    yaml
  ];
  executableHaskellDepends = [
    aeson
    aeson-qq
    base
    base64-bytestring
    bilge
    brig-types
    bytestring
    bytestring-conversion
    case-insensitive
    cassandra-util
    cassava
    conduit
    containers
    cookie
    cryptonite
    email-validate
    exceptions
    extended
    galley-types
    hscim
    HsOpenSSL
    hspec
    hspec-wai
    http-api-data
    http-client
    http-types
    imports
    iso639
    lens
    lens-aeson
    MonadRandom
    mtl
    optparse-applicative
    polysemy
    polysemy-plugin
    polysemy-wire-zoo
    QuickCheck
    random
    raw-strings-qq
    retry
    saml2-web-sso
    servant
    servant-server
    silently
    tasty-hunit
    text
    time
    tinylog
    transformers
    types-common
    uri-bytestring
    uuid
    vector
    wai-extra
    wai-utilities
    warp
    wire-api
    xml-conduit
    yaml
    zauth
  ];
  executableToolDepends = [ hspec-discover ];
  testHaskellDepends = [
    aeson
    aeson-qq
    base
    brig-types
    bytestring-conversion
    cookie
    hscim
    hspec
    imports
    lens
    lens-aeson
    metrics-wai
    mtl
    network-uri
    polysemy
    polysemy-plugin
    polysemy-wire-zoo
    QuickCheck
    saml2-web-sso
    servant
    servant-swagger
    swagger2
    time
    tinylog
    types-common
    uri-bytestring
    uuid
    wire-api
  ];
  testToolDepends = [ hspec-discover ];
  description = "User Service for SSO (Single Sign-On) provisioning and authentication";
  license = lib.licenses.agpl3Only;
}
