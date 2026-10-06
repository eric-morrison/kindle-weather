# Small JSON reader for the two public weather endpoints. No external runtime.
function fail() { bad = 1; exit 1 }
function ws() { while (substr(json, pos, 1) ~ /[ \t\r\n]/ && pos <= length(json)) pos++ }
function string(    out, c, escape, hex) {
    if (substr(json, pos++, 1) != "\"") fail()
    out = ""
    while (pos <= length(json)) {
        c = substr(json, pos++, 1)
        if (c == "\"") return out
        if (c == "\\") {
            escape = substr(json, pos++, 1)
            if (escape == "u") {
                hex = substr(json, pos, 4)
                if (hex !~ /^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$/) fail()
                pos += 4
                out = out "?"
            } else if (escape == "\"" || escape == "\\" || escape == "/") out = out escape
            else if (escape ~ /^[bfnrt]$/) out = out " "
            else fail()
        } else {
            if (c ~ /[[:cntrl:]]/) fail()
            out = out c
        }
    }
    fail()
}
function value(path, depth,    c, key, item, token) {
    if (depth > 20) fail()
    ws()
    c = substr(json, pos, 1)
    if (c == "{" || c == "[") {
        kind[path] = c
        pos++; ws(); item = 0
        if (substr(json, pos, 1) == (c == "{" ? "}" : "]")) { pos++; return }
        while (1) {
            if (c == "{") {
                ws(); key = string(); ws()
                if (substr(json, pos++, 1) != ":") fail()
            } else key = item++
            value(path SUBSEP key, depth + 1); ws()
            if (substr(json, pos, 1) == (c == "{" ? "}" : "]")) { pos++; return }
            if (substr(json, pos++, 1) != ",") fail()
        }
    } else if (c == "\"") data[path] = string()
    else {
        token = substr(json, pos)
        if (!match(token, /^(-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?|true|false|null)/)) fail()
        data[path] = substr(token, 1, RLENGTH)
        pos += RLENGTH
    }
}
function field(group, key, item) {
    return data[SUBSEP group SUBSEP key (item == "" ? "" : SUBSEP item)]
}
function number(v) { return v ~ /^-?[0-9]+(\.[0-9]+)?$/ }
function temperature(v) { return number(v) ? sprintf("%.0f F", v) : "--" }
function iso_date(v) { return v ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ }
function wrap(v, width,    words, n, i, line) {
    n = split(v, words, /[[:space:]]+/); line = ""
    for (i = 1; i <= n; i++) {
        if (length(line) + length(words[i]) + 1 > width && line != "") { print line; line = "" }
        line = line (line == "" ? "" : " ") words[i]
    }
    if (line != "") print line
}
function condition(code) {
    if (code == "" || code == "null") return "Conditions unavailable"
    if (code == 0) return "Clear"
    if (code == 1) return "Mostly clear"
    if (code == 2) return "Partly cloudy"
    if (code == 3) return "Overcast"
    if (code == 45 || code == 48) return "Fog"
    if (code >= 51 && code <= 57) return "Drizzle"
    if (code >= 61 && code <= 67) return "Rain"
    if (code >= 71 && code <= 77) return "Snow"
    if (code >= 80 && code <= 82) return "Rain showers"
    if (code == 85 || code == 86) return "Snow showers"
    if (code >= 95 && code <= 99) return "Thunderstorms"
    return "Conditions unavailable"
}
function symbol(code, day) {
    code += 0
    if (code == 0 || code == 1) return day == 0 ? "◐" : "☀"
    if (code == 2) return day == 0 ? "☁" : "⛅"
    if (code == 3) return "☁"
    if (code == 45 || code == 48) return "🌫"
    if (code >= 51 && code <= 67 || code >= 80 && code <= 82) return "🌧"
    if (code >= 71 && code <= 77 || code == 85 || code == 86) return "❄"
    if (code >= 95 && code <= 99) return "⛈"
    return "?"
}
{ json = json $0 "\n" }
END {
    if (bad) exit 1
    pos = 1; value("", 0); ws()
    if (pos <= length(json)) fail()
    if (mode == "location") {
        lat = data[SUBSEP "places" SUBSEP "0" SUBSEP "latitude"]
        lon = data[SUBSEP "places" SUBSEP "0" SUBSEP "longitude"]
        city = data[SUBSEP "places" SUBSEP "0" SUBSEP "place name"]
        state = data[SUBSEP "places" SUBSEP "0" SUBSEP "state abbreviation"]
        if (!number(lat) || !number(lon) || lat + 0 < -90 || lat + 0 > 90 || lon + 0 < -180 || lon + 0 > 180 || city == "") fail()
        gsub(/[[:cntrl:]]/, "", city)
        print lat; print lon; print city ", " state
    } else if (mode == "forecast") {
        if (!number(field("daily", "temperature_2m_max", "0")) ||
            !number(field("daily", "temperature_2m_min", "0")) ||
            field("daily_units", "temperature_2m_max", "") != "°F" ||
            field("daily_units", "temperature_2m_min", "") != "°F" ||
            field("daily_units", "precipitation_sum", "") != "inch" ||
            !iso_date(field("daily", "time", "0"))) fail()
        printf "TODAY  %s\n\n", field("daily", "time", "0")
        printf "High:  %s\n", temperature(field("daily", "temperature_2m_max", "0"))
        printf "Low:   %s\n", temperature(field("daily", "temperature_2m_min", "0"))
        printf "%s\n\n", condition(field("daily", "weather_code", "0"))
        rain = field("daily", "precipitation_probability_max", "0")
        total = field("daily", "precipitation_sum", "0")
        printf "Precip chance: %s\n", number(rain) ? sprintf("%.0f%%", rain) : "--"
        printf "Precip total:  %s\n", number(total) ? sprintf("%.2f in", total) : "--"
    } else if (mode == "current") {
        time = field("current", "time", "")
        if (!number(field("current", "temperature_2m", "")) ||
            !number(field("current", "weather_code", "")) ||
            field("current_units", "temperature_2m", "") != "°F" ||
            time !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]/) fail()
        printf "Now: %s\n", temperature(field("current", "temperature_2m", ""))
        gsub(/T/, " ", time)
        printf "As of %s\n", time
        printf "Conditions: %s\n", condition(field("current", "weather_code", ""))
    } else if (mode == "hourly") {
        if (field("hourly_units", "temperature_2m", "") != "°F" ||
            field("hourly_units", "precipitation_probability", "") != "%" ||
            kind[SUBSEP "hourly" SUBSEP "time"] != "[") fail()
        reference = field("current", "time", "")
        if (reference !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]/) fail()
        count = 0
        for (i = 0; i < 48 && count < 6; i++) {
            time = field("hourly", "time", i "")
            if (time == "") break
            # Skip the current hour; include six future hours across midnight.
            if (time <= reference) continue
            temp = field("hourly", "temperature_2m", i "")
            rain = field("hourly", "precipitation_probability", i "")
            code = field("hourly", "weather_code", i "")
            day = field("hourly", "is_day", i "")
            if (!number(temp) || !number(rain) || rain + 0 < 0 || rain + 0 > 100 ||
                !number(code) || day !~ /^(0|1)$/) fail()
            hour = substr(time, 12, 2) + 0
            printf "%d%s|%.0f|%s|%.0f%%\n", (hour % 12 == 0 ? 12 : hour % 12),
                (hour < 12 ? "am" : "pm"), temp, symbol(code, day), rain
            count++
        }
        if (count != 6) fail()
    } else if (mode == "clock") {
        offset = data[SUBSEP "utc_offset_seconds"]
        zone = data[SUBSEP "timezone"]
        if (!number(offset) || offset + 0 < -43200 || offset + 0 > 50400 ||
            zone !~ /^[A-Za-z_]+\/[A-Za-z_]+(\/[A-Za-z_]+)?$/) fail()
        print offset; print zone
    } else if (mode == "alerts") {
        if (data[SUBSEP "type"] != "FeatureCollection" || kind[SUBSEP "features"] != "[") fail()
        count = 0
        for (i = 0; (SUBSEP "features" SUBSEP i) in kind; i++) {
            event = data[SUBSEP "features" SUBSEP i SUBSEP "properties" SUBSEP "event"]
            if (event == "") fail()
            if (!(event in seen)) {
                seen[event] = 1; count++
                if (count <= 3) wrap(event, 30)
            }
        }
        if (count == 0) print "No active weather alerts"
        if (count > 3) printf "+%d additional alerts\n", count - 3
    } else fail()
}
