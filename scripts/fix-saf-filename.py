#!/usr/bin/env python3
"""Make the SAF import keep the file's real name, extension included.

The picker hands back a content:// URI whose document id is an opaque number for media-provider
documents (e.g. `document:1000027067`). The old code derived the copied file's name from that id,
so an .svg from Downloads landed as `files/import/1000027067` -- no extension -- and the app then
had no way to know what format to parse. The provider's DISPLAY_NAME column carries the real name,
so ask for it first and only fall back to the id.

Idempotent: re-running changes nothing.
"""
import re
import sys

IMPORTS_OLD = "import android.content.Intent;\n"
IMPORTS_NEW = (
    "import android.content.Intent;\n"
    "import android.database.Cursor;\n"
    "import android.provider.OpenableColumns;\n"
)

BODY_OLD = """        String name = null;
        try {
            name = DocumentsContract.getDocumentId(uri);
            int slash = name.lastIndexOf('/');
            if (slash >= 0) {
                name = name.substring(slash + 1);
            }
            int colon = name.indexOf(':');
            if (colon >= 0) {
                name = name.substring(colon + 1);
            }
        } catch (Throwable ignored) {
            // Not a document URI after all; use the path segment below.
        }
"""

BODY_NEW = """        String name = null;
        // Android-port: DISPLAY_NAME is the only place the *extension* survives. The document id
        // below is an opaque number for media-provider URIs, so naming the copy after it produces
        // an extension-less file that the app cannot identify. Ask the provider first.
        try (Cursor c = getContentResolver().query(uri,
                new String[] { OpenableColumns.DISPLAY_NAME }, null, null, null)) {
            if (c != null && c.moveToFirst() && !c.isNull(0)) {
                name = c.getString(0);
            }
        } catch (Throwable ignored) {
            // Provider does not implement DISPLAY_NAME; fall back to the document id.
        }
        try {
            if (name == null || name.isEmpty()) {
                name = DocumentsContract.getDocumentId(uri);
                int slash = name.lastIndexOf('/');
                if (slash >= 0) {
                    name = name.substring(slash + 1);
                }
                int colon = name.indexOf(':');
                if (colon >= 0) {
                    name = name.substring(colon + 1);
                }
            }
        } catch (Throwable ignored) {
            // Not a document URI after all; use the path segment below.
        }
"""


def patch(path):
    src = open(path, encoding="utf-8").read()
    orig = src
    notes = []
    if "OpenableColumns" not in src:
        if IMPORTS_OLD in src:
            src = src.replace(IMPORTS_OLD, IMPORTS_NEW, 1)
            notes.append("imports")
        else:
            notes.append("NO-IMPORT-ANCHOR")
    if BODY_OLD in src:
        src = src.replace(BODY_OLD, BODY_NEW, 1)
        notes.append("body")
    elif "OpenableColumns.DISPLAY_NAME" in src:
        notes.append("body-ok")
    else:
        notes.append("NO-BODY-ANCHOR")
    if src != orig:
        open(path, "w", encoding="utf-8").write(src)
    return notes


if __name__ == "__main__":
    for p in sys.argv[1:]:
        print(f"{p.split('/apps/')[0].split('MainActivity')[0][-40:] or p}: {' '.join(patch(p))}")
