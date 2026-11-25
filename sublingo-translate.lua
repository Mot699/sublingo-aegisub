--[[
SubLingo Translate for Aegisub
Translate dialogue lines with sublingo.cc (AI translation). Override tags, \N line
breaks, styles and timing are kept. Free for 2,000 lines a day, no account.

Install: copy this file into Aegisub's automation/autoload folder
  Windows: %APPDATA%\Aegisub\automation\autoload\
  macOS:   ~/Library/Application Support/Aegisub/automation/autoload/
  Linux:   ~/.aegisub/automation/autoload/
then restart Aegisub (or Automation > Rescan Autoload Dir).
Use: Automation > SubLingo: Translate subtitles

Needs curl, which ships with Windows 10+, macOS and most Linux distributions.
The dialogue text of the lines you translate is sent to https://sublingo.cc.

More: https://sublingo.cc/tools/aegisub-translate-plugin
]]

script_name = "SubLingo: Translate subtitles"
script_description = "Translate dialogue lines with sublingo.cc (AI). Keeps override tags, \\N breaks and timing."
script_author = "SubLingo (sublingo.cc)"
script_version = "1.0.0"
script_namespace = "cc.sublingo.translate"

local API = "https://sublingo.cc/api/translate"
local CHUNK = 30
local REF = (os.getenv and os.getenv("SUBLINGO_REF")) or "aegisub"

local LANGS = {
  "English", "Spanish", "Portuguese", "French", "German", "Italian", "Japanese",
  "Korean", "Chinese (Simplified)", "Chinese (Traditional)", "Arabic", "Hindi",
  "Russian", "Vietnamese", "Indonesian", "Thai", "Turkish", "Dutch", "Polish",
  "Swedish", "Greek", "Czech", "Romanian", "Hungarian", "Hebrew", "Persian",
  "Ukrainian", "Tamil", "Filipino", "Malay",
}

local MODES = {
  "Replace text, keep original as comment",
  "Replace text",
  "Bilingual: original on top",
  "Bilingual: translation on top",
}

local SCOPES = { "Selected lines", "All dialogue lines" }

---------------------------------------------------------------------------
-- JSON (minimal, enough for this API)
---------------------------------------------------------------------------

local function json_str(s)
  s = s:gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"'
    elseif c == "\\" then return "\\\\"
    elseif c == "\n" then return "\\n"
    elseif c == "\r" then return "\\r"
    elseif c == "\t" then return "\\t"
    else return string.format("\\u%04x", c:byte()) end
  end)
  return '"' .. s .. '"'
end

local function utf8_char(cp)
  local f = math.floor
  if cp < 0x80 then return string.char(cp)
  elseif cp < 0x800 then return string.char(0xC0 + f(cp / 64), 0x80 + cp % 64)
  elseif cp < 0x10000 then
    return string.char(0xE0 + f(cp / 4096), 0x80 + f(cp / 64) % 64, 0x80 + cp % 64)
  else
    return string.char(0xF0 + f(cp / 262144), 0x80 + f(cp / 4096) % 64,
      0x80 + f(cp / 64) % 64, 0x80 + cp % 64)
  end
end

