#!/usr/bin/env python3
"""Every add-on Mirage registers must have a compiled-in cover and icon (MRGAddonArtData.m), so the shop never falls
back to the generic puzzle piece. Run by mirage-build.sh; exits 1 naming the add-ons without art."""
import re, sys, pathlib
src = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "mirage/Sources")
ids = set()
for f in list(src.rglob("*.m")) + list(src.rglob("*.x")):
    t = f.read_text(errors="ignore")
    for m in re.finditer(r'addonID \{ return (@"([^"]+)"|kAddon); \}', t):
        if m.group(2):
            ids.add(m.group(2))
        else:
            k = re.search(r'static NSString \*const kAddon = @"([^"]+)"', t)
            if k:
                ids.add(k.group(1))
art = (src / "Addons" / "MRGAddonArtData.m").read_text(errors="ignore")
have = {}
for a, kind in re.findall(r'\{"([a-z0-9-]+)", "(cover|icon)"', art):
    have.setdefault(a, set()).add(kind)
missing = sorted(i for i in ids if have.get(i, set()) != {"cover", "icon"})
print(f"art: {len(ids)} add-ons registered, {len(ids) - len(missing)} with a cover and icon")
if missing:
    print("art: missing for " + ", ".join(missing))
    sys.exit(1)
