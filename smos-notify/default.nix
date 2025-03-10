{ mkDerivation, autodocodec, base, conduit, containers, envparse
, hashable, lib, monad-logger, optparse-applicative, path, path-io
, persistent, persistent-sqlite, pretty-relative-time, pretty-show
, process, smos-data, smos-report, text, time
}:
mkDerivation {
  pname = "smos-notify";
  version = "0.2.1";
  src = ./.;
  isLibrary = true;
  isExecutable = true;
  enableSeparateDataOutput = true;
  libraryHaskellDepends = [
    autodocodec base conduit containers envparse hashable monad-logger
    optparse-applicative path path-io persistent persistent-sqlite
    pretty-relative-time pretty-show process smos-data smos-report text
    time
  ];
  executableHaskellDepends = [ base ];
  license = lib.licenses.mit;
  mainProgram = "smos-notify";
}
