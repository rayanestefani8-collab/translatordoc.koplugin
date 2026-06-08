--[[--
Translation back-ends for the Document Translator plugin.
Handles Google Translate and DeepL API calls, text chunking,
and HTML node-level translation.

@module koplugin.translator.translator
--]]--

local https  = require("ssl.https")
local ltn12  = require("ltn12")
local JSON   = require("json")
local logger = require("logger")

local M = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function urlencode(s)
    return (s:gsub("([^%w%-%.%_%~ ])", function(c)
        return string.format("%%%02X", string.byte(c))
    end):gsub(" ", "+"))
end

local function chunkText(text, max)
    local chunks = {}
    while #text > max do
        local cut = max
        while cut > 1 and text:sub(cut,cut) ~= " " and text:sub(cut,cut) ~= "\n" do
            cut = cut - 1
        end
        if cut <= 1 then cut = max end
        table.insert(chunks, text:sub(1, cut))
        text = text:sub(cut + 1)
    end
    if #text > 0 then table.insert(chunks, text) end
    return chunks
end

local function httpsRequest(url, body, headers)
    local sink = {}
    local req = {
        url     = url,
        method  = body and "POST" or "GET",
        headers = headers or {},
        sink    = ltn12.sink.table(sink),
    }
    if body then
        req.source = ltn12.source.string(body)
        req.headers["Content-Length"] = tostring(#body)
    end
    local ok, code = https.request(req)
    if ok and (code == 200 or code == 201) then
        return table.concat(sink)
    end
    return nil, tostring(code)
end

-- ── API back-ends ─────────────────────────────────────────────────────────────

local function googleChunk(text, lang, key)
    local url, resp, err
    if key and key ~= "" then
        url = string.format(
            "https://translation.googleapis.com/language/translate/v2?key=%s&q=%s&target=%s&format=text",
            urlencode(key), urlencode(text), urlencode(lang))
        resp, err = httpsRequest(url)
        if not resp then return nil, err end
        local ok, data = pcall(JSON.decode, resp)
        if ok and data and data.data and data.data.translations then
            return data.data.translations[1].translatedText
        end
        return nil, "JSON parse error"
    else
        url = string.format(
            "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=%s&dt=t&q=%s",
            urlencode(lang), urlencode(text))
        resp, err = httpsRequest(url)
        if not resp then return nil, err end
        local ok2, data = pcall(JSON.decode, resp)
        if not ok2 or not data then return nil, "JSON parse error" end
        local parts = {}
        if data[1] then
            for _, pair in ipairs(data[1]) do
                if pair[1] then table.insert(parts, pair[1]) end
            end
        end
        return table.concat(parts)
    end
end

local function deeplChunk(text, lang, key)
    if not key or key == "" then return nil, "DeepL key not set" end
    local host = key:match(":fx$") and "api-free.deepl.com" or "api.deepl.com"
    local body = string.format("auth_key=%s&text=%s&target_lang=%s",
        urlencode(key), urlencode(text),
        urlencode(lang:upper():gsub("-","_")))
    local resp, err = httpsRequest(
        "https://" .. host .. "/v2/translate", body,
        {["Content-Type"] = "application/x-www-form-urlencoded"})
    if not resp then return nil, err end
    local ok, data = pcall(JSON.decode, resp)
    if ok and data and data.translations and data.translations[1] then
        return data.translations[1].text
    end
    return nil, "JSON parse error"
end

-- ── Public: translate plain text ──────────────────────────────────────────────

--- Translate a plain text string, chunking as needed.
-- @string text     Source text
-- @string engine   "google" or "deepl"
-- @string lang     Target language code (e.g. "pt-BR")
-- @string key      API key (may be empty for Google free endpoint)
-- @treturn string  Translated text, or nil + error message
function M.translateText(text, engine, lang, key)
    if text:match("^%s*$") then return text end
    local chunks  = chunkText(text, 4500)
    local results = {}
    for i, chunk in ipairs(chunks) do
        logger.dbg("Translator: chunk", i, "/", #chunks)
        local translated, err
        if engine == "deepl" then
            translated, err = deeplChunk(chunk, lang, key)
        else
            translated, err = googleChunk(chunk, lang, key)
        end
        if not translated then
            return nil, string.format("chunk %d/%d: %s", i, #chunks, tostring(err))
        end
        table.insert(results, translated)
    end
    return table.concat(results)
end

-- ── Public: translate HTML preserving structure ───────────────────────────────

local SKIP_TAGS = { script=true, style=true, code=true, pre=true }

--- Walk an HTML/XHTML string and translate only visible text nodes,
-- leaving all tags, attributes, and structure intact.
-- @string html     Source HTML
-- @string engine   "google" or "deepl"
-- @string lang     Target language code
-- @string key      API key
-- @treturn string  HTML with translated text nodes, or nil + error
function M.translateHtmlNodes(html, engine, lang, key)
    local result  = {}
    local pos     = 1
    local in_skip = 0

    while pos <= #html do
        local tag_start, tag_end = html:find("<[^>]+>", pos)
        if not tag_start then
            local text = html:sub(pos)
            if in_skip == 0 and not text:match("^%s*$") then
                local t, err = M.translateText(text, engine, lang, key)
                if not t then return nil, err end
                text = t
            end
            table.insert(result, text)
            break
        end

        if tag_start > pos then
            local text = html:sub(pos, tag_start - 1)
            if in_skip == 0 and not text:match("^%s*$") then
                local t, err = M.translateText(text, engine, lang, key)
                if not t then return nil, err end
                text = t
            end
            table.insert(result, text)
        end

        local tag      = html:sub(tag_start, tag_end)
        local tag_name = (tag:match("^</?(%a+)") or ""):lower()
        local is_close = tag:match("^</") ~= nil
        local is_self  = tag:match("/>%s*$") ~= nil

        table.insert(result, tag)

        if SKIP_TAGS[tag_name] then
            if not is_self then
                in_skip = is_close and math.max(0, in_skip - 1) or in_skip + 1
            end
        end

        pos = tag_end + 1
    end

    return table.concat(result)
end

return M
