.pragma library

// Matching.js — unified identity matching for UnifiedAppTray
//
// Pure functions only (no Qt/QML context access, so `.pragma library`
// is safe and the file can be unit-tested under Node.js directly).
//
// One canonical matching vocabulary for all three item sources
// (pinned apps, running windows, tray items). Previously the widget
// carried two subtly different matchers: scoreNamesAgainstAppId() did
// substring matching while entryMatchesPinnedId() did exact-normalized
// matching, which made the same app occasionally render twice.

// ---------------------------------------------------------------------------
// Text normalization
// ---------------------------------------------------------------------------

// Small memo cache. Tray titles churn (VPN status, transfer rates...) and
// norm() is called O(trays x windows) times per rebuild; caching avoids
// re-running the regex chain for repeated inputs.
var _normCache = new Map();

function norm(value) {
    if (value === undefined || value === null)
        return "";
    const raw = value.toString();
    const cached = _normCache.get(raw);
    if (cached !== undefined)
        return cached;
    const result = raw.toLowerCase().replace(/[^a-z0-9]+/g, "");
    if (_normCache.size > 2000)
        _normCache.clear();
    _normCache.set(raw, result);
    return result;
}

// Strip control characters that would corrupt tab-separated PID-scan output
// or one-line tooltips.
function cleanText(value) {
    return (value === undefined || value === null ? "" : value.toString()).replace(/[\u0009\u000a\u000d\u001f]/g, " ");
}

function uniq(values) {
    const seen = new Set();
    const out = [];
    for (let i = 0; i < values.length; i++) {
        const value = values[i];
        if (!value || seen.has(value))
            continue;
        seen.add(value);
        out.push(value);
    }
    return out;
}

// ---------------------------------------------------------------------------
// Identity sets
// ---------------------------------------------------------------------------

// All normalized names a tray item can be matched by:
// SNI id, title, tooltip title, and the icon basename.
function trayNames(item) {
    if (!item)
        return [];
    const names = [
        norm(item.id),
        norm(item.title),
        norm(item.tooltipTitle)
    ];
    const iconBase = norm(((item.icon || "").toString().split("/").pop() || "").replace(/\.(png|svg|xpm|ico)$/i, ""));
    if (iconBase)
        names.push(iconBase);
    return uniq(names).filter(s => s && s.length >= 2);
}

// ---------------------------------------------------------------------------
// Scoring (tray item <-> window app_id)
// ---------------------------------------------------------------------------

// Score a tray item's name set and process-tree hints against one app_id.
// 100 exact id, 95 exact last segment, 90/85 exact process hint,
// 70 substring either way (both >= 4 chars).
function scoreAgainstAppId(names, procHints, appIdValue) {
    const appId = norm(appIdValue);
    if (!appId)
        return 0;
    const lastSeg = norm((appIdValue || "").toString().split(".").pop());
    let score = 0;
    for (let i = 0; i < names.length; i++) {
        const candidate = names[i];
        if (appId === candidate)
            score = Math.max(score, 100);
        else if (lastSeg && lastSeg === candidate)
            score = Math.max(score, 95);
        else if (candidate.length >= 4 && appId.length >= 4 && (appId.includes(candidate) || candidate.includes(appId)))
            score = Math.max(score, 70);
    }
    for (let i = 0; i < procHints.length; i++) {
        const candidate = procHints[i];
        if (appId === candidate)
            score = Math.max(score, 90);
        else if (lastSeg && lastSeg === candidate)
            score = Math.max(score, 85);
    }
    return score;
}

// ---------------------------------------------------------------------------
// Loose matching (pinned id <-> entry ids)
// ---------------------------------------------------------------------------

// The "same vocabulary" half that entryMatchesPinnedId() was missing:
// any target and any id overlapping by inclusion (both >= 4 chars) counts
// as a hit. Used after exact-normalized matching fails, so pinning a tray
// app whose friendly title is "FlClash" still matches the window whose
// app_id is "com.follow.clash" via the desktop entry name.
function looseMatchIds(ids, targets) {
    for (let t = 0; t < targets.length; t++) {
        const target = targets[t];
        if (!target || target.length < 4)
            continue;
        for (let i = 0; i < ids.length; i++) {
            const id = ids[i];
            if (!id || id.length < 4)
                continue;
            if (id === target || id.includes(target) || target.includes(id))
                return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// Node.js export shim (unit tests only; inert inside the QML engine)
// ---------------------------------------------------------------------------

if (typeof module !== "undefined" && typeof module.exports !== "undefined") {
    module.exports = {
        "norm": norm,
        "cleanText": cleanText,
        "uniq": uniq,
        "trayNames": trayNames,
        "scoreAgainstAppId": scoreAgainstAppId,
        "looseMatchIds": looseMatchIds
    };
}
