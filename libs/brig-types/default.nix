# WARNING: GENERATED FILE, DO NOT EDIT.
# This file is generated by running hack/bin/generate-local-nix-packages.sh and
# must be regenerated whenever local packages are added or removed, or
# dependencies are added or removed.
{ mkDerivation
, aeson
, attoparsec
, base
, bytestring
, bytestring-conversion
, cassandra-util
, containers
, gitignoreSource
, imports
, lib
, QuickCheck
, swagger2
, tasty
, tasty-hunit
, tasty-quickcheck
, text
, tinylog
, types-common
, wire-api
}:
mkDerivation {
  pname = "brig-types";
  version = "1.35.0";
  src = gitignoreSource ./.;
  libraryHaskellDepends = [
    aeson
    attoparsec
    base
    bytestring
    bytestring-conversion
    cassandra-util
    containers
    imports
    QuickCheck
    text
    tinylog
    types-common
    wire-api
  ];
  testHaskellDepends = [
    aeson
    base
    bytestring-conversion
    imports
    QuickCheck
    swagger2
    tasty
    tasty-hunit
    tasty-quickcheck
    wire-api
  ];
  description = "User Service";
  license = lib.licenses.agpl3Only;
}
