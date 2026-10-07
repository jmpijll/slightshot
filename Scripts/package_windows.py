"""Package a single-file Windows publish without hiding missing dependencies."""

import argparse
from pathlib import Path
import struct
import zipfile


def package(publish_directory: Path, archive: Path, architecture: str) -> None:
    entries = list(publish_directory.iterdir())
    if len(entries) != 1 or entries[0].name != "Slightshot.exe" or not entries[0].is_file():
        raise ValueError("Portable publish must contain only Slightshot.exe; use the Portable publish profile")

    executable = entries[0]
    with executable.open("rb") as binary:
        if binary.read(2) != b"MZ":
            raise ValueError("Slightshot.exe is not a Windows executable")
        binary.seek(0x3C)
        offset = binary.read(4)
        if len(offset) != 4:
            raise ValueError("Slightshot.exe has an incomplete DOS header")
        binary.seek(struct.unpack("<I", offset)[0])
        header = binary.read(6)
        expected_machine = {"x64": 0x8664, "arm64": 0xAA64}[architecture]
        if len(header) != 6 or header[:4] != b"PE\0\0" or struct.unpack("<H", header[4:])[0] != expected_machine:
            raise ValueError(f"Slightshot.exe is not a {architecture} Windows executable")

    archive.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as output:
        output.write(executable, "Slightshot.exe")
    with zipfile.ZipFile(archive) as output:
        if output.namelist() != ["Slightshot.exe"] or output.testzip() is not None:
            raise ValueError("Portable archive failed its content/integrity check")
    print(f"Packaged {architecture}: {archive} ({archive.stat().st_size:,} bytes, only Slightshot.exe)")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("publish_directory", type=Path)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--architecture", choices=["x64", "arm64"], required=True)
    args = parser.parse_args()
    package(args.publish_directory, args.archive, args.architecture)


if __name__ == "__main__":
    main()