local ESC = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function json_decode(s)
  local pos = 1
  local function ws() pos = s:find("[^ \t\r\n]", pos) or (#s + 1) end
  local function str()
    pos = pos + 1
    local buf = {}
    while true do
      local c = s:sub(pos, pos)
      if c == "" then error("unterminated JSON string") end
      if c == '"' then pos = pos + 1; break end
      if c == "\\" then
        local e = s:sub(pos + 1, pos + 1)
        if e == "u" then
          local cp = tonumber(s:sub(pos + 2, pos + 5), 16) or 63
          pos = pos + 6
          if cp >= 0xD800 and cp <= 0xDBFF and s:sub(pos, pos + 1) == "\\u" then
            local lo = tonumber(s:sub(pos + 2, pos + 5), 16) or 0xDC00
            cp = 0x10000 + (cp - 0xD800) * 1024 + (lo - 0xDC00)
            pos = pos + 6
          end
          buf[#buf + 1] = utf8_char(cp)
        else
          buf[#buf + 1] = ESC[e] or e
          pos = pos + 2
        end
      else
        local j = s:find('["\\]', pos)
        if not j then error("unterminated JSON string") end
        buf[#buf + 1] = s:sub(pos, j - 1)
        pos = j
      end
    end
    return table.concat(buf)
  end
  local value
  value = function()
    ws()
    local c = s:sub(pos, pos)
    if c == "{" then
      pos = pos + 1
      local t = {}
      ws()
      if s:sub(pos, pos) == "}" then pos = pos + 1; return t end
      while true do
        ws()
        local k = str()
        ws()
        pos = pos + 1 -- ':'
        t[k] = value()
        ws()
        local d = s:sub(pos, pos)
        pos = pos + 1
        if d == "}" then return t end
        if d ~= "," then error("bad JSON object") end
      end
    elseif c == "[" then
      pos = pos + 1
      local t = {}
      ws()
      if s:sub(pos, pos) == "]" then pos = pos + 1; return t end
      while true do
        t[#t + 1] = value()
        ws()
        local d = s:sub(pos, pos)
        pos = pos + 1
        if d == "]" then return t end
        if d ~= "," then error("bad JSON array") end
      end
    elseif c == '"' then
      return str()
    elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
    elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
    elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil
    end
    local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    if not num or num == "" then error("bad JSON at position " .. pos) end
    pos = pos + #num
    return tonumber(num)
  end
  return value()
end

---------------------------------------------------------------------------
-- Settings (saved next to Aegisub's config)
---------------------------------------------------------------------------

local function conf_path() return aegisub.decode_path("?user/sublingo-translate.conf") end

local function enc(v) return (tostring(v):gsub("[%%\r\n]", function(c) return string.format("%%%02X", c:byte()) end)) end
local function dec(v) return (v:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end

local function load_conf()
  local c = { to = "English", mode = MODES[1], scope = SCOPES[1], glossary = "", key = "", other = "" }
  local f = io.open(conf_path(), "rb")
  if f then
    for line in f:lines() do
      local k, v = line:match("^(%w+)=(.*)$")
      if k then c[k] = dec(v) end
    end
    f:close()
  end
  return c
end

local function save_conf(c)
  local f = io.open(conf_path(), "wb")
  if not f then return end
  for _, k in ipairs({ "to", "mode", "scope", "glossary", "key", "other" }) do
    f:write(k, "=", enc(c[k] or ""), "\n")
  end
  f:close()
end

---------------------------------------------------------------------------
-- HTTP via curl
---------------------------------------------------------------------------

local function is_windows() return package.config:sub(1, 1) == "\\" end

local function q(s)
  if is_windows() then return '"' .. s:gsub('"', '\\"') .. '"' end
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function post_json(body, headers)
  local req = aegisub.decode_path("?temp/sublingo-req.json")
  local resp = aegisub.decode_path("?temp/sublingo-resp.json")
  local f = assert(io.open(req, "wb"))
  f:write(body)
  f:close()
  os.remove(resp)
  local parts = { "curl", "-s", "-S", "--max-time", "120", "-X", "POST",
    "-o", q(resp), "-w", q("%{http_code}"), "-H", q("Content-Type: application/json") }
  for k, v in pairs(headers) do
    parts[#parts + 1] = "-H"
    parts[#parts + 1] = q(k .. ": " .. v)
  end
  parts[#parts + 1] = "--data-binary"
  parts[#parts + 1] = q("@" .. req)
  parts[#parts + 1] = API
  local p = io.popen(table.concat(parts, " ") .. " 2>&1", "r")
  local out = p and p:read("*a") or ""
  if p then p:close() end
  local status = tonumber(out:match("(%d%d%d)%s*$") or "")
  local rf = io.open(resp, "rb")
  local text = rf and rf:read("*a") or ""
  if rf then rf:close() end
  os.remove(req)
  os.remove(resp)
  if not status or status == 0 then
    return nil, "Could not reach sublingo.cc (" .. (out ~= "" and out or "is curl installed?") .. ")"
  end
  local ok, data = pcall(json_decode, text)
  if not ok or type(data) ~= "table" then
    return nil, "Unexpected response from sublingo.cc (HTTP " .. status .. ")"
  end
  if status ~= 200 then
    return nil, data.error or ("HTTP " .. status), data.code
  end
  return data
end

---------------------------------------------------------------------------
-- Translation
---------------------------------------------------------------------------

local function parse_glossary(text)
  local out = {}
  for line in (text or ""):gmatch("[^\r\n]+") do
    line = line:match("^%s*(.-)%s*$")
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local src, dst = line, ""
      for _, sep in ipairs({ "->", "\226\134\146", "=", "\t" }) do -- "→" in UTF-8
        local a, b = line:find(sep, 1, true)
        if a then
          src = line:sub(1, a - 1):match("^%s*(.-)%s*$")
          dst = line:sub(b + 1):match("^%s*(.-)%s*$")
          break
        end
      end
      if src ~= "" then out[#out + 1] = { source = src, target = dst } end
    end
  end
  return out
end

local function encode_body(texts, to, glossary)
  local t = {}
  for i, s in ipairs(texts) do t[i] = json_str(s) end
  local body = '{"texts":[' .. table.concat(t, ",") .. '],"from":"","to":' .. json_str(to)
  if #glossary > 0 then
    local g = {}
    for i, e in ipairs(glossary) do
      g[i] = '{"source":' .. json_str(e.source) .. ',"target":' .. json_str(e.target) .. "}"
    end
    body = body .. ',"glossary":[' .. table.concat(g, ",") .. "]"
  end
  return body .. "}"
end

-- Lines worth translating: dialogue, not commented, has visible text, not a drawing.
local function translatable(line)
  if line.class ~= "dialogue" or line.comment then return false end
  if line.text:find("\\p[1-9]") then return false end
  local plain = line.text:gsub("{[^}]*}", ""):gsub("\\[Nnh]", ""):gsub("%s", "")
  return plain ~= ""
end

local function to_api(t) return (t:gsub("\\N", "\n")) end
local function from_api(t) return (t:gsub("\r?\n", "\\N")) end

local function translate_texts(texts, to, glossary, key)
  local results = {}
  local total = #texts
  for start = 1, total, CHUNK do
    if aegisub.progress.is_cancelled() then return results, "Cancelled." end
    aegisub.progress.set(100 * (start - 1) / total)
    aegisub.progress.task(string.format("Translating lines %d-%d of %d...", start, math.min(start + CHUNK - 1, total), total))
    local chunk = {}
    for i = start, math.min(start + CHUNK - 1, total) do chunk[#chunk + 1] = texts[i] end
    local headers = { ["x-sl-ref"] = REF }
    if start == 1 then
      headers["x-sl-job"] = "1"
      headers["x-sl-fmt"] = "ass"
      headers["x-sl-mode"] = "aegisub"
      headers["x-sl-lines"] = tostring(total)
      headers["x-sl-path"] = "/aegisub"
      headers["x-sl-land"] = "/aegisub"
    end
    if key and key ~= "" then headers["x-sublingo-key"] = key end
    local data, err, code = post_json(encode_body(chunk, to, glossary), headers)
    if not data then
      if code == "FREE_QUOTA" or code == "CREDITS_EMPTY" then
        err = err .. "\nYou can paste a credit key in the SubLingo dialog to continue."
      end
      return results, err
    end
    local tr = data.translated
    if type(tr) ~= "table" or #tr ~= #chunk then
      return results, "sublingo.cc returned " .. (type(tr) == "table" and #tr or 0) .. " lines for " .. #chunk .. "; stopped here."
    end
    for _, s in ipairs(tr) do results[#results + 1] = s end
  end
  aegisub.progress.set(100)
  return results
end

local function apply(subs, idx, translated, mode)
  -- bottom-up so inserted comment lines don't shift the indexes still to do
  for n = #translated, 1, -1 do
    local i = idx[n]
    local line = subs[i]
    local tr = from_api(translated[n])
    if mode == MODES[1] then
      local orig = subs[i]
      orig.comment = true
      line.text = tr
      subs[i] = line
      subs.insert(i, orig)
    elseif mode == MODES[2] then
      line.text = tr
      subs[i] = line
    elseif mode == MODES[3] then
      line.text = line.text .. "\\N" .. tr
      subs[i] = line
    else
      line.text = tr .. "\\N" .. line.text
      subs[i] = line
    end
  end
end

local function macro(subs, sel)
  local c = load_conf()
  local dialog = {
    { class = "label", x = 0, y = 0, label = "Translate to:" },
    { class = "dropdown", name = "to", x = 1, y = 0, width = 2, items = LANGS, value = c.to },
    { class = "label", x = 0, y = 1, label = "or type a language:" },
    { class = "edit", name = "other", x = 1, y = 1, width = 2, value = c.other, hint = "e.g. Brazilian Portuguese, Tagalog" },
    { class = "label", x = 0, y = 2, label = "Lines:" },
    { class = "dropdown", name = "scope", x = 1, y = 2, width = 2, items = SCOPES, value = c.scope },
    { class = "label", x = 0, y = 3, label = "Output:" },
    { class = "dropdown", name = "mode", x = 1, y = 3, width = 2, items = MODES, value = c.mode },
    { class = "label", x = 0, y = 4, width = 3, label = "Names and terms, one per line (e.g. Ryouiki Tenkai = Domain Expansion; nothing after = keeps it as is):" },
    { class = "textbox", name = "glossary", x = 0, y = 5, width = 3, height = 5, value = c.glossary },
    { class = "label", x = 0, y = 10, width = 3, label = "Credit key (optional, from sublingo.cc/credits):" },
    { class = "edit", name = "key", x = 0, y = 11, width = 3, value = c.key },
    { class = "label", x = 0, y = 12, width = 3, label = "Free: 2,000 lines a day. The dialogue text is sent to sublingo.cc for translation." },
  }
  local btn, res = aegisub.dialog.display(dialog, { "Translate", "Cancel" }, { ok = "Translate", cancel = "Cancel" })
  if btn ~= "Translate" then aegisub.cancel() end
  for k, v in pairs(res) do c[k] = v end
  save_conf(c)

  local to = (c.other or ""):match("^%s*(.-)%s*$")
  if to == "" then to = c.to end

  local idx = {}
  if c.scope == SCOPES[1] then
    for _, i in ipairs(sel) do if translatable(subs[i]) then idx[#idx + 1] = i end end
  else
    for i = 1, #subs do if translatable(subs[i]) then idx[#idx + 1] = i end end
  end
  table.sort(idx)
  if #idx == 0 then
    aegisub.debug.out("SubLingo: no dialogue lines to translate (comments, empty lines and drawings are skipped).\n")
    return
  end

  local texts = {}
  for n, i in ipairs(idx) do texts[n] = to_api(subs[i].text) end
  local translated, err = translate_texts(texts, to, parse_glossary(c.glossary), c.key)
  if #translated > 0 then
    local done = {}
    for n = 1, #translated do done[n] = idx[n] end
    apply(subs, done, translated, c.mode)
    aegisub.set_undo_point(script_name)
  end
  if err then
    aegisub.debug.out(string.format("SubLingo: translated %d of %d lines.\n%s\n", #translated, #idx, err))
  end
end

aegisub.register_macro(script_name, script_description, macro)
