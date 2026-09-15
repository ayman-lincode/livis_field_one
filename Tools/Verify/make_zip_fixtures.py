"""Builds the zip shapes the Models import has to cope with.

Every fixture wraps the bundled QuadrantSmokeTest package so the checks can
compile and run whatever comes out of the extractor.
"""
import io, os, shutil, subprocess, sys, zipfile

out = sys.argv[1]
package = os.path.abspath(os.path.join(os.path.dirname(__file__), "../SampleModel/QuadrantSmokeTest.mlpackage"))
shutil.rmtree(out, ignore_errors=True)
os.makedirs(out)

def package_files():
    for root, _, files in os.walk(package):
        for name in files:
            full = os.path.join(root, name)
            yield full, os.path.relpath(full, package)

# 1. Contents at the root, no .mlpackage folder: what Colab/Python exports make.
with zipfile.ZipFile(os.path.join(out, "root-contents.mlpackage (1).zip"), "w", zipfile.ZIP_DEFLATED) as z:
    for full, rel in package_files():
        z.write(full, rel)
    z.writestr("labels.txt", "bright\ndark\n")

# 2. Finder-style: an enclosing .mlpackage folder plus __MACOSX resource forks.
with zipfile.ZipFile(os.path.join(out, "finder.zip"), "w", zipfile.ZIP_DEFLATED) as z:
    for full, rel in package_files():
        z.write(full, "QuadrantSmokeTest.mlpackage/" + rel)
        z.writestr("__MACOSX/QuadrantSmokeTest.mlpackage/._" + os.path.basename(rel), b"\x00\x05\x16\x07")

# 3. Stored, no compression.
with zipfile.ZipFile(os.path.join(out, "stored.zip"), "w", zipfile.ZIP_STORED) as z:
    for full, rel in package_files():
        z.write(full, "nested/model/QuadrantSmokeTest.mlpackage/" + rel)

# 4. Zip64 records, as large models force.
with zipfile.ZipFile(os.path.join(out, "zip64.zip"), "w", zipfile.ZIP_DEFLATED, allowZip64=True) as z:
    for full, rel in package_files():
        with open(full, "rb") as src, z.open(rel, "w", force_zip64=True) as dst:
            dst.write(src.read())

# 5. Data descriptors: written to an unseekable stream, sizes trail the data.
class Unseekable(io.RawIOBase):
    def __init__(self, f): self.f = f
    def writable(self): return True
    def write(self, b): return self.f.write(b)
with open(os.path.join(out, "descriptor.zip"), "wb") as raw:
    with zipfile.ZipFile(Unseekable(raw), "w", zipfile.ZIP_DEFLATED) as z:
        for full, rel in package_files():
            z.write(full, rel)

# 6. Zip-slip: an entry that climbs out of the destination.
with zipfile.ZipFile(os.path.join(out, "slip.zip"), "w") as z:
    z.writestr("../escaped.txt", "should never be written")
    for full, rel in package_files():
        z.write(full, rel)

# 7. Two models in one zip.
with zipfile.ZipFile(os.path.join(out, "two-models.zip"), "w", zipfile.ZIP_DEFLATED) as z:
    for full, rel in package_files():
        z.write(full, "a.mlpackage/" + rel)
        z.write(full, "b.mlpackage/" + rel)

# 8. A corrupted byte inside compressed data.
data = bytearray(open(os.path.join(out, "stored.zip"), "rb").read())
marker = data.find(b"weight.bin")
data[marker + 200] ^= 0xFF
open(os.path.join(out, "corrupt.zip"), "wb").write(bytes(data))

# 9b. Entries prefixed with "./", as `zip -r x.zip .` style tools write them.
with zipfile.ZipFile(os.path.join(out, "dot-prefix.zip"), "w", zipfile.ZIP_DEFLATED) as z:
    for full, rel in package_files():
        z.write(full, "./" + rel)

# 9. A folder of package contents under a Finder duplicate name.
shutil.copytree(package, os.path.join(out, "QuadrantSmokeTest.mlpackage (1)"))
os.rename(os.path.join(out, "QuadrantSmokeTest.mlpackage (1)"), os.path.join(out, "unzipped-folder.mlpackage (1)"))

print("fixtures ready:", ", ".join(sorted(os.listdir(out))))
