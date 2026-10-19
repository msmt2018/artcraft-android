#!/usr/bin/env python3
"""Apply the two SAF fixes to every ArtCraft MainActivity.java.

Both were found by driving the real device, and neither was visible from the source alone:

1. startActivityForResult must run on the UI thread. The Rust side calls safPickMedia() from a
   background thread (it polls safIsDone instead of blocking the render thread), and starting an
   activity off the UI thread throws -- the JNI wrapper then swallows it, so the picker silently
   never appears. Wrap both pickers in runOnUiThread.

2. vivo's file manager picks its UI from the intent's MIME type. With only the all-types MIME it
   shows its *media* selector (图片 / 时光轴 / 相册集), where a .svg / .pdf / .blend cannot be
   selected at all. Adding EXTRA_MIME_TYPES with a non-visual list makes it open the real document
   browser (全部 / 图片 / 文档 / 其他 + 最近 + 设备存储). Verified on the device by running the same
   intent with and without the extra.

Idempotent: re-running changes nothing.
"""
import re
import sys

MIME_EXTRA = """        /* Android-port: vivo's file manager decides which UI to show from the MIME type. With a
         * bare all-types MIME it opens its *media* selector (图片 / 时光轴 / 相册集), where a .svg,
         * .pdf or .blend cannot be selected at all -- the picker "appears" but is useless for
         * documents. A non-visual EXTRA_MIME_TYPES list makes it open the real document browser
         * (全部 / 图片 / 文档 / 其他, with 最近 and 设备存储). Verified on the device. */
        intent.putExtra(Intent.EXTRA_MIME_TYPES, new String[] {
            "application/octet-stream",
            "application/pdf",
            "image/svg+xml",
            "text/plain",
        });
"""

# Matches the un-wrapped form:
#     try {
#         startActivityForResult(intent, REQ_OPEN);
#     } catch (Exception e) {
#         ...
#     }
UNWRAPPED = re.compile(
    r"^( *)try \{\n"
    r"( *)startActivityForResult\(intent, (REQ_OPEN|REQ_SAVE)\);\n"
    r"( *)\} catch \(Exception e\) \{\n"
    r"((?:.*\n)*?)"
    r"( *)\}\n",
    re.MULTILINE,
)


def wrap(match):
    base, _, req, _, body, _ = match.groups()
    ind = base + "    "
    # The body already carries the original indentation (base + 4); one more level is enough.
    body = "".join(("    " + line if line.strip() else line) for line in body.splitlines(True))
    return (
        f"{base}runOnUiThread(() -> {{\n"
        f"{ind}try {{\n"
        f"{ind}    startActivityForResult(intent, {req});\n"
        f"{ind}}} catch (Exception e) {{\n"
        f"{body}"
        f"{ind}}}\n"
        f"{base}}});\n"
    )


def patch(path):
    src = open(path, encoding="utf-8").read()
    orig = src
    notes = []

    if "EXTRA_MIME_TYPES" not in src:
        anchor = "        intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);\n"
        if anchor in src:
            src = src.replace(anchor, anchor + MIME_EXTRA, 1)
            notes.append("mime-types")
        else:
            notes.append("NO-ANCHOR")
    else:
        notes.append("mime-ok")

    src, n = UNWRAPPED.subn(wrap, src)
    notes.append(f"wrapped={n}")

    if src != orig:
        open(path, "w", encoding="utf-8").write(src)
    return notes


if __name__ == "__main__":
    for path in sys.argv[1:]:
        print(f"{path}: {' '.join(patch(path))}")
