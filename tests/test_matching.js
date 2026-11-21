#!/usr/bin/env node
// Unit tests for js/Matching.js — zero dependencies, run: node tests/test_matching.js
//
// Matching.js carries a `.pragma library` line (QML dialect) that plain
// Node cannot parse, so the loader strips it before compiling the rest,
// which is standard ES that both the V4 engine and Node accept. The
// module.exports shim at the bottom of Matching.js handles the export.

"use strict";

const fs = require("fs");
const path = require("path");
const Module = require("module");

const libPath = path.join(__dirname, "..", "js", "Matching.js");
const source = fs.readFileSync(libPath, "utf8")
    .replace(/^\s*\.pragma\s+library\s*$/m, "");
const mod = new Module("matching", null);
mod.filename = libPath;
mod._compile(source, libPath);
const M = mod.exports;

let passed = 0;
let failed = 0;

function eq(actual, expected, label) {
    const a = JSON.stringify(actual);
    const b = JSON.stringify(expected);
    if (a === b) {
        passed++;
    } else {
        failed++;
        console.error(`FAIL ${label}\n  expected: ${b}\n  actual:   ${a}`);
    }
}

// --- norm -------------------------------------------------------------
eq(M.norm(undefined), "", "norm(undefined) -> empty");
eq(M.norm(null), "", "norm(null) -> empty");
eq(M.norm("FlClash"), "flclash", "norm lowercases");
eq(M.norm("com.follow.clash"), "comfollowclash", "norm strips dots");
eq(M.norm("KDE Connect"), "kdeconnect", "norm strips spaces");
eq(M.norm("蒸汽平台"), "", "norm strips non-alnum (CJK)");
eq(M.norm("Steam-WebHelper_2"), "steamwebhelper2", "norm strips - and _");

// --- cleanText --------------------------------------------------------
eq(M.cleanText(null), "", "cleanText(null) -> empty");
eq(M.cleanText("a\tb\nc\rd\x1fe"), "a b c d e", "cleanText flattens separators");

// --- uniq -------------------------------------------------------------
eq(M.uniq(["a", "b", "a", "", "b"]), ["a", "b"], "uniq drops dups and empty");
eq(M.uniq([]), [], "uniq of empty");

// --- trayNames --------------------------------------------------------
eq(M.trayNames(null), [], "trayNames(null) -> empty");
eq(
    M.trayNames({ "id": "flclash", "title": "FlClash", "tooltipTitle": "FlClash", "icon": "" }),
    ["flclash"],
    "trayNames collapses identical id/title/tooltip"
);
eq(
    M.trayNames({ "id": "steam", "title": "Steam", "tooltipTitle": "", "icon": "file:///x/steam_tray_mono.png" }),
    ["steam", "steamtraymono"],
    "trayNames includes icon basename without extension"
);
eq(
    M.trayNames({ "id": "x", "title": "y", "tooltipTitle": "z" }),
    [],
    "trayNames drops one-char names"
);

// --- scoreAgainstAppId ------------------------------------------------
const names = M.trayNames({ "id": "FlClash", "title": "FlClash", "tooltipTitle": "FlClash", "icon": "" });
eq(M.scoreAgainstAppId(names, [], "flclash"), 100, "score exact id");
eq(M.scoreAgainstAppId(names, [], "com.follow.clash.FlClash"), 95, "score exact last segment");
eq(M.scoreAgainstAppId(names, [], "com.follow.clash.flclash"), 95, "score exact last segment (lowercase)");
eq(M.scoreAgainstAppId(names, [], "flclash-gui"), 70, "score substring");
eq(M.scoreAgainstAppId(names, [], "unrelated"), 0, "score no match");
eq(M.scoreAgainstAppId([], ["flclash"], "flclash"), 90, "score proc hint exact");
eq(M.scoreAgainstAppId([], ["flclash"], "FlClash.desktop"), 0, "score proc hint requires exact match (no substring)");
eq(M.scoreAgainstAppId(names, [], ""), 0, "score empty appId");
// regression guard: generic short names must not substring-match
eq(M.scoreAgainstAppId(["app"], [], "appstream"), 0, "score short name cannot substring");

// --- looseMatchIds ----------------------------------------------------
eq(M.looseMatchIds(["comfollowclash"], ["followclash"]), true, "loose containment both >= 4");
eq(M.looseMatchIds(["steam"], ["steamwebhelper"]), true, "loose containment steam");
eq(M.looseMatchIds(["qq"], ["qqmusic"]), false, "loose rejects < 4 char id");
eq(M.looseMatchIds(["discord"], ["spotifysomething"]), false, "loose rejects unrelated");
eq(M.looseMatchIds([], ["anything"]), false, "loose empty ids");
eq(M.looseMatchIds(["anything"], []), false, "loose empty targets");

// --- unified vocabulary scenario ---------------------------------------
// The original bug: pinning "com.follow.clash" failed to dedupe with a
// tray item titled "FlClash" because entryMatchesPinnedId only did exact
// normalized equality. With looseMatchIds in the chain it must now hit.
const trayIds = M.trayNames({ "id": "FlClash", "title": "FlClash", "tooltipTitle": "FlClash", "icon": "" });
const pinnedVariants = [M.norm("com.follow.clash")];
const desktopName = M.norm("FlClash");
eq(
    M.looseMatchIds(trayIds, pinnedVariants.concat(desktopName ? [desktopName] : [])),
    true,
    "scenario: pinned desktop id dedupes with friendly tray title"
);

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
