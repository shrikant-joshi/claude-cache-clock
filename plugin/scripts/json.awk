# Cache Clock: minimal JSON and transcript helpers, in POSIX awk (works with mawk, gawk, BWK awk).
# Modes (-v mode=...):
#   get     -v key=K           print the first value of "K" in the input (strings unescaped)
#   raw     -v key=K           print the first value of "K" as raw JSON (objects, arrays, anything)
#   fields  -v keys="A B" -v prefix=P   print shell assignments P_A='...' for each key (for eval)
#   merge                      merge ENVIRON["CC_UPD"] ("key<TAB>json value" lines) into a flat
#                              JSON object read from the input, print the result compactly
#   usage                      read transcript JSONL, print "ts input read write ttl" for the last
#                              main-chat API response with cache receipts
# Keys are looked up with a regex on the raw text, like the transcript parsing: an unescaped
# "key": can't occur inside a JSON string, where quotes are escaped. Lookups take the first match.

function skipws(s, p,   c) {
    while (p <= length(s)) { c = substr(s, p, 1); if (c != " " && c != "\t" && c != "\r" && c != "\n") break; p++ }
    return p
}

# Read a JSON string starting at the opening quote. Sets VEND to the closing quote.
function read_str(s, p,   out, c, e, n) {
    out = ""; p++; n = length(s)
    while (p <= n) {
        c = substr(s, p, 1)
        if (c == "\\") {
            e = substr(s, p + 1, 1)
            if (e == "n") out = out "\n"
            else if (e == "t") out = out "\t"
            else if (e == "r") out = out "\r"
            else if (e == "b" || e == "f") out = out " "
            else if (e == "u") { out = out "?"; p += 4 }
            else out = out e
            p += 2; continue
        }
        if (c == "\"") { VEND = p; return out }
        out = out c; p++
    }
    VEND = n; return out
}

# Read any JSON value as raw text. Sets VEND to its last character.
function read_raw(s, p,   start, c, depth, instr, n, v) {
    start = p; n = length(s); depth = 0; instr = 0
    while (p <= n) {
        c = substr(s, p, 1)
        if (instr) {
            if (c == "\\") { p += 2; continue }
            if (c == "\"") { instr = 0; if (depth == 0) { p++; break } }
            p++; continue
        }
        if (c == "\"") { instr = 1; p++; continue }
        if (c == "{" || c == "[") depth++
        else if (c == "}" || c == "]") { if (depth == 0) break; depth--; if (depth == 0) { p++; break } }
        else if (c == "," && depth == 0) break
        p++
    }
    VEND = p - 1
    v = substr(s, start, p - start)
    sub(/[ \t\r\n]+$/, "", v)
    return v
}

# Position of the value of the first "key": in s, or 0.
function find_val(s, key) {
    if (!match(s, "\"" key "\"[ \t\r\n]*:")) return 0
    return skipws(s, RSTART + RLENGTH)
}

function get_val(s, key,   p) {
    p = find_val(s, key)
    if (!p) return ""
    if (substr(s, p, 1) == "\"") return read_str(s, p)
    return read_raw(s, p)
}

function shq(v) { gsub(/'/, "'\\''", v); return "'" v "'" }

# Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm).
function days_from_civil(y, m, d,   era, yoe, doy, doe) {
    if (m <= 2) y--
    era = int(y / 400)
    yoe = y - era * 400
    doy = int((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5) + d - 1
    doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
    return era * 146097 + doe - 719468
}

# "2026-09-24T18:02:06.123Z" -> epoch seconds (UTC timestamps, as Claude Code writes them).
function iso_epoch(t) {
    if (t !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/) return 0
    return days_from_civil(substr(t, 1, 4) + 0, substr(t, 6, 2) + 0, substr(t, 9, 2) + 0) * 86400 + \
        substr(t, 12, 2) * 3600 + substr(t, 15, 2) * 60 + substr(t, 18, 2)
}

function num(line, key) {
    if (match(line, "\"" key "\":[0-9]+")) return substr(line, RSTART + length(key) + 3, RLENGTH - length(key) - 3) + 0
    return 0
}

mode == "usage" {
    if (index($0, "\"type\":\"assistant\"") == 0) next
    if (index($0, "\"isSidechain\":true")) next
    if (index($0, "\"cache_read_input_tokens\":") == 0) next
    u_ts = ""
    if (match($0, "\"timestamp\":\"[^\"]*\"")) u_ts = substr($0, RSTART + 13, RLENGTH - 14)
    u_in = num($0, "input_tokens"); u_rd = num($0, "cache_read_input_tokens"); u_wr = num($0, "cache_creation_input_tokens")
    # The TTL shows up in the split of cache writes. Keep the latest write that says which.
    if (num($0, "ephemeral_1h_input_tokens") > 0) u_ttl = 3600
    else if (num($0, "ephemeral_5m_input_tokens") > 0) u_ttl = 300
    u_found = 1
    next
}

mode != "usage" { buf = buf $0 "\n" }

END {
    if (mode == "usage") {
        if (u_found) print iso_epoch(u_ts), u_in, u_rd, u_wr, (u_ttl ? u_ttl : 0)
        exit
    }
    if (mode == "get") { v = get_val(buf, key); if (v != "") print v; exit }
    if (mode == "raw") { p = find_val(buf, key); if (p) print read_raw(buf, p); exit }
    if (mode == "fields") {
        nk = split(keys, ks, " ")
        for (i = 1; i <= nk; i++) print prefix "_" ks[i] "=" shq(get_val(buf, ks[i]))
        exit
    }
    if (mode == "merge") {
        # Parse a flat object: "key": <any value>, ...
        n = 0; p = index(buf, "{")
        if (p) {
            p = skipws(buf, p + 1)
            while (p <= length(buf) && substr(buf, p, 1) == "\"") {
                k = read_str(buf, p)
                p = skipws(buf, VEND + 1)
                if (substr(buf, p, 1) != ":") break
                p = skipws(buf, p + 1)
                v = read_raw(buf, p)
                if (!(k in val)) order[++n] = k
                val[k] = v
                p = skipws(buf, VEND + 1)
                if (substr(buf, p, 1) == ",") p = skipws(buf, p + 1)
            }
        }
        nu = split(ENVIRON["CC_UPD"], lines, "\n")
        for (i = 1; i <= nu; i++) {
            t = index(lines[i], "\t")
            if (!t) continue
            k = substr(lines[i], 1, t - 1)
            if (!(k in val)) order[++n] = k
            val[k] = substr(lines[i], t + 1)
        }
        out = "{"
        for (i = 1; i <= n; i++) out = out (i > 1 ? "," : "") "\"" order[i] "\":" val[order[i]]
        print out "}"
    }
}
